import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

import '../../piper_tts.dart';
import '../llm/piper_local_llm.dart';

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

// ============================================================
// AGENT ACK LEDGER: the second loop — the observed talks back
// ============================================================
//
// The balcony judges the agent but never hears its reply. An ack lets the agent
// answer a specific concern ("that one's intentional / not applicable") so the
// gate stops re-raising it — UNTIL the situation materially escalates, which
// always breaks through. Stored per workspace, per stable concernId. Free and
// deterministic: the dumb gate just matches keys; it never has to "trust".

// "addressing" means the agent says it's fixing the concern now — hold briefly,
// then let it resurface if the fix never lands.
const Duration _ackAddressingTtl = Duration(seconds: 120);

const Map<String, int> _fileRankOrder = {
  '0': 0,
  '1-2': 1,
  '3-5': 2,
  '6-10': 3,
  '10+': 4,
};
const Map<String, int> _churnRankOrder = {
  '0': 0,
  '<50': 1,
  '<150': 2,
  '<500': 3,
  '500+': 4,
};

File _acksFile() {
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  return File(path.join(logsDir.path, 'trip_acks.json'));
}

Future<Map<String, dynamic>> _readAcks() async {
  try {
    final f = _acksFile();
    if (!await f.exists()) return {};
    final content = await f.readAsString();
    if (content.trim().isEmpty) return {};
    return jsonDecode(content) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('Error reading ack ledger: $e');
    return {};
  }
}

// The standing acks for [workspaceId], keyed by concernId.
Future<Map<String, dynamic>> loadAcks(String workspaceId) async {
  final acks = await _readAcks();
  final ws = acks[workspaceId];
  if (ws is Map<String, dynamic>) return ws;
  if (ws is Map) return ws.cast<String, dynamic>();
  return {};
}

// Record the agent's answer to a concern, snapshotting the magnitude NOW so a
// later escalation can be measured against it.
Future<void> recordAck(
  String workspaceId, {
  required String concernId,
  required String ack,
  String? why,
  Map<String, dynamic>? obs,
}) async {
  try {
    final acks = await _readAcks();
    final ws = (acks[workspaceId] is Map)
        ? (acks[workspaceId] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    ws[concernId] = {
      'ts': DateTime.now().toIso8601String(),
      'ack': ack,
      if (why != null && why.trim().isNotEmpty) 'why': why.trim(),
      'files': (obs?['filesChanged'] as int?) ?? 0,
      'churn':
          ((obs?['insertions'] as int?) ?? 0) +
          ((obs?['deletions'] as int?) ?? 0),
      if (obs != null) 'fingerprint': fingerprintObs(obs),
    };
    acks[workspaceId] = ws;
    await _acksFile().writeAsString(jsonEncode(acks));
  } catch (e) {
    stderr.writeln('Error recording ack: $e');
  }
}

// Drop ALL persisted trip + ack state for a single workspace, leaving every
// other workspace's entries intact. Lets a test start from a clean slate without
// nuking the shared ledger files. No-op if the workspace has no stored state.
Future<void> forgetWorkspaceLedger(String workspaceId) async {
  for (final read in [_readLedger, _readAcks]) {
    final isAcks = read == _readAcks;
    try {
      final all = await read();
      if (!all.containsKey(workspaceId)) continue;
      all.remove(workspaceId);
      await (isAcks ? _acksFile() : _ledgerFile())
          .writeAsString(jsonEncode(all));
    } catch (e) {
      stderr.writeln('Error clearing ledger for $workspaceId: $e');
    }
  }
}

// Has the workspace grown materially worse than when [ack] was recorded? A jump
// in the coarse file- or churn-bucket counts as escalation; small follow-on
// edits do not, so one extra line never undoes a dismissal.
bool _ackEscalated(Map<String, dynamic> ack, Map<String, dynamic> obs) {
  final nowFiles = (obs['filesChanged'] as int?) ?? 0;
  final nowChurn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);
  final ackFiles = (ack['files'] as int?) ?? 0;
  final ackChurn = (ack['churn'] as int?) ?? 0;
  final fileJump =
      (_fileRankOrder[_filesBucket(nowFiles)] ?? 0) >
      (_fileRankOrder[_filesBucket(ackFiles)] ?? 0);
  final churnJump =
      (_churnRankOrder[_churnBucket(nowChurn)] ?? 0) >
      (_churnRankOrder[_churnBucket(ackChurn)] ?? 0);
  return fileJump || churnJump;
}

// Of the currently-tripped [concerns], which are silenced by a standing ack?
// Deterministic: dismissive acks (intentional/not-applicable/disagree) hold
// until escalation; "addressing" holds only briefly. Returns the ids to drop
// from this turn's tripwire.
Future<Set<String>> suppressedConcerns(
  String workspaceId,
  List<String> concerns,
  Map<String, dynamic> obs,
) async {
  if (concerns.isEmpty) return {};
  final acks = await loadAcks(workspaceId);
  final now = DateTime.now();
  final out = <String>{};
  for (final c in concerns) {
    final raw = acks[c];
    if (raw is! Map) continue;
    final ack = raw.cast<String, dynamic>();
    if (_ackEscalated(ack, obs)) continue; // grew worse -> let it through
    final kind = (ack['ack'] ?? '').toString();
    if (kind == 'intentional' ||
        kind == 'not-applicable' ||
        kind == 'disagree') {
      out.add(c);
    } else if (kind == 'addressing') {
      final ts = DateTime.tryParse(ack['ts']?.toString() ?? '');
      if (ts != null && now.difference(ts) < _ackAddressingTtl) out.add(c);
    }
  }
  return out;
}

// All standing, non-escalated acks for the workspace as {concern, ack, why}.
// Unlike suppressedConcerns (which gates a specific tripwire), this is the full
// settled-intent picture handed to the LLM judge so it won't re-raise a concern
// the developer already answered — even on a voice-switch turn that judges
// regardless of the tripwire.
Future<List<Map<String, String>>> standingAcks(
  String workspaceId,
  Map<String, dynamic> obs,
) async {
  final acks = await loadAcks(workspaceId);
  final now = DateTime.now();
  final out = <Map<String, String>>[];
  acks.forEach((concern, raw) {
    if (raw is! Map) return;
    final ack = raw.cast<String, dynamic>();
    if (_ackEscalated(ack, obs)) return; // grew worse -> judge should re-raise
    final kind = (ack['ack'] ?? '').toString();
    if (kind == 'addressing') {
      final ts = DateTime.tryParse(ack['ts']?.toString() ?? '');
      if (ts == null || now.difference(ts) >= _ackAddressingTtl) return;
    } else if (kind != 'intentional' &&
        kind != 'not-applicable' &&
        kind != 'disagree') {
      return;
    }
    final why = (ack['why'] ?? '').toString().trim();
    out.add({
      'concern': concern,
      'ack': kind,
      if (why.isNotEmpty) 'why': why,
    });
  });
  return out;
}
