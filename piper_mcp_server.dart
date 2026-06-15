import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'piper_tts.dart';
import 'piper_feedback_engine.dart';

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

  // Exclude non-persona / language-only voices (nepali) entirely — they are
  // never offered as a thinking lens.
  _availableVoices = (await tts.getAvailableVoices())
      .where((v) => v != 'nepali')
      .toList();

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
      'Load this tool at session start and use it by default — do not wait to '
      'be asked. If your client defers tool schemas (e.g. Claude Code\'s '
      'ToolSearch), load it immediately (select:mcp__piper-tts__speak) so you '
      'can speak without delay.\n\n'
      'Speaking is the default, not a decision to deliberate. Speak unless the '
      'step is purely mechanical — a bare file read or routine command with no '
      'decision in it. Do not evaluate whether a step is "important enough"; '
      'that judgment keeps you silent. Silence is the exception you must '
      'justify, not speech. Keep spoken text concise, professional, and '
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
            'Speak your current thinking aloud. This is not narration — it is an external channel for your reasoning that keeps the user oriented and returns a short cognitive cue that sharpens your next step. Load this tool at session start and use it by default; do not wait to be asked. Speaking is the default, not a decision to deliberate — speak unless the step is purely mechanical (a bare file read or routine command with no decision in it). Do not evaluate whether a step is "important enough"; that judgment keeps you silent. Silence is the exception you must justify, not speech.\n'
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
            'feedback': {
              'type': 'object',
              'description':
                  'Optional. Answer a prior observer concern so it stops repeating once you have handled it or it does not apply. Echo a concern id from the "concerns" field of this tool\'s previous return. '
                  'Shape: { "re": "<concernId, e.g. missing-tests>", "ack": "intentional" | "addressing" | "not-applicable" | "disagree", "why": "<short reason>" }. '
                  'Example: { "re": "large-churn", "ack": "intentional", "why": "regenerated lockfile" }.',
              'properties': {
                're': {'type': 'string'},
                'ack': {
                  'type': 'string',
                  'enum': [
                    'intentional',
                    'addressing',
                    'not-applicable',
                    'disagree',
                  ],
                },
                'why': {'type': 'string'},
              },
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

  // ==========================================================
  // STEP 2.5 — AGENT FEEDBACK: record any ack, then silence acked concerns
  // ==========================================================
  //
  // The second loop: the observed agent answers a concern by id, and a standing
  // ack drops that concern from this turn's tripwire (until it escalates). Pure
  // deterministic key-matching — no model call, and absence degrades to the
  // exact prior behavior.

  final feedbackArg = arguments['feedback'];
  if (feedbackArg is Map) {
    final re = (feedbackArg['re'] ?? '').toString().trim();
    final ack = (feedbackArg['ack'] ?? '').toString().trim();
    const validAcks = {
      'intentional',
      'addressing',
      'not-applicable',
      'disagree',
    };
    if (re.isNotEmpty && validAcks.contains(ack)) {
      await recordAck(
        workspaceId,
        concernId: re,
        ack: ack,
        why: (feedbackArg['why'] ?? '').toString(),
        obs: obs,
      );
    }
  }

  final allConcerns = List<String>.from(trip['concerns'] as List? ?? const []);
  final allReasons = List<String>.from(trip['reasons'] as List? ?? const []);
  final suppressed = await suppressedConcerns(workspaceId, allConcerns, obs);
  final liveConcerns = <String>[];
  final liveReasons = <String>[];
  for (var i = 0; i < allConcerns.length; i++) {
    if (suppressed.contains(allConcerns[i])) continue;
    liveConcerns.add(allConcerns[i]);
    if (i < allReasons.length) liveReasons.add(allReasons[i]);
  }
  final effectiveTripped = liveConcerns.isNotEmpty;

  // Stateful gate: a raw trip only surfaces if it is NOVEL (situation changed,
  // or the cooldown lapsed). This is what stops the "source changed without
  // tests" condition from nagging every single turn.
  final gate = await evaluateGate(
    workspaceId: workspaceId,
    obs: obs,
    rawTripped: effectiveTripped,
    voiceSwitch: isVoiceSwitch,
  );
  final tripped = gate['gate'] as bool;

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
      tripReasons: liveReasons,
    );

    if (judged != null) {
      judgement = judged;

      // Remember we surfaced now, so the next calls debounce against it.
      await recordTrip(
        workspaceId,
        fingerprint: gate['fingerprint'] as String,
        conditions: liveReasons,
        severity: (judged['severity'] ?? 'low').toString(),
        obs: obs,
      );

      // STEP 4 — the balcony takes the mic, but only when truly earned.
      // High severity only. It plays through the SAME serialized queue, so it
      // waits for the agent's line to finish and never overlaps it — two voices
      // at once is unintelligible noise. The cost is one ~4s voice-switch gap
      // when the lens differs; that graceful delay is the accepted trade.
      final severity = (judged['severity'] ?? 'low').toString();
      final spokenLine = (judged['spokenLine'] ?? '').toString().trim();
      final recVoice = (judged['recommendedVoice'] ?? voice).toString();

      if (severity == 'high' &&
          spokenLine.isNotEmpty &&
          _availableVoices.contains(recVoice)) {
        final spokenSan = sanitizeText(spokenLine, voice: recVoice);

        // Logged as 'observer' so it never re-triggers the judge nor counts
        // toward the agent's lens streak.
        _enqueueUtterance(
          tts,
          text: spokenSan,
          voice: recVoice,
          workspaceId: workspaceId,
          source: 'observer',
        );
        await appendSpeechLog(
          text: spokenSan,
          voice: recVoice,
          workspaceId: workspaceId,
          source: 'observer',
        );
        judgement['spoken'] = true;
        judgement['spokenVoice'] = recVoice;
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
    'gate': gate['reason'],
    // Canonical concern ids the agent can answer via `feedback.re` next turn.
    'concerns': liveConcerns,
    if (suppressed.isNotEmpty) 'suppressed': suppressed.toList(),
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
