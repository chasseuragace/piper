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
  // Each fired signal carries a STABLE id (for deterministic ack-matching) and a
  // human reason (for the judge prompt). The two lists stay index-aligned.
  final concerns = <String>[];
  final reasons = <String>[];
  void fire(String id, String reason) {
    concerns.add(id);
    reasons.add(reason);
  }

  final filesChanged = (obs['filesChanged'] as int?) ?? 0;
  final churn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);
  final spread = (obs['moduleSpread'] as int?) ?? 0;

  if (filesChanged >= 6) fire('sprawl', 'sprawl: $filesChanged files touched');
  if (spread >= 3) fire('scattered', 'scattered across $spread modules');
  if (churn >= 150) fire('large-churn', 'large churn ($churn lines)');
  if (obs['srcTouched'] == true && obs['testTouched'] == false) {
    fire('missing-tests', 'source changed without tests');
  }

  int streak = 1;
  for (final entry in logs.reversed) {
    if (entry['voice'] == voice && entry['source'] != 'observer') {
      streak++;
    } else {
      break;
    }
  }
  if (streak >= 5) {
    fire('lens-streak', 'held the $voice lens for $streak turns');
  }

  return {
    'tripped': reasons.isNotEmpty,
    'reasons': reasons,
    'concerns': concerns,
    'streak': streak,
  };
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
  List<Map<String, String>> acknowledged = const [],
}) async {
  try {
    // Nothing in the working tree -> nothing to diverge from. Skip the judge so
    // it cannot hallucinate drift by comparing a clean tree against stale
    // narration still in the log window (e.g. just after a commit).
    if (((obs['filesChanged'] as int?) ?? 0) == 0) return null;

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
      acknowledged: acknowledged,
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
      // PASS 3 — VOICE (local, focused): compose the line AS that persona,
      // carrying the concrete facts so the heard channel delivers real feedback.
      result['spokenLine'] = await _composeSpokenLine(lens, diag, obs) ?? '';
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
  List<Map<String, String>> acknowledged = const [],
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
      'The developer may have ACKNOWLEDGED some concerns (intentional, '
      'not-applicable, being-addressed, or disputed). A listed acknowledgement '
      'is SETTLED: do not raise that concern again. Only override it if the '
      'change has clearly grown much larger than the acknowledgement implies.\n\n'
      'Be SPARING — most turns are fine. Reserve "high" for genuine, '
      'worth-interrupting divergence.\n\n'
      'Return ONLY JSON: {"severity": "none|low|medium|high", "verdict": '
      '"1-2 neutral sentences for the developer to read", "divergence": "what '
      'drifted, or empty"}. Raw JSON only, no markdown.';

  final ackBlock = acknowledged.isEmpty
      ? '(none)'
      : acknowledged
            .map(
              (a) =>
                  '- ${a['concern']}: ${a['ack']}${a['why'] != null ? ' (${a['why']})' : ''}',
            )
            .join('\n');

  final prompt =
      'GROUND TRUTH (git):\n${summarizeObservation(obs)}\n'
      'Changed paths: ${(obs['dirtyPaths'] as List).join(', ')}\n\n'
      'CHEAP SIGNALS THAT FIRED: ${tripReasons.isEmpty ? '(none — routine check)' : tripReasons.join('; ')}\n\n'
      'DEVELOPER ACKNOWLEDGEMENTS (already settled — do not re-flag these):\n$ackBlock\n\n'
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
  Map<String, dynamic> obs,
) async {
  final persona = voiceDescriptions[lens] ?? 'A wise mentor.';

  // Curated, human-phrased facts — NOT the raw debug summary, so the persona
  // weaves real numbers in naturally instead of reciting "src=true tests=false".
  final files = (obs['filesChanged'] as int?) ?? 0;
  final churn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);
  final noTests = obs['srcTouched'] == true && obs['testTouched'] != true;
  // Large line counts get a speech-safe "over N00" phrasing — a small model
  // tends to mangle exact figures (409 -> "forty-one hundred") when it spells
  // them out, but "over 400" it just repeats, and it is never wrong. Small
  // counts (files, low churn) stay exact.
  final churnPhrase = churn >= 100 ? 'over ${(churn ~/ 100) * 100} lines' : '$churn lines';
  final facts = [
    '$files files changed',
    churnPhrase,
    if (noTests) 'no tests updated',
  ].join(', ');

  final systemPrompt =
      'You ARE this character: $persona\n\n'
      'Say AT MOST TWO short sentences to a fellow craftsman, in your own diction '
      'and cadence. THIS IS HEARD ALOUD and is the only feedback the listener '
      'gets, so weave in the two or three most telling facts so they learn WHAT '
      'is wrong — not merely that something is. Use the numbers EXACTLY as given '
      '(as digits). Speak naturally as that character; do NOT recite field names, '
      'branch names, or file paths like a report. Be brief — no sermons. Flavour '
      'wraps the facts; it never replaces them. Address the listener as your '
      'character would (comrade, apprentice, soldier). NEVER use the words '
      '"agent", "AI", "assistant", "user", or "model". Return ONLY JSON: '
      '{"line": "<your words>"}.';
  final prompt =
      'Key facts: $facts.\n'
      'The contradiction: ${diag['divergence']}\n\n'
      'Say your concise piece — name the most telling facts, in your voice.';

  final r = await cheapJson(prompt, systemPrompt: systemPrompt, maxTokens: 90);
  final line = (r?['line'] ?? '').toString().trim();
  if (line.isEmpty) return null;
  // Hard cap: verbose personas (e.g. Arngeir) ignore "be brief" — enforce it.
  final capped = _firstSentences(line, 2);
  // Drop fact-free output: a cryptic persona (e.g. Septimus) can dodge the
  // substance entirely ("the patterns..."). Better silent than a heard line
  // that says nothing — the factual verdict still reaches the agent.
  // A real intervention names a concrete number (file/line counts) or speaks to
  // tests. Require a DIGIT or an explicit "test(s)" mention — a bare "files" or
  // "line" with no number is exactly how a rambling persona sneaks past ("Zero
  // files altered, yet the narrative expands...").
  final carriesFact =
      RegExp(r'\d').hasMatch(capped) ||
      RegExp(r'\btests?\b', caseSensitive: false).hasMatch(capped);
  return carriesFact ? capped : null;
}

// Returns the first [n] sentences of [s], trimmed, skipping empty/punctuation-
// only fragments. A backstop so a rambling persona line can never run on past
// two sentences when heard aloud.
String _firstSentences(String s, int n) {
  final out = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    buf.write(s[i]);
    if ('.!?'.contains(s[i])) {
      final seg = buf.toString().trim();
      buf.clear();
      if (seg.replaceAll(RegExp(r'[.!?\s]'), '').isEmpty) continue;
      out.add(seg);
      if (out.length >= n) break;
    }
  }
  if (out.length < n && buf.toString().trim().isNotEmpty) {
    out.add(buf.toString().trim());
  }
  return out.join(' ').trim();
}
