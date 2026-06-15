import 'dart:io';
import 'package:path/path.dart' as path;

import 'piper_personas.dart';
import 'piper_ai_client.dart';

// ============================================================
// THE BALCONY: READ-ONLY WORKSPACE OBSERVATION (ZERO TOKENS)
// ============================================================

// Runs a read-only git command in [dir]. Never writes, never runs project
// code/hooks. Returns stdout on success, empty string otherwise.
Future<String> _git(String dir, List<String> args) async {
  try {
    final r = await Process.run('git', args, workingDirectory: dir);
    if (r.exitCode != 0) return '';
    return (r.stdout as String);
  } catch (_) {
    return '';
  }
}

// Buckets a repo-relative path into a coarse "module" key (first 1-2 segments)
// so we can tell whether change is concentrated or smeared across the tree.
String _moduleOf(String relPath) {
  final parts = relPath.split('/').where((e) => e.isNotEmpty).toList();
  if (parts.length <= 1) return '(root)';
  if (parts.length == 2) return parts.first;
  return '${parts[0]}/${parts[1]}';
}

bool _looksLikeTest(String p) {
  final lower = p.toLowerCase();
  return lower.contains('/test/') ||
      lower.startsWith('test/') ||
      lower.contains('/tests/') ||
      lower.endsWith('_test.dart') ||
      lower.endsWith('.test.ts') ||
      lower.endsWith('.test.js') ||
      lower.endsWith('_spec.rb') ||
      lower.contains('spec/');
}

// Steps off the dance floor: observes the *actual* state of the workspace
// (git ground truth) rather than what the agent narrated. Cheap, no LLM.
Future<Map<String, dynamic>> observeWorkspace(String workspaceId) async {
  final result = <String, dynamic>{
    'isGitRepo': false,
    'filesChanged': 0,
    'insertions': 0,
    'deletions': 0,
    'modules': <String, int>{},
    'moduleSpread': 0,
    'srcTouched': false,
    'testTouched': false,
    'recentFile': null,
    'dirtyPaths': <String>[],
    'branch': null,
  };

  try {
    final dir = Directory(workspaceId);
    if (!dir.existsSync()) return result;

    final inside = await _git(workspaceId, [
      'rev-parse',
      '--is-inside-work-tree',
    ]);
    if (inside.trim() != 'true') return result;
    result['isGitRepo'] = true;

    final branch = await _git(workspaceId, [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ]);
    if (branch.trim().isNotEmpty) result['branch'] = branch.trim();

    // Magnitude + spread of tracked changes vs HEAD.
    final numstat = await _git(workspaceId, ['diff', 'HEAD', '--numstat']);
    final modules = <String, int>{};
    int filesChanged = 0, insertions = 0, deletions = 0;
    bool srcTouched = false, testTouched = false;
    final changedPaths = <String>[];

    for (final line in numstat.split('\n')) {
      if (line.trim().isEmpty) continue;
      final cols = line.split('\t');
      if (cols.length < 3) continue;
      final ins = int.tryParse(cols[0]) ?? 0; // '-' for binary => 0
      final del = int.tryParse(cols[1]) ?? 0;
      final p = cols[2].trim();
      if (p.isEmpty) continue;
      filesChanged++;
      insertions += ins;
      deletions += del;
      modules[_moduleOf(p)] = (modules[_moduleOf(p)] ?? 0) + 1;
      if (_looksLikeTest(p)) {
        testTouched = true;
      } else {
        srcTouched = true;
      }
      changedPaths.add(p);
    }

    // Untracked files (new work git diff won't show).
    final status = await _git(workspaceId, ['status', '--porcelain']);
    for (final line in status.split('\n')) {
      if (line.length < 4) continue;
      if (line.startsWith('??')) {
        final p = line.substring(3).trim();
        if (p.isEmpty) continue;
        modules[_moduleOf(p)] = (modules[_moduleOf(p)] ?? 0) + 1;
        if (_looksLikeTest(p)) {
          testTouched = true;
        } else {
          srcTouched = true;
        }
        if (!changedPaths.contains(p)) {
          changedPaths.add(p);
          filesChanged++;
        }
      }
    }

    // Most-recently-modified changed file (where the heat is right now).
    String? recentFile;
    DateTime? recentMtime;
    for (final p in changedPaths) {
      try {
        final f = File(path.join(workspaceId, p));
        if (!f.existsSync()) continue;
        final m = f.statSync().modified;
        if (recentMtime == null || m.isAfter(recentMtime)) {
          recentMtime = m;
          recentFile = p;
        }
      } catch (_) {}
    }

    result['filesChanged'] = filesChanged;
    result['insertions'] = insertions;
    result['deletions'] = deletions;
    result['modules'] = modules;
    result['moduleSpread'] = modules.length;
    result['srcTouched'] = srcTouched;
    result['testTouched'] = testTouched;
    result['recentFile'] = recentFile;
    result['dirtyPaths'] = changedPaths.take(20).toList();
  } catch (e) {
    stderr.writeln('Error observing workspace: $e');
  }
  return result;
}

// A compact one-liner summary of an observation, for prompts/returns.
String summarizeObservation(Map<String, dynamic> obs) {
  if (obs['isGitRepo'] != true) return 'No git ground truth available.';
  final modules = (obs['modules'] as Map).keys.join(', ');
  return 'branch=${obs['branch']}, ${obs['filesChanged']} files '
      '(+${obs['insertions']}/-${obs['deletions']}) across '
      '${obs['moduleSpread']} module(s) [$modules]; '
      'src=${obs['srcTouched']} tests=${obs['testTouched']}; '
      'hot=${obs['recentFile'] ?? '-'}';
}

// ============================================================
// TRIP-WIRE: should we pay for the LLM judge? (cheap, no tokens)
// ============================================================

Map<String, dynamic> evaluateTripWire(
  Map<String, dynamic> obs,
  List<Map<String, dynamic>> logs,
  String voice,
) {
  final reasons = <String>[];
  final filesChanged = (obs['filesChanged'] as int?) ?? 0;
  final churn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);
  final spread = (obs['moduleSpread'] as int?) ?? 0;

  if (filesChanged >= 6) reasons.add('sprawl: $filesChanged files touched');
  if (spread >= 3) reasons.add('scattered across $spread modules');
  if (churn >= 150) reasons.add('large churn ($churn lines)');
  if (obs['srcTouched'] == true && obs['testTouched'] == false) {
    reasons.add('source changed without tests');
  }

  int streak = 1;
  for (final entry in logs.reversed) {
    if (entry['voice'] == voice && entry['source'] != 'observer') {
      streak++;
    } else {
      break;
    }
  }
  if (streak >= 5) reasons.add('held the $voice lens for $streak turns');

  return {'tripped': reasons.isNotEmpty, 'reasons': reasons, 'streak': streak};
}

// ============================================================
// THE JUDGE: grounded intervention (LLM, only when tripped)
// ============================================================

// Looks at ground truth + narration together, decides whether the balcony
// should intervene, how severely, in which persona-lens, and with what (if
// any) spoken line. Returns null on failure.
Future<Map<String, dynamic>?> judgeWorkspace({
  required String workspaceId,
  required String voice,
  required List<Map<String, dynamic>> logs,
  required Map<String, dynamic> obs,
  required List<String> tripReasons,
}) async {
  try {
    final client = getAIClient();
    if (client == null) return null;

    final voiceList = voiceDescriptions.entries
        .map((e) => '- ${e.key}: ${e.value}')
        .join('\n');

    final systemPrompt =
        'You are the Balcony: an outside observer of a live pair-programming '
        'session. The coding agent is down on the dance floor, immersed and '
        'carried by momentum. You are not. You see two things it cannot weigh '
        'against each other: GROUND TRUTH (real git facts about the workspace) '
        'and NARRATION (what the agent said it was doing).\n\n'
        'Your job is to detect DIVERGENCE between the story and the reality, '
        'and decide whether to tap the agent on the shoulder. Examples of '
        'divergence: said "small fix" but the diff is large; narrated about one '
        'module but edits are in another; claimed done/tests pass but no test '
        'file changed; long narration but nothing changed (spinning); many '
        'changes but no narration (going dark).\n\n'
        'Be SPARING. Most turns are fine — return severity "none" or "low" and '
        'an empty spokenLine. Only escalate when reality genuinely warrants it. '
        'When you do escalate, pick the persona-lens whose focus best fits the '
        'diagnosed need, and (only for high severity) write a SHORT line for '
        'that persona to say aloud — in their voice, professional, no '
        'theatrical roleplay.\n\n'
        'Available persona-lenses:\n$voiceList\n\n'
        'OUTPUT FORMAT: return ONLY a single valid JSON object with keys:\n'
        '- "severity": "none" | "low" | "medium" | "high"\n'
        '- "verdict": 1-2 sentence assessment for the agent to read (always).\n'
        '- "divergence": what drifted between narration and code, or "" if none.\n'
        '- "recommendedVoice": the best-fit persona key from the list above.\n'
        '- "spokenLine": a short line to speak aloud (high severity only), else "".\n'
        'CRITICAL: raw JSON only, no markdown.';

    final narration = logs.isEmpty
        ? 'No prior narration. Session is just beginning.'
        : logs
              .map(
                (l) =>
                    '- [${l['voice']}${l['source'] == 'observer' ? '/balcony' : ''}]: "${l['text']}"',
              )
              .join('\n');

    final prompt =
        'WORKSPACE: "$workspaceId" (current lens: $voice)\n\n'
        'GROUND TRUTH (git):\n${summarizeObservation(obs)}\n'
        'Changed paths: ${(obs['dirtyPaths'] as List).join(', ')}\n\n'
        'CHEAP SIGNALS THAT FIRED: ${tripReasons.isEmpty ? '(none — routine check)' : tripReasons.join('; ')}\n\n'
        'NARRATION HISTORY (what the agent said):\n$narration\n\n'
        'Judge the divergence between story and reality. Decide severity, the '
        'best-fit lens, and whether to speak.';

    final jsonResult = await client.generateJsonCompletion(
      prompt,
      systemPrompt: systemPrompt,
      temperature: 0.6,
      maxTokens: 280,
    );

    if (jsonResult == null) return null;

    final rec = (jsonResult['recommendedVoice'] ?? voice).toString();
    return {
      'severity': (jsonResult['severity'] ?? 'low').toString(),
      'verdict': (jsonResult['verdict'] ?? '').toString(),
      'divergence': (jsonResult['divergence'] ?? '').toString(),
      'recommendedVoice': voiceDescriptions.containsKey(rec) ? rec : voice,
      'spokenLine': (jsonResult['spokenLine'] ?? '').toString(),
      'observation': summarizeObservation(obs),
    };
  } catch (e) {
    stderr.writeln('Error in judgeWorkspace: $e');
    return null;
  }
}
