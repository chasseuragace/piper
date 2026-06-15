import 'dart:io';
import 'dart:math';

import 'piper_personas.dart';
import 'piper_ai_client.dart';

final Random _random = Random();

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
