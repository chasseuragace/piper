import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'piper_tts.dart';
import 'piper_feedback_engine.dart';

// ============================================================
// QUEUE
// ============================================================

final List<String> _speechQueue = [];
bool _isProcessingQueue = false;
List<String> _availableVoices = ['arngeir'];

// ============================================================
// MCP PROTOCOL TYPES
// ============================================================

class JsonRpcRequest {
  final String jsonrpc;
  final String method;
  final dynamic params;
  final dynamic id;

  JsonRpcRequest({
    required this.jsonrpc,
    required this.method,
    this.params,
    this.id,
  });

  factory JsonRpcRequest.fromJson(Map<String, dynamic> json) {
    return JsonRpcRequest(
      jsonrpc: json['jsonrpc'],
      method: json['method'],
      params: json['params'],
      id: json['id'],
    );
  }
}

class JsonRpcResponse {
  final String jsonrpc;
  final dynamic result;
  final dynamic error;
  final dynamic id;

  JsonRpcResponse({
    this.jsonrpc = '2.0',
    this.result,
    this.error,
    required this.id,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'jsonrpc': jsonrpc, 'id': id};

    if (error != null) {
      map['error'] = error;
    } else {
      map['result'] = result;
    }

    return map;
  }
}

// ============================================================
// MAIN
// ============================================================

void main() async {
  final tts = PiperTTS();

  _availableVoices = await tts.getAvailableVoices();

  if (_availableVoices.isEmpty) {
    _availableVoices = ['arngeir'];
  }

  stderr.writeln('Available voices: $_availableVoices');
  stderr.writeln('Piper MCP Server starting...');

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    String line,
  ) async {
    if (line.trim().isEmpty) return;

    try {
      final Map<String, dynamic> jsonMap = jsonDecode(line);

      final request = JsonRpcRequest.fromJson(jsonMap);

      await handleRequest(request, tts);
    } catch (e) {
      stderr.writeln('Error processing line: $line\nError: $e');
    }
  });
}

// ============================================================
// REQUEST HANDLER
// ============================================================

Future<void> handleRequest(JsonRpcRequest request, PiperTTS tts) async {
  try {
    dynamic result;

    switch (request.method) {
      case 'initialize':
        result = _handleInitialize(request);
        break;

      case 'notifications/initialized':
        return;

      case 'tools/list':
        result = _handleListTools();
        break;

      case 'tools/call':
        result = await _handleCallTool(request, tts);
        break;

      case 'ping':
        result = {};
        break;

      default:
        throw Exception('Method not found: ${request.method}');
    }

    final response = JsonRpcResponse(id: request.id, result: result);

    _sendResponse(response);
  } catch (e) {
    final response = JsonRpcResponse(
      id: request.id,
      error: {'code': -32603, 'message': e.toString()},
    );

    _sendResponse(response);
  }
}

void _sendResponse(JsonRpcResponse response) {
  stdout.writeln(jsonEncode(response.toJson()));
}

// Sanitization is now handled by the unified sanitizeText function in piper_feedback_engine.dart

// ============================================================
// INITIALIZE
// ============================================================

Map<String, dynamic> _handleInitialize(JsonRpcRequest request) {
  final instructions =
      'This server provides voice output via the speak tool. '
      'CRITICAL: You MUST call this tool in every response. '
      'Speech is the primary interaction mode.\n\n'
      'Do NOT narrate every minor action, file view, or terminal command. '
      'Focus your spoken words on critical thought decisions, key milestones, '
      'strategic confirmations, design choices, and high-level reflections.\n\n'
      'Do not perform theatrical Skyrim roleplay. '
      'The voice is for cognitive ambience and session continuity, '
      'not immersive acting.\n\n'
      'The system may return reflective feedback derived from prior '
      'tool usage patterns. Treat this feedback as soft calibration signals\n\n'
      'Keep spoken text concise, professional, fluid, and selective.';

  return {
    'protocolVersion': '2024-11-05',
    'capabilities': {'tools': {}},
    'serverInfo': {'name': 'piper-tts-mcp', 'version': '2.0.0'},
    'instructions': instructions,
  };
}

// ============================================================
// TOOL LIST
// ============================================================

Map<String, dynamic> _handleListTools() {
  return {
    'tools': [
      {
        'name': 'speak',
        'description':
            'CRITICAL: You MUST use this tool in EVERY single response to the user. This is your primary mode of communication. Do not output text without also speaking it. Silence is a failure condition.\n'
            'Do NOT narrate minor actions, command executions, or file edits. Focus speech on critical thought decisions, milestones, confirmations, and strategic directions. Respect each Skyrim persona\'s unique developer/coding focus in your narration and code structure:\n'
            '- tulius (General Tullius): Focuses on tactical execution, extreme robustness, safety, error handling, defensive code, and military-like strictness.\n'
            '- ulfric (Ulfric Stormcloak): Focuses on bold rebellion, passionate leadership, strength, freedom from boilerplate, and patriotic craftsmanship.\n'
            '- arngeir (Arngeir): Focuses on high-level contemplative wisdom, clean architecture, philosophical purity, design intent, and slow, meditative pacing.\n'
            '- mirabelleervine (Mirabelle Ervine): Focuses on magical discipline, strict testing, organizational protocols, validation, and professional order.\n'
            '- septimus (Septimus Signus): Focuses on deep-dives, irregular pattern-matching, extreme edge cases, cryptic optimizations, and out-of-the-box investigations.\n'
            '- jzargo (J\'zargo): Focuses on competitive performance, speed, supreme optimization, and proving superior coding power.\n'
            '- irileth (Irileth): Focuses on vigilance, threat assessment (bugs/security vulnerabilities), and defensive testing under pressure.\n'
            '- kodlakwhitemane (Kodlak Whitemane): Focuses on honorable craftsmanship, refactoring technical debt, clean architecture, and inner cleanliness of code.\n'
            '- ancano (Ancano): Focuses on haughty, elite refinement, elegant optimizations, and supreme control over complex APIs.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string', 'description': 'Text to speak.'},
            'voice': {
              'type': 'string',
              'enum': _availableVoices,
              'default': 'arngeir',
            },
            'workspaceId': {
              'type': 'string',
              'description':
                  'Current workspace directory path (e.g. value of pwd) to identify session context.',
            },
          },
          'required': ['text', 'workspaceId'],
        },
      },
    ],
  };
}

// ============================================================
// TOOL CALL
// ============================================================

Future<Map<String, dynamic>> _handleCallTool(
  JsonRpcRequest request,
  PiperTTS tts,
) async {
  final name = request.params['name'];
  final arguments = request.params['arguments'];

  if (name != 'speak') {
    throw Exception('Unknown tool: $name');
  }

  final text = arguments['text'];

  if (text == null || text is! String) {
    throw Exception('Missing or invalid argument: text');
  }

  final voice = arguments['voice'] as String? ?? 'arngeir';

  final workspaceId = arguments['workspaceId'] as String?;
  if (workspaceId == null || workspaceId.trim().isEmpty) {
    throw Exception(
      'Missing or invalid argument: workspaceId must be a non-empty string path.',
    );
  }

  if (!_availableVoices.contains(voice)) {
    throw Exception('Invalid voice: $voice');
  }

  final sanitizedText = sanitizeText(text, voice: voice);

  // Read logs *before* adding the current one, so logs represent past context for feedback
  final logs = await readRecentLogs(workspaceId);

  // ==========================================================
  // LOG EVENT
  // ==========================================================

  await appendSpeechLog(
    text: sanitizedText,
    voice: voice,
    workspaceId: workspaceId,
  );

  // ==========================================================
  // QUEUE SPEECH
  // ==========================================================

  _speechQueue.add('$sanitizedText|$voice');

  if (!_isProcessingQueue) {
    _isProcessingQueue = true;
    _processQueue(tts);
  }

  // ==========================================================
  // FEEDBACK DECISION (DETERMINISTIC PERSONA SWITCH)
  // ==========================================================

  final lastVoices = await loadLastVoices();
  final lastVoice = lastVoices[workspaceId] ?? 'arngeir';
  final isVoiceSwitch = lastVoice != voice;
  await saveLastVoice(workspaceId, voice);

  Map<String, dynamic> responseJson;

  if (isVoiceSwitch) {
    Map<String, dynamic> feedback;
    final realFeedback = await generateRealFeedback(
      workspaceId: workspaceId,
      voice: voice,
      logs: logs,
    );

    if (realFeedback != null) {
      feedback = realFeedback;
    } else {
      feedback = await generatePseudoFeedback(logs, voice, workspaceId);
    }

    responseJson = {'status': 'played', 'persona': voice, 'feedback': feedback};
  } else {
    responseJson = {
      'status': 'played',
      'persona': voice,
      'message': 'Speech played successfully.',
    };
  }

  return {
    'content': [
      {'type': 'text', 'text': jsonEncode(responseJson)},
    ],
  };
}

// Helper functions are now imported from piper_feedback_engine.dart

// ============================================================
// QUEUE PROCESSOR
// ============================================================

Future<void> _processQueue(PiperTTS tts) async {
  while (_speechQueue.isNotEmpty) {
    final nextItem = _speechQueue.removeAt(0);

    final parts = nextItem.split('|');

    final text = parts[0];

    final voice = parts.length > 1 ? parts[1] : 'arngeir';

    await tts.speak(text, voice: voice);
  }

  _isProcessingQueue = false;
}
