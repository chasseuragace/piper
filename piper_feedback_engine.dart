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
}) async {
  final file = getLogFileForWorkspace(workspaceId);

  final logEntry = {
    'timestamp': DateTime.now().toIso8601String(),
    'text': text,
    'voice': voice,
    'workspaceId': workspaceId,
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
