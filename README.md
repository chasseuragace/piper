# Piper TTS - Dart Wrapper

![Banner](banner.webp)

A Dart wrapper for the Piper text-to-speech engine with cross-platform support (Windows, Linux, macOS).

## Use Case

**Give voice to your AI agents** - Integrate natural-sounding speech synthesis into your AI applications, chatbots, virtual assistants, and agents. Let your AI speak with personality using multiple voice options.

## Features

- Text-to-speech conversion using Piper TTS
- Cross-platform support (Windows, Linux, macOS)
- HTTP server for TTS requests
- Multiple voice support
- Audio playback via ffplay
- Simple API for AI agent integration

## Prerequisites

- **Dart SDK** 3.8.0 or higher
- **Python 3** (for Piper TTS backend)
- **ffplay** (for audio playback - part of FFmpeg)

## Installation

### 1. Clone the repository

```bash
git clone <repository-url>
cd piper
```

### 2. Install Dart dependencies

```bash
dart pub get
```

### 3. Set up Python virtual environment

#### Linux/macOS

```bash
./setup_venv.sh
```

Or manually:

```bash
python3 -m venv venv
source venv/bin/activate  # On Linux/macOS
pip install -r requirements.txt
```

#### Windows

```cmd
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
```

### 4. Install FFmpeg (for audio playback)

#### macOS

```bash
brew install ffmpeg
```

#### Linux (Ubuntu/Debian)

```bash
sudo apt-get install ffmpeg
```

#### Windows

Download from [ffmpeg.org](https://ffmpeg.org/download.html) and add to PATH.

## Usage

### Command Line

```bash
dart run piper_tts.dart "Hello, world!"
```

### As a Library

```dart
import 'piper_tts.dart';

void main() async {
  final tts = PiperTTS();
  
  // Speak text
  await tts.speak("Hello, world!");
  
  // Convert to speech and save to file
  final audioPath = await tts.textToSpeech("Hello, world!", outputPath: "output.wav");
  
  // Change voice
  await tts.restartWithVoice("arngeir");
  
  // Get available voices
  final voices = await tts.getAvailableVoices();
  print("Available voices: $voices");
}
```

## Available Voices

Voice files are stored in the `voices/` directory as `.onnx` files. The default voice is `arngeir` (a Skyrim character).

### Skyrim-Themed Voices

This project includes Skyrim-inspired voices to give your AI agents the authentic feel of Elder Scrolls characters:
- **arngeir** - Default voice, wise Greybeard elder
- More Skyrim voices can be added for different character personalities

**Voice Model Credits**: The Skyrim voice models used in this project are sourced from the [Mantella mod](https://github.com/art-from-the-machine/Mantella) for Skyrim. Mantella is an incredible mod that brings AI-powered NPCs to Skyrim using speech-to-text, LLMs, and text-to-speech. We're grateful to the original author (art-from-the-machine) for making these voice models available.

- [GitHub Repository](https://github.com/art-from-the-machine/Mantella)
- [Nexus Mods Page](https://www.nexusmods.com/skyrimspecialedition/mods/98631)

### Download More Voices

Explore the official Piper TTS voice gallery to find additional voices:
- [Piper Voice Samples](https://rhasspy.github.io/piper-samples/) - Listen to and download various voice models
- [Piper Voices on Hugging Face](https://huggingface.co/rhasspy/piper-voices) - Large collection of pre-trained voices
- [Piper TTS Official](https://piper.ttstool.com/) - Project homepage and resources

### Adding New Voices

1. Download voice models from the galleries above
2. Place `.onnx` files in the `voices/` directory
3. Use the voice name (without `.onnx` extension) when calling `speak()` or `restartWithVoice()`

## MCP Integration

This project includes MCP (Model Context Protocol) server support for IDE integration. To enable the Piper TTS MCP server in your IDE:

### Claude Desktop / Windsurf MCP Config

Add the following to your MCP configuration file (usually `~/.config/claude/claude_desktop_config.json` or similar):

```json
{
  "mcpServers": {
    "piper-tts": {
      "command": "dart",
      "args": [
        "run",
        "/path/to/piper/piper_mcp_server.dart"
      ],
      "disabled": false
    }
  }
}
```

**Note:** Replace `/path/to/piper/piper_mcp_server.dart` with the actual path to the `piper_mcp_server.dart` file on your system.

### Available MCP Servers

- `piper_mcp_server.dart` - Standard MCP server for Piper TTS
- `piper_http_mcp_server.dart` - HTTP-based MCP server variant

## API Reference

### PiperTTS Class

#### Constructor

```dart
PiperTTS({String host = 'localhost', int port = 5000})
```

#### Methods

- `Future<void> startServer({String? voice})` - Starts the Piper TTS HTTP server
- `Future<void> stopServer()` - Stops the server
- `Future<void> restartWithVoice(String voice)` - Restarts server with different voice
- `Future<void> ensureServerRunning({String? voice})` - Ensures server is running
- `Future<String> textToSpeech(String text, {String? outputPath})` - Converts text to speech
- `Future<void> playAudio(String filePath)` - Plays audio file using ffplay
- `Future<void> speak(String text, {String? voice})` - Converts text to speech and plays it
- `Future<List<String>> getAvailableVoices()` - Returns list of available voices
- `Future<bool> isServerRunning()` - Checks if server is running

## Project Structure

```
piper/
├── piper_tts.dart          # Main Dart wrapper
├── pubspec.yaml            # Dart dependencies
├── requirements.txt        # Python dependencies
├── setup_venv.sh          # Unix setup script
├── voices/                # Voice model files (.onnx)
├── venv/                  # Python virtual environment
└── README.md              # This file
```

## Troubleshooting

### Server fails to start

- Check that Python virtual environment is set up correctly
- Verify voice model files exist in `voices/` directory
- Check that the port (default 5000) is not in use

### Audio playback fails

- Ensure FFmpeg/ffplay is installed and in PATH
- Check that the audio file was generated successfully

### Windows-specific issues

- Make sure Python is in your PATH
- Use `venv\Scripts\python.exe` when running Python commands manually
- Background process management uses Windows-specific commands

## License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
