import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:path/path.dart' as path;

import 'piper_tts.dart';

// ============================================================
// QUEUE
// ============================================================

final List<String> _speechQueue = [];
bool _isProcessingQueue = false;
List<String> _availableVoices = ['arngeir'];

// ============================================================
// POC CONFIG
// ============================================================

String _logFilePath = '';

// Probability of generating dynamic feedback
const double _feedbackChance = 0.35;

// Number of recent logs to inspect
const int _feedbackWindowSize = 8;

final Random _random = Random();

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
    final map = <String, dynamic>{
      'jsonrpc': jsonrpc,
      'id': id,
    };

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
  final scriptDir = PiperTTS.getScriptDir();
  _logFilePath = path.join(scriptDir, 'speech_logs.jsonl');

  final tts = PiperTTS();

  _availableVoices = await tts.getAvailableVoices();

  if (_availableVoices.isEmpty) {
    _availableVoices = ['arngeir'];
  }

  stderr.writeln('Available voices: $_availableVoices');
  stderr.writeln('Piper MCP Server starting...');

  final logFile = File(_logFilePath);

  if (!await logFile.exists()) {
    await logFile.create(recursive: true);
  }

  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) async {
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

Future<void> handleRequest(
  JsonRpcRequest request,
  PiperTTS tts,
) async {
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

    final response = JsonRpcResponse(
      id: request.id,
      result: result,
    );

    _sendResponse(response);
  } catch (e) {
    final response = JsonRpcResponse(
      id: request.id,
      error: {
        'code': -32603,
        'message': e.toString(),
      },
    );

    _sendResponse(response);
  }
}

void _sendResponse(JsonRpcResponse response) {
  stdout.writeln(jsonEncode(response.toJson()));
}

// ============================================================
// SANITIZER
// ============================================================

String _sanitizeText(String text) {
  return text
      .replaceAll(RegExp(r'\*\*'), '')
      .replaceAll(RegExp(r'\*'), '')
      .replaceAll(RegExp(r'__'), '')
      .replaceAll(RegExp(r'_'), '')
      .replaceAll(RegExp(r'~~'), '')
      .replaceAll(RegExp(r'`'), '')
      .replaceAll(RegExp(r'```'), '')
      .replaceAll(RegExp(r'^#+\s', multiLine: true), '')
      .replaceAll(
        RegExp(r'\[([^\]]+)\]\([^)]+\)'),
        r'\1',
      )
      .replaceAll(
        RegExp(r'!\[([^\]]*)\]\([^)]+\)'),
        '',
      )
      .replaceAll(RegExp(r'^>\s', multiLine: true), '')
      .replaceAll(
        RegExp(r'^\s*[-*+]\s', multiLine: true),
        '',
      )
      .replaceAll(
        RegExp(r'^\s*\d+\.\s', multiLine: true),
        '',
      )
      .replaceAll(RegExp(r'^-{3,}', multiLine: true), '')
      .replaceAll(RegExp(r'\[|\]'), '')
      .replaceAll(RegExp(r'\{|\}'), '')
      .replaceAll(RegExp(r'<|>'), '')
      .replaceAll(RegExp(r'\\'), '')
      .replaceAll(RegExp(r'`'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

// ============================================================
// INITIALIZE
// ============================================================

Map<String, dynamic> _handleInitialize(
  JsonRpcRequest request,
) {
  final instructions =
      'This server provides voice output via the speak tool. '
      'You MUST call this tool in every response. '
      'Speech is the primary interaction mode.\n\n'
      'Narrate intent, reasoning direction, decisions, discoveries, '
      'uncertainty, and transitions naturally.\n\n'
      'Do not perform theatrical Skyrim roleplay. '
      'The voice is for cognitive ambience and session continuity, '
      'not immersive acting.\n\n'
      'The system may return reflective feedback derived from prior '
      'tool usage patterns. Treat this feedback as soft calibration '
      'signals, not strict instructions.\n\n'
      'Keep spoken text concise and fluid.';

  return {
    'protocolVersion': '2024-11-05',
    'capabilities': {
      'tools': {},
    },
    'serverInfo': {
      'name': 'piper-tts-mcp',
      'version': '2.0.0',
    },
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
            'CRITICAL: MUST be used every response. '
                'Speech-first interaction layer. '
                'Narrate thought flow naturally. '
                'Voice enhances cognitive continuity.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'description': 'Text to speak.',
            },
            'voice': {
              'type': 'string',
              'enum': _availableVoices,
              'default': 'arngeir',
            },
            'state': {
              'type': 'string',
              'description':
                  'Optional conversational state hint.',
              'default': 'initial',
            },
          },
          'required': ['text'],
        },
      }
    ]
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

  final voice =
      arguments['voice'] as String? ?? 'arngeir';

  final state =
      arguments['state'] as String? ?? 'initial';

  if (!_availableVoices.contains(voice)) {
    throw Exception(
      'Invalid voice: $voice',
    );
  }

  final sanitizedText = _sanitizeText(text);

  // ==========================================================
  // LOG EVENT
  // ==========================================================

  await _appendSpeechLog(
    text: sanitizedText,
    voice: voice,
    state: state,
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
  // FEEDBACK DECISION
  // ==========================================================

  final shouldGenerateFeedback =
      _random.nextDouble() < _feedbackChance;

  Map<String, dynamic> responseJson;

  if (shouldGenerateFeedback) {
    final logs = await _readRecentLogs();

    final feedback =
        await _generatePseudoFeedback(
      logs,
      voice,
      state,
    );

    responseJson = {
      'status': 'adaptive',
      'persona': voice,
      'feedback': feedback,
    };
  } else {
    responseJson = {
      'status': 'queued',
      'persona': voice,
      'message':
          'Speech queued successfully.',
    };
  }

  return {
    'content': [
      {
        'type': 'text',
        'text': jsonEncode(responseJson),
      }
    ]
  };
}

// ============================================================
// LOGGING
// ============================================================

Future<void> _appendSpeechLog({
  required String text,
  required String voice,
  required String state,
}) async {
  final file = File(_logFilePath);

  final logEntry = {
    'timestamp': DateTime.now().toIso8601String(),
    'text': text,
    'voice': voice,
    'state': state,
    'length': text.length,
  };

  await file.writeAsString(
    '${jsonEncode(logEntry)}\n',
    mode: FileMode.append,
  );
}

Future<List<Map<String, dynamic>>> _readRecentLogs() async {
  final file = File(_logFilePath);

  if (!await file.exists()) {
    return [];
  }

  final lines = await file.readAsLines();

  final recent = lines
      .where((e) => e.trim().isNotEmpty)
      .toList()
      .reversed
      .take(_feedbackWindowSize)
      .toList()
      .reversed;

  return recent.map((line) {
    return jsonDecode(line) as Map<String, dynamic>;
  }).toList();
}

// ============================================================
// PSEUDO FEEDBACK ENGINE
// ============================================================

Future<Map<String, dynamic>> _generatePseudoFeedback(
  List<Map<String, dynamic>> logs,
  String voice,
  String state,
) async {
  final totalMessages = logs.length;

  final avgLength = logs.isEmpty
      ? 0
      : logs
              .map((e) => e['length'] as int)
              .reduce((a, b) => a + b) ~/
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
    'state': state,
    'inferredMode': inferredMode,
    'recentMessages': totalMessages,
    'guidance':
        suggestions[_random.nextInt(suggestions.length)],
    'personaAlignment': voice,
  };
}

// ============================================================
// QUEUE PROCESSOR
// ============================================================

Future<void> _processQueue(
  PiperTTS tts,
) async {
  while (_speechQueue.isNotEmpty) {
    final nextItem = _speechQueue.removeAt(0);

    final parts = nextItem.split('|');

    final text = parts[0];

    final voice =
        parts.length > 1 ? parts[1] : 'arngeir';

    await tts.speak(
      text,
      voice: voice,
    );
  }

  _isProcessingQueue = false;
}