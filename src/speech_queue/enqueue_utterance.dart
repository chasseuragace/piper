import 'dart:async';
import 'dart:io';

import '../../piper_tts.dart';
import '../feedback/piper_feedback_engine.dart';

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

void enqueueUtterance(
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
    processQueue(tts);
  }
}

Future<void> processQueue(PiperTTS tts) async {
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
