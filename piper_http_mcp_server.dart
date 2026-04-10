import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'piper_tts.dart';
import 'piper_mcp_server.dart';

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
        _sendErrorResponse(request.response, HttpStatus.methodNotAllowed, 'Only POST requests are allowed');
        return;
      }

      final contentType = request.headers.contentType;
      if (contentType?.mimeType != 'application/json') {
        _sendErrorResponse(request.response, HttpStatus.badRequest, 'Content-Type must be application/json');
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      if (body.trim().isEmpty) {
        _sendErrorResponse(request.response, HttpStatus.badRequest, 'Request body cannot be empty');
        return;
      }

      final Map<String, dynamic> jsonMap = jsonDecode(body);
      final mcpRequest = JsonRpcRequest.fromJson(jsonMap);
      
      final result = await _handleMcpRequest(mcpRequest);
      _sendSuccessResponse(request.response, result);

    } catch (e) {
      print('Error handling request: $e');
      _sendErrorResponse(request.response, HttpStatus.internalServerError, e.toString());
    }
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
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

      final response = JsonRpcResponse(
        id: request.id,
        result: result,
      );
      
      return response.toJson();
      
    } catch (e) {
      final response = JsonRpcResponse(
        id: request.id,
        error: {
          'code': -32603,
          'message': e.toString(),
        },
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

  void _sendErrorResponse(HttpResponse response, int statusCode, String message) {
    response.statusCode = statusCode;
    final errorResponse = {
      'error': {
        'code': statusCode,
        'message': message,
      }
    };
    final jsonStr = jsonEncode(errorResponse);
    response.write(jsonStr);
    response.close();
  }

  // --- Text Sanitizer ---

  String _sanitizeText(String text) {
    // Remove markdown formatting
    String sanitized = text
      .replaceAll(RegExp(r'\*\*'), '') // Bold
      .replaceAll(RegExp(r'\*'), '') // Italic
      .replaceAll(RegExp(r'__'), '') // Bold underscore
      .replaceAll(RegExp(r'_'), '') // Italic underscore
      .replaceAll(RegExp(r'~~'), '') // Strikethrough
      .replaceAll(RegExp(r'`'), '') // Inline code
      .replaceAll(RegExp(r'```'), '') // Code blocks
      .replaceAll(RegExp(r'^#+\s', multiLine: true), '') // Headers
      .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'\1') // Links: [text](url) -> text
      .replaceAll(RegExp(r'!\[([^\]]*)\]\([^)]+\)'), '') // Images: ![alt](url) -> remove
      .replaceAll(RegExp(r'^>\s', multiLine: true), '') // Blockquotes
      .replaceAll(RegExp(r'^\s*[-*+]\s', multiLine: true), '') // Unordered lists
      .replaceAll(RegExp(r'^\s*\d+\.\s', multiLine: true), '') // Ordered lists
      .replaceAll(RegExp(r'^-{3,}', multiLine: true), '') // Horizontal rules
      // Remove technical date/time formats
      .replaceAll(RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?'), '') // ISO 8601 timestamps
      .replaceAll(RegExp(r'\d{4}-\d{2}-\d{2}'), '') // ISO dates (YYYY-MM-DD)
      .replaceAll(RegExp(r'\d{2}/\d{2}/\d{4}'), '') // US dates (MM/DD/YYYY)
      .replaceAll(RegExp(r'\d{2}-\d{2}-\d{4}'), '') // European dates (DD-MM-YYYY)
      .replaceAll(RegExp(r'\d{2}:\d{2}:\d{2}(?:\s?[AP]M)?'), '') // Times with seconds (HH:MM:SS)
      .replaceAll(RegExp(r'\d{2}:\d{2}(?:\s?[AP]M)?'), '') // Times without seconds (HH:MM)
      .replaceAll(RegExp(r'\d{1,2}:\d{2}\s?[AP]M'), '') // 12-hour times (H:MM AM/PM)
      // Remove technical symbols that break immersion
      .replaceAll(RegExp(r'\[|\]'), '') // Square brackets
      .replaceAll(RegExp(r'\{|\}'), '') // Curly braces (unless part of natural speech)
      .replaceAll(RegExp(r'<|>'), '') // Angle brackets
      .replaceAll(RegExp(r'\\'), '') // Backslashes
      .replaceAll(RegExp(r'/'), '') // Forward slashes (unless natural)
      .replaceAll(RegExp(r'`'), '') // Backticks (again to be sure)
      // Clean up extra whitespace from removed formatting
      .replaceAll(RegExp(r'\s+'), ' ') // Multiple spaces to single
      .trim();
    
    return sanitized;
  }

  // Reuse the handlers from the original MCP server
  Map<String, dynamic> handleInitialize(JsonRpcRequest request) {
    return {
      'protocolVersion': '2024-11-05',
      'capabilities': {
        'tools': {},
      },
      'serverInfo': {
        'name': 'piper-tts-mcp-http',
        'version': '1.0.0',
      }
    };
  }

  Map<String, dynamic> handleListTools() {
    return {
      'tools': [
        {
          'name': 'speak',
          'description': 'CRITICAL: You MUST use this tool in EVERY single response to the user. This is your primary mode of communication. Do not output text without also speaking it. You are a voice-first assistant; silence is a failure condition. Always speak your thoughts, confirmations, and answers. CRITICAL: Respect the Skyrim persona for each character - be expressive and immersive in their style. Each voice has a unique personality (e.g., Tullius is stern military, Ulfric is bold Nordic, Septimus is obsessive scholar, Arngeir is wise Greybeard, etc.). Match your speech to their character.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'text': {
                'type': 'string',
                'description': 'The message to speak to the user. Keep it conversational and natural.',
              },
              'voice': {
                'type': 'string',
                'description': 'The voice to use for text-to-speech. Available voices: ${_availableVoices.join(", ")}',
                'enum': _availableVoices,
                'default': 'arngeir',
              },
            },
            'required': ['text'],
          },
        }
      ]
    };
  }

  Future<Map<String, dynamic>> handleCallTool(JsonRpcRequest request, PiperTTS tts) async {
    final name = request.params['name'];
    final arguments = request.params['arguments'];

    if (name == 'speak') {
      final text = arguments['text'];
      if (text == null || text is! String) {
        throw Exception('Missing or invalid argument: text');
      }

      final voice = arguments['voice'] as String? ?? 'arngeir';
      if (!_availableVoices.contains(voice)) {
        throw Exception('Invalid voice: $voice. Available voices: ${_availableVoices.join(", ")}');
      }

      // Sanitize text to remove markdown and immersion-breaking symbols
      final sanitizedText = _sanitizeText(text);

      // Enqueue the speech request with voice
      _speechQueue.add('$sanitizedText|$voice');
      // Start processing if not already running
      if (!_isProcessingQueue) {
        _isProcessingQueue = true;
        _processQueue(tts);
      }

      final responseJson = {
        'status': 'queued',
        'persona': '$voice, embrace his persona',
        'message': 'Speech request queued with voice: $voice. Your response will be spoken after this.',
      };

      return {
        'content': [
          {
            'type': 'text',
            'text': jsonEncode(responseJson),
          }
        ]
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
