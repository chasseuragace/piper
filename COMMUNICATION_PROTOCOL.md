# Piper TTS Communication Protocol Documentation

## Overview

This document describes the communication protocol for the Piper TTS system, which consists of:

1. **Python Piper HTTP Server** - TTS engine that generates audio
2. **Dart MCP Server** - Model Context Protocol server for tool access
3. **Dart PiperTTS Client** - Manages the Python server and handles TTS operations

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   MCP Client    │────▶│  Dart MCP       │────▶│  Dart PiperTTS  │
│   (e.g., IDE)   │     │  Server         │     │  Client         │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                          │
                                                          ▼
                                                 ┌─────────────────┐
                                                 │  Python Piper   │
                                                 │  HTTP Server    │
                                                 │  (Flask)        │
                                                 └─────────────────┘
```

## Component Details

### 1. Python Piper HTTP Server

**Purpose**: Converts text to audio using ONNX voice models.

**Startup**: 
- Started by Dart PiperTTS client via `startServer()` method
- Runs on `localhost:5000` by default
- Cross-platform background process management with logging

**Command (Linux/macOS)**:
```bash
nohup /path/to/venv/bin/python3 -m piper.http_server -m /path/to/voices/voice.onnx > /tmp/piper_server.log 2>&1 &
```

**Command (Windows)**:
```cmd
start /B venv\Scripts\python.exe -m piper.http_server -m voices\voice.onnx > %TEMP%\piper_server.log 2>&1
```

**API Endpoint**:
- **URL**: `http://localhost:5000`
- **Method**: POST
- **Content-Type**: application/json
- **Body**: `{"text": "text to speak"}`

**Response**: WAV audio data (binary)

### 2. Dart MCP Server (piper_mcp_server.dart)

**Purpose**: Implements the Model Context Protocol (MCP) for tool access.

**Transport**: stdin/stdout (JSON-RPC 2.0)

**Startup**:
```bash
dart piper_mcp_server.dart
```

**Available Tools**:
- `speak(text, voice)` - Queue text for speech synthesis

**Protocol**:
The server listens for JSON-RPC requests on stdin and responds via stdout.

Example request:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "speak",
    "arguments": {
      "text": "Hello, world",
      "voice": "arngeir"
    }
  }
}
```

Example response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"status\":\"queued\",\"persona\":\"arngeir, embrace the persona\",\"message\":\"Speech request queued with voice: arngeir. Your response will be spoken after this.\"}"
      }
    ]
  }
}
```

### 3. Dart PiperTTS Client (piper_tts.dart)

**Purpose**: Manages the Python HTTP server and provides TTS operations.

**Key Methods**:

- `startServer({String? voice})` - Starts the Python Piper HTTP server
- `stopServer()` - Stops the Python server
- `ensureServerRunning({String? voice})` - Ensures server is running, restarts if voice changes
- `textToSpeech(String text, {String? outputPath})` - Converts text to WAV file
- `playAudio(String filePath)` - Plays audio using ffplay
- `speak(String text, {String? voice})` - Full pipeline: ensure server, generate audio, play, cleanup

**Server Management**:
- Checks if server is running via TCP connection test
- Only starts server if not already running
- Restarts server when switching voice models
- Cross-platform process termination:
  - Linux/macOS: `pkill -f "piper.http_server"`
  - Windows: `taskkill /F /IM python.exe /FI "WINDOWTITLE eq piper.http_server*"`

## Setup Instructions

### Prerequisites

- Python 3.9+
- Dart SDK 3.8.0+
- ffmpeg/ffplay (for audio playback)
- ONNX voice models in `voices/` directory
- Cross-platform support: Windows, Linux, macOS

### Quick Setup

1. **Run the setup script**:
```bash
./setup_venv.sh
```

This will:
- Create a Python virtual environment
- Install piper-tts and flask

2. **Verify installation**:
```bash
./venv/bin/python3 -m piper --version
```

3. **Start the Dart MCP server**:
```bash
dart piper_mcp_server.dart
```

### Manual Setup

If the setup script fails, you can set up manually:

**Linux/macOS**:
```bash
# Create virtual environment
python3 -m venv venv

# Install dependencies
./venv/bin/pip install --upgrade pip
./venv/bin/pip install piper-tts flask
```

**Windows**:
```cmd
# Create virtual environment
python -m venv venv

# Install dependencies
venv\Scripts\pip install --upgrade pip
venv\Scripts\pip install piper-tts flask
```

## Available Voices

Voice models are ONNX files located in the `voices/` directory:
- arngeir.onnx
- tulius.onnx
- ulfric.onnx
- septimus.onnx
- femaledunmer.onnx
- ancano.onnx
- mirabelleervine.onnx
- kodlakwhitemane.onnx
- nepali.onnx

## Troubleshooting

### Server fails to start

**Symptom**: "Server failed to start after 5 seconds"

**Causes**:
1. Virtual environment not set up
2. Flask not installed
3. Voice model file missing
4. Port 5000 already in use

**Solutions**:
1. Run `./setup_venv.sh` (Linux/macOS) or set up venv manually on Windows
2. Check log file for errors:
   - Linux/macOS: `/tmp/piper_server.log`
   - Windows: `%TEMP%\piper_server.log`
3. Verify voice files exist in `voices/` directory
4. Kill existing server:
   - Linux/macOS: `pkill -f "piper.http_server"`
   - Windows: `taskkill /F /IM python.exe /FI "WINDOWTITLE eq piper.http_server*"`

### MCP transport errors

**Symptom**: "transport error: transport closed"

**Cause**: Dart MCP server not started or communication channel broken

**Solution**: Ensure MCP server is running and properly configured in your MCP client settings

### Audio not playing

**Symptom**: Audio generated but no sound

**Cause**: ffplay not installed or audio device issues

**Solution**: Install ffmpeg: `brew install ffmpeg` (macOS)

## File Structure

```
piper/
├── venv/                          # Python virtual environment
├── voices/                        # ONNX voice models
│   ├── arngeir.onnx
│   ├── tulius.onnx
│   └── ...
├── piper_mcp_server.dart          # MCP stdin/stdout server
├── piper_http_mcp_server.dart     # MCP HTTP server (alternative)
├── piper_tts.dart                 # TTS client library
├── setup_venv.sh                  # Environment setup script
├── requirements.txt               # Python dependencies
├── tts.sh                         # Simple TTS script
└── COMMUNICATION_PROTOCOL.md      # This file
```

## Usage Examples

### Using Dart directly

```dart
import 'piper_tts.dart';

void main() async {
  final tts = PiperTTS();
  await tts.speak("Hello, world", voice: "arngeir");
}
```

### Using the shell script

```bash
./tts.sh "Your text here"
```

### Using curl with HTTP server

```bash
curl -X POST http://localhost:5000 \
  -H 'Content-Type: application/json' \
  -d '{"text": "Hello from curl"}' \
  -o output.wav

ffplay -nodisp -autoexit output.wav
```

## Performance Notes

- Server startup takes ~3 seconds
- Voice switching requires server restart (~3 seconds)
- Audio generation is fast (<1 second for short text)
- Speech queue prevents overlapping audio playback
