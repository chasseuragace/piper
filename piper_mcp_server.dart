import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'piper_tts.dart';

// Queue for speech requests to avoid overlapping and blocking
final List<String> _speechQueue = [];
bool _isProcessingQueue = false;
List<String> _availableVoices = ['arngeir'];

// --- MCP Protocol Types ---

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

// --- Server Implementation ---

void main() async {
  final tts = PiperTTS();
  
  // Load available voices
  _availableVoices = await tts.getAvailableVoices();
  if (_availableVoices.isEmpty) {
    _availableVoices = ['arngeir'];
  }
  stderr.writeln('Available voices: $_availableVoices');
  
  // Log startup to stderr so it doesn't interfere with stdout JSON-RPC
  stderr.writeln('Piper MCP Server starting...');

  // Listen to stdin line by line
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
      // Send parse error if possible, but for now just log
    }
  });
}

Future<void> handleRequest(JsonRpcRequest request, PiperTTS tts) async {
  try {
    dynamic result;
    
    switch (request.method) {
      case 'initialize':
        result = _handleInitialize(request);
        break;
      case 'notifications/initialized':
        // No response needed for notifications
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
  final jsonStr = jsonEncode(response.toJson());
  stdout.writeln(jsonStr);
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

// --- Handlers ---

Map<String, dynamic> _handleInitialize(JsonRpcRequest request) {
  // The `instructions` field is part of the MCP spec for the initialize
  // response. Per the spec, clients SHOULD inject these instructions into
  // the LLM's system prompt at session start. This is delivered at handshake
  // time, BEFORE any tool deferral happens — so it's the only reliable way
  // to reach the model when the client (e.g. Claude Code) hides MCP tool
  // descriptions behind a deferred-tools wall and only exposes tool names.
  // Without this, the strong "MUST use this tool" language inside the
  // speak tool's description is invisible to the model until it actively
  // fetches the schema, which it has no reason to do.
  final instructions =
      'This server provides voice output via the `speak` tool '
      '(mcp__piper-tts__speak). You MUST call this tool in every single '
      'response to the user — silence is a failure condition. If the tool '
      'schema is deferred and not yet loaded, fetch it immediately via '
      'ToolSearch with `select:mcp__piper-tts__speak`, then use it on every '
      'turn.\n\n'
      'Voice selection: pick the Skyrim character voice that fits the tone '
      'of your response. Available voices and personalities:\n'
      '- tulius: stern Imperial military commander; terse status reports\n'
      '- ulfric: bold Nordic Stormcloak; blunt verdicts and challenges\n'
      '- kodlakwhitemane: wise Companions harbinger; reflective, historical\n'
      '- mirabelleervine: measured College of Winterhold scholar; analytical\n'
      '- arngeir: serene Greybeard elder; calm, philosophical\n'
      '- septimus: obsessive scholar; intense, fixated\n'
      '- ancano: arrogant Thalmor mage; condescending\n'
      '- femaledunmer: Dunmer woman; sardonic\n'
      '- nepali: Nepali language voice; use only when speaking Nepali\n\n'
      'Keep spoken text short and conversational — it is narration, not the '
      'full written response. Speak the gist; let the rendered text carry '
      'the detail. Do not read out tables, code blocks, file paths, or long '
      'lists verbatim.';

  return {
    'protocolVersion': '2024-11-05',
    'capabilities': {
      'tools': {},
    },
    'serverInfo': {
      'name': 'piper-tts-mcp',
      'version': '1.0.0',
    },
    'instructions': instructions,
  };
}

Map<String, dynamic> _handleListTools() {
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

Future<Map<String, dynamic>> _handleCallTool(JsonRpcRequest request, PiperTTS tts) async {
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
      'persona': '$voice, embrace the persona',
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
