import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

import 'piper_tts.dart';
import 'piper_local_llm.dart';

// ============================================================
// TRIP LEDGER: STATEFUL, NOVELTY-AWARE GATING
// ============================================================
//
// The raw tripwire (evaluateTripWire) answers "is the workspace state
// concerning?" — but a true-yet-stale condition (e.g. "source changed without
// tests") would fire on every single call, nagging about something it already
// flagged. A human pair says it once, then stays quiet until something changes.
//
// The ledger gives the gate that memory: it records the last time we actually
// surfaced a concern, with a coarse FINGERPRINT of the state at that moment.
// A raw trip is only allowed through if it is NOVEL — the fingerprint changed,
// or enough time has passed that a gentle reminder is warranted. This is free
// and deterministic; it is also the exact context a future LLM gate would need.

const Duration _tripCooldown = Duration(seconds: 90);

File _ledgerFile() {
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  return File(path.join(logsDir.path, 'trip_ledger.json'));
}

String _filesBucket(int n) => n == 0
    ? '0'
    : n <= 2
    ? '1-2'
    : n <= 5
    ? '3-5'
    : n <= 10
    ? '6-10'
    : '10+';

String _churnBucket(int n) => n == 0
    ? '0'
    : n < 50
    ? '<50'
    : n < 150
    ? '<150'
    : n < 500
    ? '<500'
    : '500+';

// A coarse signature of the observation. Two states with the same fingerprint
// are "the same situation" for gating purposes — small edits don't re-trigger.
String fingerprintObs(Map<String, dynamic> obs) {
  final files = (obs['filesChanged'] as int?) ?? 0;
  final churn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);
  final mods = ((obs['modules'] as Map?)?.keys.toList() ?? <String>[])
    ..sort();
  return 'f:${_filesBucket(files)};c:${_churnBucket(churn)};'
      'm:${mods.join(",")};s:${obs['srcTouched'] == true};'
      't:${obs['testTouched'] == true}';
}

Future<Map<String, dynamic>> _readLedger() async {
  try {
    final f = _ledgerFile();
    if (!await f.exists()) return {};
    final content = await f.readAsString();
    if (content.trim().isEmpty) return {};
    return jsonDecode(content) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('Error reading trip ledger: $e');
    return {};
  }
}

// The last trip we surfaced for [workspaceId], or null.
Future<Map<String, dynamic>?> lastTrip(String workspaceId) async {
  final ledger = await _readLedger();
  final entry = ledger[workspaceId];
  return entry is Map<String, dynamic> ? entry : null;
}

// Record that we surfaced a concern now, so future calls can debounce against it.
Future<void> recordTrip(
  String workspaceId, {
  required String fingerprint,
  required List<String> conditions,
  required String severity,
  Map<String, dynamic>? obs,
}) async {
  try {
    final ledger = await _readLedger();
    ledger[workspaceId] = {
      'ts': DateTime.now().toIso8601String(),
      'fingerprint': fingerprint,
      'conditions': conditions,
      'severity': severity,
      // Raw numbers so a future repeat can be described to the gate in concrete
      // terms ("3 files -> 12 files") rather than opaque fingerprints.
      'files': (obs?['filesChanged'] as int?) ?? 0,
      'churn':
          ((obs?['insertions'] as int?) ?? 0) +
          ((obs?['deletions'] as int?) ?? 0),
    };
    await _ledgerFile().writeAsString(jsonEncode(ledger));
  } catch (e) {
    stderr.writeln('Error recording trip: $e');
  }
}

// The gate decision: should this raw trip actually surface, or be debounced?
//
// Returns the decision plus the context a smarter (LLM) gate would consume —
// the current fingerprint, the last trip, and how long ago it fired — so this
// function can later delegate the ambiguous middle without changing callers.
Future<Map<String, dynamic>> evaluateGate({
  required String workspaceId,
  required Map<String, dynamic> obs,
  required bool rawTripped,
  required bool voiceSwitch,
}) async {
  final fingerprint = fingerprintObs(obs);
  final last = await lastTrip(workspaceId);
  final now = DateTime.now();

  int? secondsAgo;
  bool cooldownElapsed = true;
  bool sameSituation = false;
  if (last != null) {
    final ts = DateTime.tryParse(last['ts']?.toString() ?? '');
    if (ts != null) {
      secondsAgo = now.difference(ts).inSeconds;
      cooldownElapsed = now.difference(ts) >= _tripCooldown;
    }
    sameSituation = last['fingerprint'] == fingerprint;
  }

  // Decide. Clear cases are deterministic and free; the ambiguous middle — a
  // REPEAT trip where we've spoken before — is delegated to the on-device LLM
  // gate (free, local), which weighs "is it worth speaking again?" given when
  // we last spoke. Deterministic novelty (situation changed OR cooldown lapsed)
  // is the fallback when the local model is unavailable.
  bool gate;
  String reason;
  final deterministicNovel = !sameSituation || cooldownElapsed;

  if (voiceSwitch) {
    gate = true;
    reason = 'voice switch';
  } else if (!rawTripped) {
    gate = false;
    reason = 'no concern';
  } else if (last == null) {
    gate = true;
    reason = 'first occurrence';
  } else {
    // Repeat trip — ask the on-device gate whether to re-surface.
    final llm = await _llmGateDecision(
      obs: obs,
      fingerprint: fingerprint,
      last: last,
      secondsAgo: secondsAgo,
    );
    if (llm != null) {
      gate = llm;
      reason = llm ? 'llm gate: re-surface' : 'llm gate: stay quiet';
    } else {
      gate = deterministicNovel;
      reason = deterministicNovel
          ? (!sameSituation
                ? 'situation changed since last trip'
                : 'cooldown elapsed (${secondsAgo}s)')
          : 'debounced: same situation flagged ${secondsAgo}s ago';
    }
  }

  return {
    'gate': gate,
    'reason': reason,
    'fingerprint': fingerprint,
    'novel': deterministicNovel,
    'lastTrip': last,
    'secondsSinceLastTrip': secondsAgo,
  };
}

// The L2 gate: a tiny, free, on-device call that decides whether a REPEAT
// concern is worth voicing again, given how long ago we last spoke and whether
// the situation drifted. Prefers silence. Returns null if no model is reachable
// (caller falls back to deterministic novelty).
Future<bool?> _llmGateDecision({
  required Map<String, dynamic> obs,
  required String fingerprint,
  required Map<String, dynamic> last,
  required int? secondsAgo,
}) async {
  final systemPrompt =
      'A code observer already warned the developer about an issue a short '
      'while ago. Decide if it should repeat the warning now. Rule: answer true '
      'ONLY if the amount of changed code grew clearly larger since last time '
      '(roughly half again as much or more), OR a long time has passed. If the '
      'change is about the same or smaller, answer false to avoid nagging. '
      'Return ONLY JSON: {"shouldSurface": true or false, "why": "few words"}.';

  final files = (obs['filesChanged'] as int?) ?? 0;
  final churn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);
  final lastFiles = (last['files'] as int?) ?? 0;
  final lastChurn = (last['churn'] as int?) ?? 0;
  final prompt =
      'Last warning: "${(last['conditions'] as List?)?.join(", ")}", '
      '${secondsAgo ?? '?'} seconds ago.\n'
      'Code changed THEN: $lastFiles files, $lastChurn lines.\n'
      'Code changed NOW: $files files, $churn lines.\n'
      'Repeat the warning?';

  final r = await cheapJson(prompt, systemPrompt: systemPrompt, maxTokens: 60);
  if (r == null) return null;
  final v = r['shouldSurface'];
  if (v is bool) return v;
  if (v is String) return v.toLowerCase() == 'true';
  return null;
}
