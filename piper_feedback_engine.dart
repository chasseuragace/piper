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
const int feedbackWindowSize = 8;

final Random _random = Random();

// Skyrim voice personality descriptions for contextual feedback prompt
const Map<String, String> voiceDescriptions = {
  'tulius': 'General Tullius, stern, tactical Imperial military commander. Serious, disciplined, pragmatic, speaks with authority.',
  'ulfric': 'Ulfric Stormcloak, bold Nordic leader, passionate rebel, patriotic, deeply emotional, resonates with strength, honor, and freedom.',
  'septimus': 'Septimus Signus, obsessive, eccentric scholar of the Elder Scrolls. Brilliant but highly unstable, fast-paced, paranoid, speaks in cryptic metaphors.',
  'arngeir': 'Arngeir, wise, calm, and serene Greybeard monk. Extremely peaceful, meditative, speaks slowly, with deep insight, patience, and profound wisdom.',
  'jzargo': 'J\'zargo, arrogant, ambitious Khajiit mage-apprentice. Proud, refers to himself in the third person, competitive, eager to prove his superior magical prowess.',
  'irileth': 'Irileth, fierce, hyper-vigilant Housecarl. Fiercely loyal, direct, highly protective, sharp-tongued, pragmatic, no-nonsense warrior.',
  'ancano': 'Ancano, haughty, condescending Thalmor advisor. Extremely arrogant, superior, scheming, sneers, speaks with smooth but dripping distain.',
  'mirabelleervine': 'Mirabelle Ervine, efficient, strict Master Wizard of the College. Organized, professional, highly competent, nurturing but demands excellence and protocol.',
  'kodlakwhitemane': 'Kodlak Whitemane, respected Harbinger of the Companions. Honorable, fatherly, wise, ancient warrior who speaks of inner honor, spiritual cleanliness, and the old ways.',
  'nepali': 'A local guide speaking with a warm, friendly, helpful Nepali accent and demeanor.',
};

// Loads session state of last voices from session_state.json
Future<Map<String, String>> loadLastVoices() async {
  final scriptDir = PiperTTS.getScriptDir();
  final file = File(path.join(scriptDir, 'workspace_logs', 'session_state.json'));
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
        currentStates = jsonMap.map((key, value) => MapEntry(key, value.toString()));
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
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }

  String filename;
  if (workspaceId.trim().isEmpty) {
    filename = 'default_speech_logs.jsonl';
  } else {
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
    filename = 'speech_logs_$slug.jsonl';
  }

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
        '- Nepali: Warm, highly friendly, collaborative guide.\n\n'
        'Your goal is to look at the narration history of what the previous personas said in the logs, and write the internal monologue guidance for the incoming persona as they "take over the microphone."\n'
        'This guidance must suggest how the incoming voice will shift their active cognitive focus (e.g. from the previous voice\'s focus to their own preferred style like testing, architecture, or optimization).\n\n'
        'OUTPUT FORMAT:\n'
        'You must return ONLY a single valid JSON object containing exactly the following keys:\n'
        '- "inferredMode": "verbose" (if past logs are wordy), "compressed" (if logs are too short/fragmented), or "stable" (if balanced).\n'
        '- "guidance": A 1-sentence internal monologue coaching nudge written in the distinct tone and perspective of the incoming voice. It should reference the transition from the previous voice\'s focus to theirs, and outline what they will prioritize next in the workspace. Do not do theatrical roleplay; it is a professional, immersive programming guide.\n'
        '- "personaAlignment": A 1-word alignment status of the incoming voice ("strong", "moderate", "shifting").\n\n'
        'CRITICAL: Return ONLY raw JSON. Do not include markdown backticks or formatting.';

    final logsSummary = logs.isEmpty
        ? 'No previous speech logs. This is the start of the session.'
        : logs.map((log) => '- [${log['voice']}]: "${log['text']}"').join('\n');

    final previousVoice = logs.isEmpty ? 'none' : logs.last['voice'];
    final incomingPersonaDesc = voiceDescriptions[voice] ?? 'A Skyrim character persona.';

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
        'guidance': jsonResult['guidance'] ?? 'maintain current narration pacing',
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

String sanitizeText(String text) {
  return text
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
      .replaceAll(RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?'), '')
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
}
