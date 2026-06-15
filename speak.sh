#!/bin/bash
# Piper TTS - uses piper_tts.dart which handles audio directly

# Read from argument OR stdin
if [ -n "$1" ]; then
  text="$1"
else
  text=$(cat)
fi

# Use piper_tts.dart directly - it handles audio playback properly
/Users/ajaydahal/fvm/versions/3.44.0/bin/cache/dart-sdk/bin/dart /Volumes/shared_code/skyrim/piper/piper_tts.dart "$text" 2>&1
