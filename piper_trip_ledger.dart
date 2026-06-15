import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

import 'piper_tts.dart';

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
}) async {
  try {
    final ledger = await _readLedger();
    ledger[workspaceId] = {
      'ts': DateTime.now().toIso8601String(),
      'fingerprint': fingerprint,
      'conditions': conditions,
      'severity': severity,
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

  // A voice switch is an intentional signal — always worth a fresh look.
  // Otherwise a raw trip surfaces only when novel: the situation changed, or
  // the cooldown lapsed (a gentle, spaced reminder rather than a per-turn nag).
  final novel = !sameSituation || cooldownElapsed;
  final gate = voiceSwitch || (rawTripped && novel);

  String reason;
  if (gate) {
    reason = voiceSwitch
        ? 'voice switch'
        : last == null
        ? 'first occurrence'
        : !sameSituation
        ? 'situation changed since last trip'
        : 'cooldown elapsed (${secondsAgo}s)';
  } else if (!rawTripped) {
    reason = 'no concern';
  } else {
    reason = 'debounced: same situation flagged ${secondsAgo}s ago';
  }

  return {
    'gate': gate,
    'reason': reason,
    'fingerprint': fingerprint,
    'novel': novel,
    'lastTrip': last,
    'secondsSinceLastTrip': secondsAgo,
  };
}
