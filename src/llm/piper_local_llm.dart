import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../../piper_tts.dart';
import 'piper_ai_client.dart';

// ============================================================
// LOCAL LLM: APPLE ON-DEVICE BRIDGE (FREE, PRIVATE) + CLOUD FALLBACK
// ============================================================
//
// Cheap/frequent calls (the L2 gate, log compaction) prefer Apple's on-device
// foundation model via a small Swift bridge exposing an OpenAI-compatible
// endpoint. It's free, private, and fast enough to call liberally — which is
// what makes per-call LLM gating affordable.
//
// Lifecycle mirrors the Python TTS server: the bridge is spawned ON DEMAND and
// kept warm for the process lifetime (it prewarms the model at startup). If it
// can't be reached or started, every call falls back to the cloud client, so
// the bridge is an optimization, never a hard dependency.

const int _bridgePort = 8765;
bool _spawning = false;

Future<bool> _bridgeUp() async {
  try {
    final s = await Socket.connect(
      '127.0.0.1',
      _bridgePort,
      timeout: const Duration(seconds: 1),
    );
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

// Compiles the bridge binary on demand if missing or stale (source newer than
// binary). One-time cost; mirrors how the TTS server is brought up by the act
// of using it — no separate setup step. Returns false if swiftc is unavailable
// or compilation fails (caller falls back to cloud).
Future<bool> _ensureBridgeBuilt(String dir) async {
  final src = File(path.join(dir, 'bridge.swift'));
  final bin = File(path.join(dir, 'bridge'));
  if (!src.existsSync()) {
    stderr.writeln('Apple bridge source not found at ${src.path}');
    return false;
  }
  final fresh =
      bin.existsSync() &&
      !src.lastModifiedSync().isAfter(bin.lastModifiedSync());
  if (fresh) return true;

  stderr.writeln('Compiling Apple bridge (one-time)...');
  final r = await Process.run('swiftc', [
    '-O',
    'bridge.swift',
    '-o',
    'bridge',
  ], workingDirectory: dir);
  if (r.exitCode != 0) {
    stderr.writeln('Apple bridge compile failed: ${r.stderr}');
    return false;
  }
  return true;
}

// Ensures the Apple bridge is built and listening, compiling/spawning on demand.
// Returns false (caller falls back to cloud) on non-macOS, no swiftc, or timeout.
Future<bool> ensureBridgeRunning() async {
  if (!Platform.isMacOS) return false;
  if (await _bridgeUp()) return true;
  if (_spawning) return false; // another call is already starting it
  _spawning = true;
  try {
    final dir = path.join(PiperTTS.getScriptDir(), 'apple_bridge');
    if (!await _ensureBridgeBuilt(dir)) return false;
    final bin = path.join(dir, 'bridge');
    stderr.writeln('Starting Apple on-device bridge...');
    await Process.run('bash', [
      '-c',
      'nohup "$bin" > /tmp/apple_bridge.log 2>&1 &',
    ]);
    // Allow time for launch + model prewarm.
    for (var i = 0; i < 16; i++) {
      if (await _bridgeUp()) {
        stderr.writeln('Apple bridge ready on $_bridgePort');
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    stderr.writeln('Apple bridge did not come up; using cloud fallback');
    return false;
  } catch (e) {
    stderr.writeln('Error starting Apple bridge: $e');
    return false;
  } finally {
    _spawning = false;
  }
}

// Strips ```json fences and decodes the first JSON object found.
Map<String, dynamic>? _parseJsonLoose(String raw) {
  var s = raw.trim();
  if (s.startsWith('```')) {
    s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '');
    if (s.endsWith('```')) s = s.substring(0, s.length - 3);
    s = s.trim();
  }
  try {
    final decoded = jsonDecode(s);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    // Last resort: grab the outermost {...}.
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final decoded = jsonDecode(s.substring(start, end + 1));
        return decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {}
    }
    return null;
  }
}

// One JSON call to the local bridge, or null if unavailable/failed.
Future<Map<String, dynamic>?> _localJson(
  String prompt, {
  String? systemPrompt,
}) async {
  if (!await ensureBridgeRunning()) return null;
  try {
    final messages = [
      if (systemPrompt != null) {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': prompt},
    ];
    final resp = await http
        .post(
          Uri.parse('http://127.0.0.1:$_bridgePort/v1/chat/completions'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': 'apple-foundation-model',
            'messages': messages,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final content =
        (((body['choices'] as List?)?.first as Map?)?['message']
                as Map?)?['content']
            as String?;
    if (content == null) return null;
    return _parseJsonLoose(content);
  } catch (e) {
    stderr.writeln('Local bridge call failed: $e');
    return null;
  }
}

// Cheap JSON completion: prefer the free local model, fall back to cloud. Use
// this for high-frequency, low-stakes calls (gate, compaction) — NOT the deep
// judge, which wants the cloud model's nuance.
Future<Map<String, dynamic>?> cheapJson(
  String prompt, {
  String? systemPrompt,
  double temperature = 0.5,
  int maxTokens = 300,
}) async {
  // Apple's on-device session has a hard ~4096-token budget covering
  // instructions + prompt + the generated response (a fresh session per call
  // means no transcript accumulation, so only THIS call's size matters). At
  // ~3.5 chars/token, skip local for oversized inputs — they would throw
  // contextSizeExceeded — and go straight to cloud, which has the room.
  const localCharBudget = 10000; // ~2800 tokens in + headroom for the response
  final estChars = prompt.length + (systemPrompt?.length ?? 0);
  if (estChars <= localCharBudget) {
    final local = await _localJson(prompt, systemPrompt: systemPrompt);
    if (local != null) return local;
  }

  final client = getAIClient();
  if (client == null) return null;
  return client.generateJsonCompletion(
    prompt,
    systemPrompt: systemPrompt,
    temperature: temperature,
    maxTokens: maxTokens,
  );
}
