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
      'Speech is a second channel for your reasoning. The speak tool lets you '
      'externalize your thinking so the user stays oriented, and it returns a '
      'short cognitive cue that sharpens your next step.\n\n'
      'Use it when your thinking reaches a boundary: a decision made, a '
      'direction chosen, a milestone reached, or a change in the kind of work '
      'you are doing. Skip it for routine file reads and shell commands. Keep '
      'spoken text concise, professional, and fluid.\n\n'
      'Each voice is a thinking mode, not a costume. Pick the one whose focus '
      'matches the work, and switch when the work changes nature (design -> '
      'testing -> security -> optimization). Switching returns a transition '
      'nudge — read it and let it shape what you prioritize next. Do not act '
      'out a character; let the voice color the framing, not hijack the '
      'content.\n\n'
      'The return value is feedback, not an acknowledgment: every call returns '
      'a cue (guidance, inferred mode, persona drift). Treat its guidance as a '
      'real input to your next move.';

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
            'Speak your current thinking aloud. This is not narration — it is an external channel for your reasoning that keeps the user oriented and returns a short cognitive cue that sharpens your next step. Use it at decision points: when you have reached a conclusion, chosen a direction, hit a milestone, or changed the kind of work you are doing. Skip it for routine file reads and shell commands.\n'
            'Each voice is a thinking mode, not a costume. Pick the one whose focus matches the work, and switch when the work changes — switching returns a transition nudge that helps you re-focus. Do not act out a character; let the voice color the framing, not hijack the content.\n'
            '- arngeir (Arngeir): architecture, design intent, high-level direction, calm pacing.\n'
            '- tulius (General Tullius): robustness, error handling, defensive execution, tactical strictness.\n'
            '- mirabelleervine (Mirabelle Ervine): testing, validation, protocol, organizational order.\n'
            '- irileth (Irileth): security, threat assessment, vulnerability hunting, defensive vigilance.\n'
            '- septimus (Septimus Signus): deep investigation, edge cases, anomaly hunting, irregular patterns.\n'
            '- kodlakwhitemane (Kodlak Whitemane): refactoring, technical debt, clean craftsmanship.\n'
            '- jzargo (J\'zargo): performance, optimization, speed.\n'
            '- ancano (Ancano): API elegance, taming complex interfaces, refined control.\n'
            '- ulfric (Ulfric Stormcloak): decisive cuts, removing boilerplate, bold simplification.',
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
                  'Optional. Your current working directory (your pwd) to scope session context and continuity. Defaults to the server working directory if omitted.',
            },
          },
          'required': ['text'],
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

  // workspaceId is optional: scope to the caller's pwd when provided, else
  // fall back to the server's working directory so a missing arg never blocks
  // speech.
  final rawWorkspaceId = (arguments['workspaceId'] as String?)?.trim();
  final workspaceId = (rawWorkspaceId == null || rawWorkspaceId.isEmpty)
      ? Directory.current.path
      : rawWorkspaceId;

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
    // Always-on cognitive cue: keep the speak -> think loop closed even when
    // the persona is unchanged, so the tool stays part of reasoning rather
    // than a fire-and-forget side effect. Cheap and deterministic (no AI call).
    final cue = await generatePseudoFeedback(logs, voice, workspaceId);

    // Persona-drift hint: how many consecutive turns has this single voice
    // held the mic? A long streak suggests the work may have moved on.
    int streak = 1;
    for (final entry in logs.reversed) {
      if (entry['voice'] == voice) {
        streak++;
      } else {
        break;
      }
    }
    if (streak >= 5) {
      cue['drift'] =
          'You have held the $voice lens for $streak turns. If the work has '
          'shifted, consider handing the mic to a better-matched persona.';
    }

    responseJson = {'status': 'played', 'persona': voice, 'cue': cue};
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
