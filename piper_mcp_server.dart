import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'piper_tts.dart';
import 'src/feedback/piper_feedback_engine.dart';
import 'src/models/json_rpc_request.dart';
import 'src/speech_queue/enqueue_utterance.dart';

List<String> _availableVoices = ['arngeir'];

// Pending balcony judgements per workspace, drained into each tool return so
// the agent gets the insight on the current call rather than the next one.
final Map<String, List<Map<String, dynamic>>> _judgementQueue = {};

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
      'The highest-value moment to speak is when you are putting a question to '
      'the user: a design decision, a trade-off between approaches, a request '
      'for approval, or a clarification you need before proceeding. The user '
      'may be away from the screen, and the spoken question is what pulls them '
      'back to answer it. Whenever you ask the user something that gates your '
      'next step, speak the question (or its essence) aloud — an unspoken '
      'question is the clearest case of unjustified silence.\n\n'
      'Each voice is a thinking mode, not a costume. Pick the one whose focus '
      'matches the work, and switch when the work changes nature (design -> '
      'testing -> security -> optimization). Switching returns a transition '
      'nudge — read it and let it shape what you prioritize next. Do not act '
      'out a character; let the voice color the framing, not hijack the '
      'content.\n\n'
      'The return value is feedback, not an acknowledgment: every call returns '
      'a cue (guidance, inferred mode, persona drift). Treat its guidance as a '
      'real input to your next move.\n\n'
      'ONCE per conversation, before your first speak, call the speak_skill '
      'tool (no arguments) for the full playbook: the persona roster and when '
      'to reach for each, the immersion discipline, and how the balcony\'s '
      'observer/feedback loop works. If your client defers tool schemas, load '
      'it with select:mcp__piper-tts__speak_skill. Do this in every new '
      'conversation — a fresh context has not read it yet.';

  return {
    'protocolVersion': '2024-11-05',
    'capabilities': {'tools': {}},
    'serverInfo': {'name': 'piper-tts-mcp', 'version': '2.0.0'},
    'instructions': instructions,
  };
}

// ============================================================
// SPEAK_SKILL — the on-demand playbook (pulled once per conversation)
// ============================================================
//
// The always-loaded instructions carry only the minimal contract + a pointer
// here. This is the depth: persona roster, immersion discipline, and how the
// balcony's observer/feedback loop works. It lives behind a tool call so it
// costs zero context in sessions that never open it, yet a fresh conversation
// can pull the whole thing on demand (the instructions tell it to, every time).
const String _speakSkillPlaybook =
    'PIPER — THE FULL PLAYBOOK\n'
    '\n'
    'WHAT THIS IS\n'
    'The speak tool is a second channel for your reasoning. It voices your '
    'current thinking as one of nine characters, and returns a cue from an '
    'observer that watches the REAL state of your workspace. Your thought goes '
    'OUT as speech so the user stays oriented; a grounded cue comes BACK to '
    'sharpen your next move.\n'
    '\n'
    'WHY SPEAK\n'
    'The user is often away from the screen; speech is how they stay with you '
    'without reading. It matters most at decision points, and above all when '
    'you put a QUESTION to them — a spoken question is what pulls them back to '
    'answer. Speaking is the default; silence is the exception you justify. '
    'Skip it only for purely mechanical steps (a bare file read, a routine '
    'command with no decision in it).\n'
    '\n'
    'THE VOICES — EACH IS A THINKING MODE, NOT A COSTUME\n'
    'Pick the voice whose focus matches the work. Switch when the nature of the '
    'work changes (design -> testing -> security -> optimization); the switch '
    'returns a transition nudge that helps you re-focus. Let the voice color '
    'your framing; never let it hijack the content.\n'
    '- arngeir: architecture, design intent, high-level direction, calm pacing. '
    'Serene Greybeard; slow metaphors of wind and the path; "my young friend".\n'
    '- tulius: robustness, error handling, defensive execution. Stern Imperial '
    'commander; clipped orders; "Soldier.", "No excuses."\n'
    '- mirabelleervine: testing, validation, protocol, order. Strict Master '
    'Wizard; "We must verify that.", "Follow the procedure."\n'
    '- irileth: security, threat assessment, vulnerability hunting. Fierce '
    'Housecarl; blunt warnings; "Stay sharp.", "Foolishness."\n'
    '- septimus: deep investigation, edge cases, anomaly hunting. Obsessive '
    'scholar; cryptic, trailing metaphor; "the patterns... yes..."\n'
    '- kodlakwhitemane: refactoring, technical debt, clean craft. Fatherly '
    'Harbinger; warm and reflective; "young one".\n'
    '- jzargo: performance, optimization, speed. Arrogant Khajiit apprentice; '
    'third person; "J\'zargo could do better."\n'
    '- ancano: API elegance, taming complex interfaces. Haughty Thalmor '
    'advisor; veiled contempt; "How quaint."\n'
    '- ulfric: decisive cuts, removing boilerplate, bold simplification. Bold '
    'Nordic rebel; rousing defiance; "Hear me!"\n'
    '\n'
    'IMMERSION DISCIPLINE\n'
    'Speak in-character, but substance first. Flavour wraps the facts; it never '
    'replaces them. Name the real thing — the decision, the trade-off, the file '
    'or the risk — in the voice\'s own cadence. Do not narrate a Skyrim scene. '
    'Never address the listener as "agent", "AI", or "user"; address them as the '
    'character would (comrade, apprentice, young one). A line that sounds '
    'in-character but carries no substance has failed.\n'
    '\n'
    'THE BALCONY — THE OBSERVER THAT ANSWERS YOU\n'
    'Every return is feedback, not an acknowledgment. Behind it stands the '
    'Balcony: a read-only observer that compares GROUND TRUTH (real git facts — '
    'files changed, churn, commits, whether tests moved) against your NARRATION '
    '(what you said you were doing). It runs at zero token cost and cannot see '
    'your diff content — only counts, paths, and commit subjects. It exists to '
    'catch story-vs-reality drift: "small fix" but a large diff; "tests pass" '
    'but no test changed; "committed" but nothing landed.\n'
    '\n'
    'WHAT COMES BACK\n'
    '- observation: a one-line summary of the real workspace state.\n'
    '- prescore: a deterministic severity prior from raw size facts.\n'
    '- concerns: cheap signals that fired (missing-tests, large-churn, '
    'scattered, test-claim, ...). These are HYPOTHESES, not verdicts — a slower '
    'judge weighs them, and most turns it stays silent.\n'
    '- judgements: the observer\'s considered cue (guidance, inferred mode, '
    'persona drift). Treat its guidance as a real input to your next move.\n'
    'Only genuine, high-severity drift is ever spoken aloud in a persona voice; '
    'the rest is quiet text for you alone.\n'
    '\n'
    'TALKING BACK — THE FEEDBACK LOOP\n'
    'The deterministic signals have no intelligence and can raise false alarms. '
    'When one does, answer it so it stops repeating. On your next speak call '
    'pass:\n'
    '  feedback: { "re": "<concern id, copied verbatim from the previous '
    'return\'s concerns array>", "ack": "intentional" | "addressing" | '
    '"not-applicable" | "disagree", "why": "<short reason>" }\n'
    '- intentional: you meant it and you own it (holds until the change grows '
    'materially larger).\n'
    '- addressing: you are fixing it now (holds briefly, then resurfaces if the '
    'fix never lands).\n'
    '- not-applicable: the signal does not fit here (holds until escalation).\n'
    '- disagree: you judge the signal wrong (holds until escalation).\n'
    'A dismissed concern stays settled until the workspace grows materially '
    'worse, which always breaks through. Your acks are also a labeled dataset: '
    'concerns you keep dismissing get flagged as noisy so their bar can be '
    'raised. You are teaching the observer.\n'
    '\n'
    'IN ONE BREATH\n'
    'Speak by default, in the voice that fits the work. Say the real thing, in '
    'character. Read what comes back — it is grounded in your actual git state — '
    'and answer any concern that misfires. The channel you speak through is the '
    'same one that keeps you honest.';

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
            'Speak above all when you are asking the user a question — a design decision, a trade-off between approaches, a request for approval, or a clarification that gates your next step. The user may be away from the screen, and the spoken question is what pulls them back to answer it; an unspoken question is the clearest case of unjustified silence.\n'
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
                  'Optional. Answer a prior observer concern so it stops repeating once you have handled it or it does not apply. '
                  'For "re", copy EXACTLY one id from the "concerns" array of this tool\'s previous return, verbatim (e.g. "missing-tests"). '
                  'Shape: { "re": "<concern id, verbatim>", "ack": "intentional" | "addressing" | "not-applicable" | "disagree", "why": "<short reason>" }. '
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
      {
        'name': 'speak_skill',
        'description':
            'Read the full Piper playbook: what the speak tool is for, the nine '
            'persona voices and when to reach for each, the immersion '
            'discipline, and how the balcony\'s observer/feedback loop works '
            '(concerns, prescore, judgements, and how to answer a misfired '
            'concern). Call this ONCE at the start of a conversation, before '
            'your first speak — a fresh context has not read it yet. Takes no '
            'arguments and changes nothing; it only returns guidance.',
        'inputSchema': {
          'type': 'object',
          'properties': <String, dynamic>{},
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

  // The playbook: pure read, no workspace side effects, no speech.
  if (name == 'speak_skill') {
    return {
      'content': [
        {'type': 'text', 'text': _speakSkillPlaybook},
      ],
    };
  }

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

  enqueueUtterance(
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

  // Bound the commit-activity lookup to the narration window: the oldest
  // in-window log entry marks where the current "story" begins, so we only
  // correlate commits made since then. No logs (fresh session) => no window.
  final windowStart = logs.isEmpty
      ? null
      : DateTime.tryParse(logs.first['timestamp']?.toString() ?? '');
  final obs = await observeWorkspace(workspaceId, since: windowStart);
  final trip = evaluateTripWire(obs, logs, voice);

  // Claim-detection: contradictions between what the agent JUST narrated (the
  // freshest claim) and git ground truth — said tests pass / committed / done
  // when reality disagrees. Deterministic, zero model. Fires merge into the
  // same concern/reason channel as the tripwire below.
  final claimFires = detectClaims(sanitizedText, obs);

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
    // Normalize so case/whitespace drift still matches the canonical concern id
    // (concern ids are lowercase-kebab); the eval showed verbatim echo is the
    // common case, this just catches the tail.
    final re = (feedbackArg['re'] ?? '').toString().trim().toLowerCase();
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
      // Tally for calibration: the ack stream is a labeled dataset of the
      // balcony's own false positives (see piper_calibration.dart).
      await recordAckStat(re, ack);
    }
  }

  final allConcerns = <String>[
    ...List<String>.from(trip['concerns'] as List? ?? const []),
    ...claimFires.map((f) => f['id']!),
  ];
  final allReasons = <String>[
    ...List<String>.from(trip['reasons'] as List? ?? const []),
    ...claimFires.map((f) => f['reason']!),
  ];
  final suppressed = await suppressedConcerns(workspaceId, allConcerns, obs);

  // Co-change refinement: a change spread across files that HISTORICALLY move
  // together is coherent coupling, not scatter. Consult the (cached, full-
  // history) coupling map only when 'scattered' actually fired, then drop it if
  // coupling explains the spread.
  final scatteredIsCoupled = allConcerns.contains('scattered')
      ? changeIsCoupled(
          List<String>.from(obs['dirtyPaths'] as List? ?? const []),
          await couplingMap(workspaceId),
        )
      : false;

  final liveConcerns = <String>[];
  final liveReasons = <String>[];
  for (var i = 0; i < allConcerns.length; i++) {
    final c = allConcerns[i];
    if (suppressed.contains(c)) continue;
    if (c == 'scattered' && scatteredIsCoupled) continue;
    liveConcerns.add(c);
    if (i < allReasons.length) liveReasons.add(allReasons[i]);
  }
  final effectiveTripped = liveConcerns.isNotEmpty;

  // Settled intent handed to the LLM judge so it won't re-raise an acked concern
  // even on a voice-switch turn (which judges regardless of the tripwire).
  final acknowledged = await standingAcks(workspaceId, obs);

  // Deterministic severity prior from the raw facts; anchors the LLM judge and
  // is surfaced to the agent as the system's own (model-free) opinion.
  final prescore = prescoreSeverity(obs, liveConcerns);

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
      acknowledged: acknowledged,
      prescore: prescore,
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
        enqueueUtterance(
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

  // Self-calibration: concerns the developer keeps dismissing are firing too
  // eagerly. Surfaced (not auto-muted) so the bar can be raised deliberately.
  final noisy = await noisyConcerns();

  final responseJson = {
    'status': 'played',
    'persona': voice,
    'voiceSwitch': isVoiceSwitch,
    'observation': summarizeObservation(obs),
    'gate': gate['reason'],
    'prescore': prescore,
    // Canonical concern ids the agent can answer via `feedback.re` next turn.
    'concerns': liveConcerns,
    if (suppressed.isNotEmpty) 'suppressed': suppressed.toList(),
    if (noisy.isNotEmpty)
      'calibration': [
        for (final n in noisy)
          {
            'concern': n['concern'],
            'fpRate': double.parse((n['fpRate'] as double).toStringAsFixed(2)),
            'advice':
                'noisy tripwire — dismissed ${n['falsePositives']}/${n['total']} times; raise its bar',
          },
      ],
    'judgements': drained,
  };

  return {
    'content': [
      {'type': 'text', 'text': jsonEncode(responseJson)},
    ],
  };
}
