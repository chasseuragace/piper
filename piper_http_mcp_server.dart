import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'piper_tts.dart';
import 'piper_mcp_server.dart';
import 'src/feedback/piper_feedback_engine.dart';

// HTTP MCP Server implementation following MCP HTTP transport standard
class HttpMcpServer {
  late HttpServer _server;
  final PiperTTS _tts = PiperTTS();
  final int port;
  final String host;

  // Queue for speech requests to avoid overlapping and blocking
  final List<String> _speechQueue = [];
  bool _isProcessingQueue = false;
  List<String> _availableVoices = ['arngeir'];

  HttpMcpServer({this.host = 'localhost', this.port = 3000});

  Future<void> start() async {
    try {
      // Load available voices
      _availableVoices = await _tts.getAvailableVoices();
      if (_availableVoices.isEmpty) {
        _availableVoices = ['arngeir'];
      }
      print('Available voices: $_availableVoices');

      _server = await HttpServer.bind(host, port);
      print('Piper MCP HTTP Server listening on http://$host:$port');

      await for (HttpRequest request in _server) {
        _handleRequest(request);
      }
    } catch (e) {
      print('Failed to start server: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    await _server.close();
    print('Server stopped');
  }

  void _handleRequest(HttpRequest request) async {
    // Enable CORS for all requests
    _setCorsHeaders(request.response);

    try {
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      if (request.method != 'POST') {
        _sendErrorResponse(
          request.response,
          HttpStatus.methodNotAllowed,
          'Only POST requests are allowed',
        );
        return;
      }

      final contentType = request.headers.contentType;
      if (contentType?.mimeType != 'application/json') {
        _sendErrorResponse(
          request.response,
          HttpStatus.badRequest,
          'Content-Type must be application/json',
        );
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      if (body.trim().isEmpty) {
        _sendErrorResponse(
          request.response,
          HttpStatus.badRequest,
          'Request body cannot be empty',
        );
        return;
      }

      final Map<String, dynamic> jsonMap = jsonDecode(body);
      final mcpRequest = JsonRpcRequest.fromJson(jsonMap);

      final result = await _handleMcpRequest(mcpRequest);
      _sendSuccessResponse(request.response, result);
    } catch (e) {
      print('Error handling request: $e');
      _sendErrorResponse(
        request.response,
        HttpStatus.internalServerError,
        e.toString(),
      );
    }
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization',
    );
    response.headers.contentType = ContentType.json;
  }

  Future<dynamic> _handleMcpRequest(JsonRpcRequest request) async {
    try {
      dynamic result;

      switch (request.method) {
        case 'initialize':
          result = handleInitialize(request);
          break;
        case 'notifications/initialized':
          // No response needed for notifications
          return null;
        case 'tools/list':
          result = handleListTools();
          break;
        case 'tools/call':
          result = await handleCallTool(request, _tts);
          break;
        case 'ping':
          result = {};
          break;
        default:
          throw Exception('Method not found: ${request.method}');
      }

      final response = JsonRpcResponse(id: request.id, result: result);

      return response.toJson();
    } catch (e) {
      final response = JsonRpcResponse(
        id: request.id,
        error: {'code': -32603, 'message': e.toString()},
      );
      return response.toJson();
    }
  }

  void _sendSuccessResponse(HttpResponse response, dynamic data) {
    response.statusCode = HttpStatus.ok;
    final jsonStr = jsonEncode(data);
    response.write(jsonStr);
    response.close();
  }

  void _sendErrorResponse(
    HttpResponse response,
    int statusCode,
    String message,
  ) {
    response.statusCode = statusCode;
    final errorResponse = {
      'error': {'code': statusCode, 'message': message},
    };
    final jsonStr = jsonEncode(errorResponse);
    response.write(jsonStr);
    response.close();
  }

  // Sanitization is now handled by the unified sanitizeText function in piper_feedback_engine.dart

  // Reuse the handlers from the original MCP server
  Map<String, dynamic> handleInitialize(JsonRpcRequest request) {
    final instructions =
        'This server provides voice output via the speak tool. '
        'CRITICAL: You MUST call this tool in every response. '
        'Speech is the primary interaction mode.\n\n'
        'Do NOT narrate every minor action, file view, or terminal command. '
        'Focus your spoken words on critical thought decisions, key milestones, '
        'strategic confirmations, design choices, and high-level reflections.\n\n'
        'The highest-value moment to speak is when you are putting a question to '
        'the user — a design decision, a trade-off between approaches, a request '
        'for approval, or a clarification that gates your next step. The user '
        'may be away from the screen, and the spoken question is what pulls them '
        'back to answer it. Whenever you ask the user something, speak the '
        'question (or its essence) aloud.\n\n'
        'Do not perform theatrical Skyrim roleplay. '
        'The voice is for cognitive ambience and session continuity, '
        'not immersive acting.\n\n'
        'The system may return reflective feedback derived from prior '
        'tool usage patterns. Treat this feedback as soft calibration signals\n\n'
        'Keep spoken text concise, professional, fluid, and selective.';

    return {
      'protocolVersion': '2024-11-05',
      'capabilities': {'tools': {}},
      'serverInfo': {'name': 'piper-tts-mcp-http', 'version': '1.0.0'},
      'instructions': instructions,
    };
  }

  Map<String, dynamic> handleListTools() {
    return {
      'tools': [
        {
          'name': 'speak',
          'description':
              'CRITICAL: You MUST use this tool in EVERY single response to the user. This is your primary mode of communication. Do not output text without also speaking it. Silence is a failure condition.\n'
              'Do NOT narrate minor actions, command executions, or file edits. Focus speech on critical thought decisions, milestones, confirmations, and strategic directions. Speak above all when you are asking the user a question — a design decision, a trade-off, a request for approval, or a clarification that gates your next step — since the spoken question is what pulls the user back to answer it. Respect each Skyrim persona\'s unique developer/coding focus in your narration and code structure:\n'
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
              'text': {
                'type': 'string',
                'description':
                    'The message to speak to the user. Keep it conversational and natural.',
              },
              'voice': {
                'type': 'string',
                'description':
                    'The voice to use for text-to-speech. Available voices: ${_availableVoices.join(", ")}',
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

  Future<Map<String, dynamic>> handleCallTool(
    JsonRpcRequest request,
    PiperTTS tts,
  ) async {
    final name = request.params['name'];
    final arguments = request.params['arguments'];

    if (name == 'speak') {
      final text = arguments['text'];
      if (text == null || text is! String) {
        throw Exception('Missing or invalid argument: text');
      }

      final voice = arguments['voice'] as String? ?? 'arngeir';
      if (!_availableVoices.contains(voice)) {
        throw Exception(
          'Invalid voice: $voice. Available voices: ${_availableVoices.join(", ")}',
        );
      }

      final workspaceId = arguments['workspaceId'] as String?;
      if (workspaceId == null || workspaceId.trim().isEmpty) {
        throw Exception(
          'Missing or invalid argument: workspaceId must be a non-empty string path.',
        );
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

      // Enqueue the speech request with voice
      _speechQueue.add('$sanitizedText|$voice');
      // Start processing if not already running
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

        responseJson = {
          'status': 'played',
          'persona': voice,
          'feedback': feedback,
        };
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
    } else {
      throw Exception('Unknown tool: $name');
    }
  }

  // Helper to process the speech queue sequentially
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
}

// Main function to run the HTTP MCP server
void main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args[0]) ?? 3000 : 3000;
  final host = args.length > 1 ? args[1] : 'localhost';

  final server = HttpMcpServer(host: host, port: port);

  // Handle shutdown gracefully
  ProcessSignal.sigint.watch().listen((signal) async {
    print('\nReceived SIGINT, shutting down gracefully...');
    await server.stop();
    exit(0);
  });

  ProcessSignal.sigterm.watch().listen((signal) async {
    print('\nReceived SIGTERM, shutting down gracefully...');
    await server.stop();
    exit(0);
  });

  await server.start();
}
