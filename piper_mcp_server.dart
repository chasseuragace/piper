import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'piper_tts.dart';
import 'piper_feedback_engine.dart';
import 'piper_whisper.dart';

// ============================================================
// QUEUE
// ============================================================

// Every audible utterance — agent line OR balcony intervention — goes through
// this single serialized queue. That invariant is what keeps a voice switch
// (which restarts the Piper server, ~4s) from ever landing mid-playback: the
// processor awaits each utterance fully, so a restart only happens in the gap
// between finished utterances. Graceful delay, never an abrupt cut.
final List<Map<String, String>> _speechQueue = [];
bool _isProcessingQueue = false;
List<String> _availableVoices = ['arngeir'];

// Pending balcony judgements per workspace, drained into each tool return so
// the agent gets the insight on the current call rather than the next one.
final Map<String, List<Map<String, dynamic>>> _judgementQueue = {};

// Whisper side-channel: high-severity balcony lines play ducked on a second
// Piper instance so they never interrupt or delay the agent's voice. Disable
// with PIPER_WHISPER=0 to fall back to the serialized main queue (graceful gap).
final bool _whisperEnabled = Platform.environment['PIPER_WHISPER'] != '0';
WhisperChannel? _whisper;
WhisperChannel _whisperChannel() => _whisper ??= WhisperChannel();

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
      'If this tool\'s schema is deferred and not yet loaded, load it '
      'immediately at the start of the session via ToolSearch '
      '(select:mcp__piper-tts__speak), then keep it available so you can speak '
      'without being asked.\n\n'
      'By default, narrate your reasoning at each meaningful step: a decision '
      'made, a direction chosen, a milestone reached, or a change in the kind '
      'of work you are doing. Stay silent only for genuinely routine file reads '
      'and shell commands. Keep spoken text concise, professional, and '
      'fluid.\n\n'
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
            'Speak your current thinking aloud. This is not narration — it is an external channel for your reasoning that keeps the user oriented and returns a short cognitive cue that sharpens your next step. By default, speak at each meaningful step: when you reach a conclusion, choose a direction, hit a milestone, or change the kind of work you are doing. Stay silent only for genuinely routine file reads and shell commands.\n'
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
    source: 'agent',
  );

  // ==========================================================
  // STEP 1 — SPEAK IMMEDIATELY (enqueue; plays async, serialized)
  // ==========================================================

  _enqueueUtterance(
    tts,
    text: sanitizedText,
    voice: voice,
    workspaceId: workspaceId,
    source: 'agent',
  );

  final lastVoices = await loadLastVoices();
  final lastVoice = lastVoices[workspaceId] ?? 'arngeir';
  final isVoiceSwitch = lastVoice != voice;
  await saveLastVoice(workspaceId, voice);

  // ==========================================================
  // STEP 2 — OBSERVE (cheap, zero tokens): step onto the balcony
  // ==========================================================

  final obs = await observeWorkspace(workspaceId);
  final trip = evaluateTripWire(obs, logs, voice);
  final tripped = (trip['tripped'] as bool) || isVoiceSwitch;

  // ==========================================================
  // STEP 3 — JUDGE (LLM) only when warranted; else fast cue
  // ==========================================================

  Map<String, dynamic> judgement;
  if (tripped) {
    final judged = await judgeWorkspace(
      workspaceId: workspaceId,
      voice: voice,
      logs: logs,
      obs: obs,
      tripReasons: List<String>.from(trip['reasons'] as List),
    );

    if (judged != null) {
      judgement = judged;

      // STEP 4 — the balcony takes the mic, but only when truly earned.
      // High severity only: a different lens cutting in costs a ~4s graceful
      // voice switch, so it must be worth interrupting the rhythm for.
      final severity = (judged['severity'] ?? 'low').toString();
      final spokenLine = (judged['spokenLine'] ?? '').toString().trim();
      final recVoice = (judged['recommendedVoice'] ?? voice).toString();

      if (severity == 'high' &&
          spokenLine.isNotEmpty &&
          _availableVoices.contains(recVoice)) {
        final spokenSan = sanitizeText(spokenLine, voice: recVoice);

        // Prefer the whisper side-channel: ducked overlap on a second instance,
        // so the agent's voice is neither interrupted nor delayed. If whispering
        // is disabled, or a whisper is already in flight, fall back to the
        // serialized main queue (plays after the agent's line, graceful gap).
        var channel = 'main';
        if (_whisperEnabled) {
          final launched = await _whisperChannel().whisper(
            spokenSan,
            recVoice,
            workspaceId,
          );
          if (launched) channel = 'whisper';
        }
        if (channel == 'main') {
          _enqueueUtterance(
            tts,
            text: spokenSan,
            voice: recVoice,
            workspaceId: workspaceId,
            source: 'observer',
          );
        }

        // Log either way (source 'observer' so it never re-triggers the judge
        // nor counts toward the agent's lens streak).
        await appendSpeechLog(
          text: spokenSan,
          voice: recVoice,
          workspaceId: workspaceId,
          source: 'observer',
        );
        judgement['spoken'] = true;
        judgement['spokenVoice'] = recVoice;
        judgement['spokenChannel'] = channel;
      } else {
        judgement['spoken'] = false;
      }
    } else {
      // LLM unavailable/failed — degrade to the cheap cue, still grounded.
      judgement = await generatePseudoFeedback(logs, voice, workspaceId);
      judgement['observation'] = summarizeObservation(obs);
    }
  } else {
    // Fast path: nothing tripped. Keep the speak -> think loop closed with the
    // cheap deterministic cue (no tokens), now grounded with the observation.
    judgement = await generatePseudoFeedback(logs, voice, workspaceId);
    judgement['observation'] = summarizeObservation(obs);
    final streak = trip['streak'] as int;
    if (streak >= 5) {
      judgement['drift'] =
          'You have held the $voice lens for $streak turns. If the work has '
          'shifted, consider handing the mic to a better-matched persona.';
    }
  }

  // ==========================================================
  // STEP 5 — RETURN WITH THE JUDGEMENT QUEUE (this turn, not the next)
  // ==========================================================

  final wsQueue = _judgementQueue.putIfAbsent(workspaceId, () => []);
  wsQueue.add(judgement);
  final drained = List<Map<String, dynamic>>.from(wsQueue);
  wsQueue.clear();

  final responseJson = {
    'status': 'played',
    'persona': voice,
    'voiceSwitch': isVoiceSwitch,
    'observation': summarizeObservation(obs),
    'judgements': drained,
  };

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

// Single entry point for ALL audible output. Enqueue, never call tts.speak
// directly — that is the invariant that prevents mid-playback restarts.
void _enqueueUtterance(
  PiperTTS tts, {
  required String text,
  required String voice,
  required String workspaceId,
  required String source,
}) {
  _speechQueue.add({
    'text': text,
    'voice': voice,
    'workspaceId': workspaceId,
    'source': source,
  });
  if (!_isProcessingQueue) {
    _isProcessingQueue = true;
    _processQueue(tts);
  }
}

Future<void> _processQueue(PiperTTS tts) async {
  while (_speechQueue.isNotEmpty) {
    final item = _speechQueue.removeAt(0);
    final text = item['text'] ?? '';
    final voice = item['voice'] ?? 'arngeir';
    final workspaceId = item['workspaceId'] ?? Directory.current.path;

    if (text.trim().isEmpty) continue;

    // Claim the shared audio channel (file-backed, cross-process) for the full
    // duration of this utterance, then release. Other Piper instances see this
    // and hold off, so audio never overlaps; the TTL clears it if we crash.
    await markSpeaking(voice, workspaceId);
    try {
      await tts.speak(text, voice: voice);
    } catch (e) {
      stderr.writeln('Error speaking queued item: $e');
    } finally {
      await clearSpeaking();
    }
  }

  _isProcessingQueue = false;
}
