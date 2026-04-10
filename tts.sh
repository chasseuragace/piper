#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default text to speak
TEXT=${1:-"Aahaaa. The wizard is here, so lets begin.. . First.. , let me.. get the enchantment table ready... For this session.. . Hold on... here..., for a moment.."}
PORT=5000

# Check if the server is already running
if ! curl -s http://localhost:$PORT > /dev/null; then
    echo "Starting Piper TTS server..."
    # Start the server in the background using venv
    "$SCRIPT_DIR/venv/bin/python3" -m piper.http_server -m "$SCRIPT_DIR/voices/arngeir.onnx" &
    SERVER_PID=$!
    
    # Give the server a moment to start
    sleep 3
    
    # Set up cleanup on script exit
    # trap "kill $SERVER_PID 2> /dev/null" EXIT
fi

# Create a temporary file for the audio output
TEMP_FILE=$(mktemp /tmp/piper_audio_XXXXXX.wav)

# Make the request to the TTS server
curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"text\": \"$TEXT\"}" \
    -o "$TEMP_FILE" \
    "http://localhost:$PORT"

# Play the audio file
if [ -f "$TEMP_FILE" ]; then
    ffplay -nodisp -autoexit "$TEMP_FILE" > /dev/null 2>&1
    rm -f "$TEMP_FILE"
else
    echo "Error: Failed to generate speech"
    exit 1
fi

# # Run the Flutter app
# echo "Starting Flutter app..."
# cd "$(dirname "$0")/../flutter_enchantment_table"
# flutter run -d macos

exit 0
