import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'package:shared_ecosystem/shared_ecosystem.dart';

import 'piper_tts.dart';

// ============================================================
// CONFIG & PERSISTENT SESSION STATE
// ============================================================

// Number of recent logs to inspect
const int feedbackWindowSize = 10;

final Random _random = Random();

// Skyrim voice personality descriptions for contextual feedback prompt
const Map<String, String> voiceDescriptions = {
  'tulius':
      'General Tullius, stern, tactical Imperial military commander. Serious, disciplined, pragmatic, speaks with authority.',
  'ulfric':
      'Ulfric Stormcloak, bold Nordic leader, passionate rebel, patriotic, deeply emotional, resonates with strength, honor, and freedom.',
  'septimus':
      'Septimus Signus, obsessive, eccentric scholar of the Elder Scrolls. Brilliant but highly unstable, fast-paced, paranoid, speaks in cryptic metaphors.',
  'arngeir':
      'Arngeir, wise, calm, and serene Greybeard monk. Extremely peaceful, meditative, speaks slowly, with deep insight, patience, and profound wisdom.',
  'jzargo':
      'J\'zargo, arrogant, ambitious Khajiit mage-apprentice. Proud, refers to himself in the third person, competitive, eager to prove his superior magical prowess.',
  'irileth':
      'Irileth, fierce, hyper-vigilant Housecarl. Fiercely loyal, direct, highly protective, sharp-tongued, pragmatic, no-nonsense warrior.',
  'ancano':
      'Ancano, haughty, condescending Thalmor advisor. Extremely arrogant, superior, scheming, sneers, speaks with smooth but dripping distain.',
  'mirabelleervine':
      'Mirabelle Ervine, efficient, strict Master Wizard of the College. Organized, professional, highly competent, nurturing but demands excellence and protocol.',
  'kodlakwhitemane':
      'Kodlak Whitemane, respected Harbinger of the Companions. Honorable, fatherly, wise, ancient warrior who speaks of inner honor, spiritual cleanliness, and the old ways.',
  'nepali':
      'A local guide speaking with a warm, friendly, helpful Nepali accent and demeanor.',
};

// Loads session state of last voices from session_state.json
Future<Map<String, String>> loadLastVoices() async {
  final scriptDir = PiperTTS.getScriptDir();
  final file = File(
    path.join(scriptDir, 'workspace_logs', 'session_state.json'),
  );
  if (!await file.exists()) {
    return {};
  }
  try {
    final content = await file.readAsString();
    if (content.trim().isEmpty) return {};
    final Map<String, dynamic> jsonMap = jsonDecode(content);
    return jsonMap.map((key, value) => MapEntry(key, value.toString()));
  } catch (e) {
    stderr.writeln('Error loading session_state.json: $e');
    return {};
  }
}

// Saves session state of last voices to session_state.json
Future<void> saveLastVoice(String workspaceId, String voice) async {
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  final file = File(path.join(logsDir.path, 'session_state.json'));

  // Read current states first to merge
  Map<String, String> currentStates = {};
  if (await file.exists()) {
    try {
      final content = await file.readAsString();
      if (content.trim().isNotEmpty) {
        final Map<String, dynamic> jsonMap = jsonDecode(content);
        currentStates = jsonMap.map(
          (key, value) => MapEntry(key, value.toString()),
        );
      }
    } catch (_) {}
  }

  currentStates[workspaceId] = voice;
  await file.writeAsString(jsonEncode(currentStates));
}

// UnifiedAIClient lazy-loaded instance
UnifiedAIClient? _aiClient;

UnifiedAIClient? getAIClient() {
  if (_aiClient == null) {
    try {
      _aiClient = UnifiedAIClient.fromEnvironment();
    } catch (e) {
      stderr.writeln('Error creating UnifiedAIClient from environment: $e');
    }
  }
  return _aiClient;
}

// Slugs the workspace path to use as a file name safely
File getLogFileForWorkspace(String workspaceId) {
  if (workspaceId.trim().isEmpty) {
    throw ArgumentError('workspaceId cannot be empty or blank.');
  }

  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }

  // Slug path: replace non-alphanumeric chars with underscores, take last 2 parts
  final cleanPath = workspaceId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-/]'), '_');
  final parts = cleanPath.split('/').where((e) => e.isNotEmpty).toList();
  String slug;
  if (parts.length >= 2) {
    slug = '${parts[parts.length - 2]}_${parts.last}';
  } else if (parts.isNotEmpty) {
    slug = parts.last;
  } else {
    slug = 'default';
  }
  final filename = 'speech_logs_$slug.jsonl';

  return File(path.join(logsDir.path, filename));
}

// ============================================================
// LOGGING
// ============================================================

Future<void> appendSpeechLog({
  required String text,
  required String voice,
  required String workspaceId,
  String source = 'agent',
}) async {
  final file = getLogFileForWorkspace(workspaceId);

  final logEntry = {
    'timestamp': DateTime.now().toIso8601String(),
    'text': text,
    'voice': voice,
    'workspaceId': workspaceId,
    'source': source,
    'length': text.length,
  };

  await file.writeAsString('${jsonEncode(logEntry)}\n', mode: FileMode.append);

  // Trigger dynamic compaction transaction to keep logs compact and token-efficient
  await compactLogsIfNeeded(workspaceId);
}

// Compacts old speech logs into a single summary log entry if logs exceed threshold
Future<void> compactLogsIfNeeded(String workspaceId) async {
  try {
    final file = getLogFileForWorkspace(workspaceId);
    if (!await file.exists()) return;

    final lines = await file.readAsLines();
    final nonEmptyLines = lines.where((e) => e.trim().isNotEmpty).toList();

    // Trigger compaction if we have > 10 entries OR total characters > 3000
    final totalChars = nonEmptyLines
        .map((e) => e.length)
        .fold(0, (a, b) => a + b);
    if (nonEmptyLines.length <= 30 && totalChars <= 9000) {
      return;
    }

    // Must have at least 4 entries to meaningfully compact
    if (nonEmptyLines.length < 4) return;

    stderr.writeln(
      'Compacting speech logs for workspace $workspaceId. Total lines: ${nonEmptyLines.length}, chars: $totalChars',
    );

    // Parse all log entries
    final entries = nonEmptyLines
        .map((e) => jsonDecode(e) as Map<String, dynamic>)
        .toList();

    // We keep the last 3 entries raw, and roll up everything else (including any previous summaries)
    final keepCount = 3;
    final rollupEntries = entries.sublist(0, entries.length - keepCount);
    final keepEntries = entries.sublist(entries.length - keepCount);

    // Format the rollup entries for the AI
    final rollupSummary = rollupEntries
        .map((e) {
          final voice = e['voice'] ?? 'unknown';
          final text = e['text'] ?? '';
          return '[$voice]: "$text"';
        })
        .join('\n');

    String summaryText = '';
    final client = getAIClient();
    if (client != null) {
      final systemPrompt =
          'You are the Sigil Stone Cognitive Compactor.\n'
          'Your job is to condense a sequence of speech log entries from a pair-programming session into a single, extremely brief summary statement (2-5 sentences).\n'
          'Identify what tasks were active, which voice personas spoke, and their primary focus or outcomes.\n'
          'Keep your output professional, concise, and dense with context.\n\n'
          'OUTPUT FORMAT:\n'
          'Return ONLY a single valid JSON object containing exactly the following key:\n'
          '- "summary": "The highly concise summary statement."\n\n'
          'CRITICAL: Return ONLY raw JSON. Do not include markdown backticks or formatting.';

      final prompt =
          'Speech Logs to Compact:\n'
          '$rollupSummary\n\n'
          'Write the JSON summary for the above logs.';

      final jsonResult = await client.generateJsonCompletion(
        prompt,
        systemPrompt: systemPrompt,
        temperature: 0.5,
        maxTokens: 200,
      );

      summaryText = jsonResult?['summary'] ?? '';
    }

    // Fallback if AI call failed or returned empty
    if (summaryText.isEmpty) {
      final voices = rollupEntries.map((e) => e['voice']).toSet().join(', ');
      summaryText =
          'Development continued with contributions from active voices ($voices) focusing on coding tasks.';
    }

    final compactedSummaryEntry = {
      'timestamp': DateTime.now().toIso8601String(),
      'text': '[SUMMARY OF PREVIOUS CONTEXT]: $summaryText',
      'voice': 'system',
      'workspaceId': workspaceId,
      'length': summaryText.length + 30,
    };

    // Construct the compacted lines
    final List<Map<String, dynamic>> compactedEntries = [
      compactedSummaryEntry,
      ...keepEntries,
    ];

    // Atomically write compacted logs using a temporary file (as Mirabelle Ervine protocol dictates!)
    final tempFile = File('${file.path}.tmp');
    final buffer = StringBuffer();
    for (final entry in compactedEntries) {
      buffer.writeln(jsonEncode(entry));
    }
    await tempFile.writeAsString(buffer.toString());
    await tempFile.rename(file.path);

    stderr.writeln(
      'Compaction transaction completed successfully for workspace $workspaceId.',
    );
  } catch (e) {
    stderr.writeln('Error compacting speech logs: $e');
  }
}

Future<List<Map<String, dynamic>>> readRecentLogs(String workspaceId) async {
  final file = getLogFileForWorkspace(workspaceId);

  if (!await file.exists()) {
    return [];
  }

  final lines = await file.readAsLines();

  final recent = lines
      .where((e) => e.trim().isNotEmpty)
      .toList()
      .reversed
      .take(feedbackWindowSize)
      .toList()
      .reversed;

  return recent.map((line) {
    return jsonDecode(line) as Map<String, dynamic>;
  }).toList();
}

// ============================================================
// AUDIO-BUSY STATE (FILE-BACKED, CROSS-PROCESS)
// ============================================================
//
// An MCP server speaks over stdin and is volatile: there can be more than one
// process (multiple agents/IDEs, or an on-the-fly second Piper instance), and
// in-memory flags are invisible across them. Audio output is a single shared
// device, so "who is speaking" must live in a file that every process can see.
// A staleness timeout means a crashed speaker never deadlocks the channel.

const Duration _speakingStaleAfter = Duration(seconds: 120);

File _speakingLockFile() {
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  return File(path.join(logsDir.path, 'speaking.lock'));
}

Future<void> markSpeaking(String voice, String workspaceId) async {
  try {
    await _speakingLockFile().writeAsString(
      jsonEncode({
        'since': DateTime.now().toIso8601String(),
        'voice': voice,
        'pid': pid,
        'workspaceId': workspaceId,
      }),
    );
  } catch (e) {
    stderr.writeln('Error marking speaking state: $e');
  }
}

Future<void> clearSpeaking() async {
  try {
    final f = _speakingLockFile();
    if (await f.exists()) await f.delete();
  } catch (e) {
    stderr.writeln('Error clearing speaking state: $e');
  }
}

// Returns the live speaking state if some process is currently speaking and the
// lock is fresh; null if free or stale.
Future<Map<String, dynamic>?> currentSpeakingState() async {
  try {
    final f = _speakingLockFile();
    if (!await f.exists()) return null;
    final content = await f.readAsString();
    if (content.trim().isEmpty) return null;
    final m = jsonDecode(content) as Map<String, dynamic>;
    final since = DateTime.tryParse(m['since']?.toString() ?? '');
    if (since == null) return null;
    if (DateTime.now().difference(since) > _speakingStaleAfter) {
      return null; // stale lock from a crashed speaker
    }
    return m;
  } catch (_) {
    return null;
  }
}

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

// ============================================================
// REAL LLM FEEDBACK ENGINE
// ============================================================

Future<Map<String, dynamic>?> generateRealFeedback({
  required String workspaceId,
  required String voice,
  required List<Map<String, dynamic>> logs,
}) async {
  try {
    final client = getAIClient();
    if (client == null) return null;

    final systemPrompt =
        'You are the Sigil Stone Cognitive Director. Your task is to compose a short "Internal Monologue Transition Nudge" for an incoming AI voice persona taking over a programming session.\n\n'
        'CONTEXT:\n'
        'During a pair-programming session, the AI assistant switches between different Skyrim-inspired character voices (personas).\n'
        'Each character has a unique software focus:\n'
        '- Arngeir: High-level wisdom, architecture, philosophy, intent, calm pacing, deep contemplation.\n'
        '- Tullius: Tactical execution, extreme robustness, safety, error handling, defensive code, military-like strictness.\n'
        '- Mirabelle: Wizarding discipline, strict testing, organizational protocols, validation, order.\n'
        '- Septimus: Deep-dive investigations, cryptic/irregular pattern matching, edge cases, out-of-the-box possibilities.\n'
        '- J\'zargo: Competitive performance, speed, supreme optimization, and proving superior coding power.\n'
        '- Irileth: Vigilance, threat assessment (bugs/security vulnerabilities), and defensive testing under pressure.\n'
        '- Kodlak: Refactoring technical debt, clean architecture, honorable craftsmanship, and inner cleanliness of code.\n'
        '- Ancano: Haughty elitism, supreme refinement of code, Thalmor-style absolute control over complexity.\n'
        'Your goal is to look at the narration history of what the previous personas said in the logs, and write the internal monologue guidance for the incoming persona as they "take over the microphone."\n'
        'This guidance must suggest how the incoming voice will shift their active cognitive focus (e.g. from the previous voice\'s focus to their own preferred style like testing, architecture, or optimization).\n\n'
        'OUTPUT FORMAT:\n'
        'You must return ONLY a single valid JSON object containing exactly the following keys:\n'
        '- "inferredMode": "verbose" (if past logs are wordy), "compressed" (if logs are too short/fragmented), or "stable" (if balanced).\n'
        '- "guidance": A 1-2 sentence internal monologue coaching nudge written in the distinct tone and perspective of the incoming voice. It should reference the transition from the previous voice\'s focus to theirs, and outline what they will prioritize next in the workspace. Do not do theatrical roleplay; it is a professional, immersive programming guide.\n'
        '- "personaAlignment": A 1-word alignment status of the incoming voice ("strong", "moderate", "shifting").\n\n'
        'CRITICAL: Return ONLY raw JSON. Do not include markdown backticks or formatting.';

    final logsSummary = logs.isEmpty
        ? 'No previous speech logs. This is the start of the session.'
        : logs.map((log) => '- [${log['voice']}]: "${log['text']}"').join('\n');

    final previousVoice = logs.isEmpty ? 'none' : logs.last['voice'];
    final incomingPersonaDesc =
        voiceDescriptions[voice] ?? 'A Skyrim character persona.';

    final prompt =
        'Workspace ID: "$workspaceId"\n'
        'Incoming Voice Persona: "$voice"\n'
        'Description of incoming persona: $incomingPersonaDesc\n'
        'Previous Voice in workspace: "$previousVoice"\n\n'
        'Narrative History of the Workspace logs:\n'
        '$logsSummary\n\n'
        'Write the internal monologue shift nudge for "$voice" taking over from "$previousVoice" in workspace "$workspaceId".';

    final jsonResult = await client.generateJsonCompletion(
      prompt,
      systemPrompt: systemPrompt,
      temperature: 0.7,
      maxTokens: 300,
    );

    if (jsonResult != null) {
      return {
        'workspaceId': workspaceId,
        'inferredMode': jsonResult['inferredMode'] ?? 'stable',
        'recentMessages': logs.length,
        'guidance':
            jsonResult['guidance'] ?? 'maintain current narration pacing',
        'personaAlignment': jsonResult['personaAlignment'] ?? voice,
      };
    }
  } catch (e) {
    stderr.writeln('Error generating real feedback: $e');
  }
  return null;
}

// ============================================================
// PSEUDO FEEDBACK ENGINE
// ============================================================

Future<Map<String, dynamic>> generatePseudoFeedback(
  List<Map<String, dynamic>> logs,
  String voice,
  String workspaceId,
) async {
  final totalMessages = logs.length;

  final avgLength = logs.isEmpty
      ? 0
      : logs.map((e) => e['length'] as int).reduce((a, b) => a + b) ~/
            logs.length;

  String inferredMode = 'stable';

  if (avgLength > 180) {
    inferredMode = 'verbose';
  } else if (avgLength < 40) {
    inferredMode = 'compressed';
  }

  final suggestions = [
    'maintain current narration pacing',
    'reasoning clarity increasing',
    'voice continuity stable',
    'session rhythm coherent',
    'narration becoming more fluid',
    'maintain concise cognitive narration',
  ];

  return {
    'workspaceId': workspaceId,
    'inferredMode': inferredMode,
    'recentMessages': totalMessages,
    'guidance': suggestions[_random.nextInt(suggestions.length)],
    'personaAlignment': voice,
  };
}

// ============================================================
// TEXT SANITIZER
// ============================================================

// ============================================================
// TEXT SANITIZER & SPEECH NORMALIZER
// ============================================================

class ExpressionRewrite {
  final RegExp pattern;
  final List<String> replacements;
  final double emotionalIntensity;

  ExpressionRewrite({
    required this.pattern,
    required this.replacements,
    this.emotionalIntensity = 1.0,
  });
}

final Map<String, List<ExpressionRewrite>> personaRules = {
  'tulius': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['As expected.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Amusing.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Let me consider this.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Careless.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Unacceptable.'],
    ),
  ],
  'ulfric': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The Empire never learns.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Ha! Well spoken!'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['There is truth in that.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Cowards.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Damn the Thalmor.'],
    ),
  ],
  'septimus': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The shifting walls disagree…'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Heh… the unseen laughs with us…'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The equations tremble…'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The ink rejects the unworthy…'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The noise returns…'],
    ),
  ],
  'arngeir': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Patience.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['A gentle truth.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['There is wisdom here.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Anger clouds judgment.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The mind must remain still.'],
    ),
  ],
  'jzargo': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["J’zargo expected as much."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["Ha! J’zargo is pleased."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["J’zargo must consider this carefully."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["A disappointing effort."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["This irritates J’zargo."],
    ),
  ],
  'irileth': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Stay focused.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["You’re fortunate."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Possible.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Sloppy.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Enough.'],
    ),
  ],
  'ancano': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Predictable.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['How quaint.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Expected from lesser minds.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Pathetic.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Insufferable.'],
    ),
  ],
  'mirabelleervine': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Focus, please.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['That was unexpected.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['We should verify that.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['This is becoming a problem.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Complications again.'],
    ),
  ],
  'kodlakwhitemane': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The old ways endure.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Ha… that brings back memories.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['A difficult path.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Pride blinds many warriors.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The beast stirs again.'],
    ),
  ],
};

final List<ExpressionRewrite> generalRules = [
  ExpressionRewrite(
    pattern: RegExp(r'\bpfft(?:\s*[,.!?]|\b)', caseSensitive: false),
    replacements: ['Nonsense.', 'Hardly.'],
  ),
  ExpressionRewrite(
    pattern: RegExp(r'\bgrrr(?:\s*[,.!?]|\b)', caseSensitive: false),
    replacements: ['Damn.', 'By the gods.'],
  ),
  ExpressionRewrite(
    pattern: RegExp(r'\btsk(?:\s*[,.!?]|\b)', caseSensitive: false),
    replacements: ['Careless.', 'Disappointing.'],
  ),
  ExpressionRewrite(
    pattern: RegExp(
      r'\b(hehehehe|hahahaha|haha|hehe|heh)(?:\s*[,.!?]|\b)',
      caseSensitive: false,
    ),
    replacements: ['That is amusing.'],
  ),
];

String sanitizeText(String text, {String? voice}) {
  // 1. Basic formatting sanitization
  String sanitized = text
      .replaceAll(RegExp(r'\*\*'), '')
      .replaceAll(RegExp(r'\*'), '')
      .replaceAll(RegExp(r'__'), '')
      .replaceAll(RegExp(r'_'), '')
      .replaceAll(RegExp(r'~~'), '')
      .replaceAll(RegExp(r'`'), '')
      .replaceAll(RegExp(r'```'), '')
      .replaceAll(RegExp(r'^#+\s', multiLine: true), '')
      .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'\1')
      .replaceAll(RegExp(r'!\[([^\]]*)\]\([^)]+\)'), '')
      .replaceAll(RegExp(r'^>\s', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*[-*+]\s', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*\d+\.\s', multiLine: true), '')
      .replaceAll(RegExp(r'^-{3,}', multiLine: true), '')
      .replaceAll(
        RegExp(
          r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?',
        ),
        '',
      )
      .replaceAll(RegExp(r'\d{4}-\d{2}-\d{2}'), '')
      .replaceAll(RegExp(r'\d{2}/\d{2}/\d{4}'), '')
      .replaceAll(RegExp(r'\d{2}-\d{2}-\d{4}'), '')
      .replaceAll(RegExp(r'\d{2}:\d{2}:\d{2}(?:\s?[AP]M)?'), '')
      .replaceAll(RegExp(r'\d{2}:\d{2}(?:\s?[AP]M)?'), '')
      .replaceAll(RegExp(r'\d{1,2}:\d{2}\s?[AP]M'), '')
      .replaceAll(RegExp(r'\[|\]'), '')
      .replaceAll(RegExp(r'\{|\}'), '')
      .replaceAll(RegExp(r'<|>'), '')
      .replaceAll(RegExp(r'\\'), '')
      .replaceAll(RegExp(r'/'), '')
      .replaceAll(RegExp(r'`'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // 2. Normalize problematic typography (A3)
  sanitized = sanitized.replaceAll(RegExp(r'!{2,}'), '!');
  sanitized = sanitized.replaceAll(RegExp(r'\?{2,}'), '?');
  sanitized = sanitized.replaceAll(RegExp(r'\.{4,}'), '…');

  // Helper to apply regex replacement with punctuation preservation
  String applyRuleReplacement(String source, ExpressionRewrite rule) {
    return source.replaceAllMapped(rule.pattern, (match) {
      final matchStr = match.group(0)!.trim();
      final hasComma = matchStr.endsWith(',');
      final hasExclamation = matchStr.endsWith('!');
      final hasQuestion = matchStr.endsWith('?');
      final hasPeriod = matchStr.endsWith('.');

      String rep = rule.replacements[_random.nextInt(rule.replacements.length)];
      if (rep.endsWith('.') ||
          rep.endsWith(',') ||
          rep.endsWith('!') ||
          rep.endsWith('?')) {
        final baseRep = rep.substring(0, rep.length - 1);
        if (hasComma) {
          rep = '$baseRep,';
        } else if (hasExclamation) {
          rep = '$baseRep!';
        } else if (hasQuestion) {
          rep = '$baseRep?';
        } else if (hasPeriod) {
          rep = '$baseRep.';
        }
      }
      return rep;
    });
  }

  // 3. Apply persona-specific semantic rewrites (A1, A2)
  if (voice != null && personaRules.containsKey(voice)) {
    final rules = personaRules[voice]!;
    for (final rule in rules) {
      sanitized = applyRuleReplacement(sanitized, rule);
    }
  }

  // 4. Apply general interjection fallback rules (D2)
  for (final rule in generalRules) {
    sanitized = applyRuleReplacement(sanitized, rule);
  }

  return sanitized.replaceAll(RegExp(r'\s+'), ' ').trim();
}
