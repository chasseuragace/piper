import 'dart:io';

import 'piper_tts.dart';
import 'piper_persistence.dart';

// A side audio channel for high-severity balcony interventions.
//
// Instead of waiting its turn in the main serialized queue (which would cost a
// ~4s voice-switch gap and stall the agent's voice), a whisper runs on a
// SECOND Piper instance bound to its own port and plays at reduced volume,
// "ducked" under the main voice. The agent's line is never interrupted or
// delayed; the intervention arrives as a low aside, like a pair-programmer
// murmuring "...scope's creeping" without taking the floor.
//
// Whispers deliberately OVERLAP the main voice — that is the whole point — but
// they are coordinated by a file-backed lock so at most one whisper plays at a
// time, even across volatile MCP processes. A dropped whisper loses nothing
// essential: the same judgement is always returned as text in the tool result.
class WhisperChannel {
  final PiperTTS _tts;
  final double volume;
  bool _busyLocal = false;

  WhisperChannel({int port = 5001, this.volume = 0.35})
    : _tts = PiperTTS(port: port);

  // Fire-and-forget. Returns true if the whisper was launched, false if it was
  // dropped (already whispering here or in another process). Never blocks on
  // playback and never touches the main TTS server.
  Future<bool> whisper(String text, String voice, String workspaceId) async {
    if (text.trim().isEmpty) return false;
    if (_busyLocal) return false;
    if (await channelState('whisper') != null) return false; // someone else

    _busyLocal = true;
    await acquireChannel('whisper', voice, workspaceId);

    // Detached: do not await playback, so the tool call returns immediately.
    () async {
      try {
        await _tts.speak(text, voice: voice, volume: volume);
      } catch (e) {
        stderr.writeln('Whisper error: $e');
      } finally {
        await releaseChannel('whisper');
        _busyLocal = false;
      }
    }();

    return true;
  }
}
