import 'dart:io';
import 'package:path/path.dart' as path;

import 'piper_personas.dart';
import 'piper_ai_client.dart';
import 'piper_local_llm.dart';

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

    final narration = logs.isEmpty
        ? 'No prior narration. Session is just beginning.'
        : logs
              .map(
                (l) =>
                    '- [${l['voice']}${l['source'] == 'observer' ? '/balcony' : ''}]: "${l['text']}"',
              )
              .join('\n');

    // PASS 1 — DIAGNOSE (cloud, nuanced): divergence + severity + verdict only.
    // No persona, no voice — just the truth. A single-purpose prompt reasons
    // far better than one juggling diagnosis, routing, and voicing at once.
    final diag = await _diagnose(
      client: client,
      workspaceId: workspaceId,
      voice: voice,
      obs: obs,
      narration: narration,
      tripReasons: tripReasons,
    );
    if (diag == null) return null;

    final severity = (diag['severity'] ?? 'low').toString();
    final result = <String, dynamic>{
      'severity': severity,
      'verdict': (diag['verdict'] ?? '').toString(),
      'divergence': (diag['divergence'] ?? '').toString(),
      'recommendedVoice': voice,
      'spokenLine': '',
      'observation': summarizeObservation(obs),
    };

    // Only a high-severity finding ever speaks, so only then do we pay for the
    // two focused follow-up passes — both free, on-device.
    if (severity == 'high') {
      // PASS 2 — ROUTE (local, focused): pick the best-fit lens for THIS issue,
      // judged on the diagnosis alone, not anchored to the current voice.
      final lens = await _routeLens(diag) ?? voice;
      result['recommendedVoice'] = lens;
      // PASS 3 — VOICE (local, focused): compose the line AS that persona.
      result['spokenLine'] = await _composeSpokenLine(lens, diag) ?? '';
    }

    return result;
  } catch (e) {
    stderr.writeln('Error in judgeWorkspace: $e');
    return null;
  }
}

// PASS 1 — DIAGNOSE: detect story-vs-reality divergence and score it. The hard,
// nuanced reasoning — kept on the cloud model. Knows nothing of personas.
Future<Map<String, dynamic>?> _diagnose({
  required dynamic client,
  required String workspaceId,
  required String voice,
  required Map<String, dynamic> obs,
  required String narration,
  required List<String> tripReasons,
}) async {
  final systemPrompt =
      'You are the Balcony: an outside observer of a live coding session. The '
      'developer is immersed and carried by momentum; you are not. You weigh '
      'two things they cannot: GROUND TRUTH (real git facts) and NARRATION '
      '(what they said they were doing).\n\n'
      'Detect DIVERGENCE between story and reality. Examples: said "small fix" '
      'but the diff is large; narrated one module but edited another; claimed '
      'done/tests pass but no test changed; long narration, nothing changed '
      '(spinning); many changes, no narration (going dark).\n\n'
      'Be SPARING — most turns are fine. Reserve "high" for genuine, '
      'worth-interrupting divergence.\n\n'
      'Return ONLY JSON: {"severity": "none|low|medium|high", "verdict": '
      '"1-2 neutral sentences for the developer to read", "divergence": "what '
      'drifted, or empty"}. Raw JSON only, no markdown.';

  final prompt =
      'GROUND TRUTH (git):\n${summarizeObservation(obs)}\n'
      'Changed paths: ${(obs['dirtyPaths'] as List).join(', ')}\n\n'
      'CHEAP SIGNALS THAT FIRED: ${tripReasons.isEmpty ? '(none — routine check)' : tripReasons.join('; ')}\n\n'
      'NARRATION HISTORY (what the developer said):\n$narration\n\n'
      'Diagnose the divergence and score its severity.';

  return client.generateJsonCompletion(
    prompt,
    systemPrompt: systemPrompt,
    temperature: 0.5,
    maxTokens: 200,
  );
}

// PASS 2 — ROUTE: pick the persona-lens whose focus best fits the diagnosed
// problem. One decision, judged on the problem alone (not the current voice),
// which is exactly why it routes accurately. Free, on-device.
Future<String?> _routeLens(Map<String, dynamic> diag) async {
  final voiceList = voiceDescriptions.entries
      .map((e) => '- ${e.key}: ${e.value}')
      .join('\n');
  final systemPrompt =
      'Choose the single best-fit reviewer for a coding concern. Match the '
      'concern to the reviewer whose focus fits it (e.g. security issue -> the '
      'vigilant one; missing tests -> the testing one; sprawling change -> the '
      'simplifier or the architect). Return ONLY JSON: {"voice": "<key>"} using '
      'one key from the list. Raw JSON only.';
  final prompt =
      'Reviewers:\n$voiceList\n\n'
      'Concern: ${diag['verdict']}\n'
      'Divergence: ${diag['divergence']}\n\n'
      'Which reviewer fits best?';

  final r = await cheapJson(prompt, systemPrompt: systemPrompt, maxTokens: 40);
  final key = (r?['voice'] ?? '').toString();
  return voiceDescriptions.containsKey(key) ? key : null;
}

// PASS 3 — VOICE: compose the spoken line AS the chosen persona. One job —
// styling the diagnosis in-character — so the voice discipline actually sticks.
// Free, on-device.
Future<String?> _composeSpokenLine(
  String lens,
  Map<String, dynamic> diag,
) async {
  final persona = voiceDescriptions[lens] ?? 'A wise mentor.';
  final systemPrompt =
      'You ARE this character: $persona\n\n'
      'Say ONE short sentence (no more) to a fellow craftsman about the concern '
      'below, in your own diction, cadence, and worldview. Be brief — a single '
      'remark, not a speech. You are that character — address them as that '
      'character naturally would (comrade, apprentice, soldier). NEVER use the '
      'words "agent", "AI", "assistant", "user", or "model". Flavour that colors '
      'the framing, but keep the substance accurate. Return ONLY JSON: '
      '{"line": "<your words>"}.';
  final prompt =
      'Concern: ${diag['verdict']}\n'
      'What drifted: ${diag['divergence']}\n\n'
      'Say your one-sentence piece.';

  final r = await cheapJson(prompt, systemPrompt: systemPrompt, maxTokens: 70);
  return (r?['line'] ?? '').toString().trim().isEmpty
      ? null
      : (r!['line']).toString().trim();
}
