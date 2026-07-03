# Piper — Skyrim-Voiced Speech, and the Balcony That Watches

![Banner](banner.webp)

Piper began as a Dart wrapper for the [Piper](https://github.com/rhasspy/piper) text-to-speech engine, giving AI coding agents a *voice* — nine Skyrim characters, each with its own cadence. It grew into something more: a **reasoning companion**. The voices give your agent personality; the **Balcony** gives it a conscience — a zero-token git observer that listens to what the agent *says* and checks it against what it actually *did*.

Both halves matter, and both are here:

- **The voice** — cross-platform Skyrim-themed TTS (Windows, Linux, macOS), a persona-preserving speech normalizer, and an MCP `speak` tool so an agent can externalize its thinking aloud.
- **The Balcony** — an observer that turns spoken reasoning into data it can audit: it watches the real git state, catches story-vs-reality drift, and speaks up (in the fitting persona) only when it's genuinely earned.

> If the *why* behind the Balcony interests you, it's written up in two essays: [The Balcony Pattern](https://chasseuragace.github.io/the-lead/blog/the-balcony-pattern) and [The Second Loop Closes](https://chasseuragace.github.io/the-lead/blog/the-second-loop-closes). For the always-current *what* — module map, dependency graph, the speak pipeline, tuning knobs — see **[ARCHITECTURE.generated.md](ARCHITECTURE.generated.md)**, which is generated from the AST and can't go stale.

## Use Case

**Give voice — and judgement — to your AI agents.** Integrate natural-sounding, in-character speech into your AI applications, and (optionally) let a deterministic observer keep an immersed coding agent honest about its own progress.

## Features

**Speech**
- Text-to-speech via Piper TTS, cross-platform (Windows, Linux, macOS)
- Nine Skyrim-character voices, each usable as a distinct *thinking mode*
- HTTP server for TTS requests, including a `POST /tts` endpoint returning sanitized `audio/wav` bytes
- Audio playback via ffplay
- **Persona-Preserving Speech Normalizer**: context-aware replacement of unstable interjections (`hmph` → voice-specific spoken equivalents) plus typography cleanup
- **Transaction-Safe Log Compaction**: bounded log growth via atomic, local-model summarization of older dialogue

**The Balcony (reasoning companion)**
- `speak` as an external reasoning channel, not narration — with a grounded cue returned on every call
- A **zero-token git observer** that compares ground truth (files, churn, commits, tests) against the agent's narration
- A tiered **cost ladder** — cheap deterministic tripwire → stateful gate → LLM judge — so intelligence is only spent when earned
- A **feedback loop**: the agent can acknowledge a concern (`intentional` / `addressing` / `not-applicable` / `disagree`) and the observer stops nagging until the change escalates
- **Claim detection**: fires only when narration ("tests pass", "committed it") contradicts git
- **Self-calibration**: the agent's acknowledgements become a labeled false-positive dataset that flags noisy signals
- `speak_skill`: an on-demand playbook the client pulls once per conversation

## Prerequisites

- **Dart SDK** 3.8.0 or higher
- **Python 3** (for the Piper TTS backend)
- **ffplay** (for audio playback — part of FFmpeg)

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

### 3. Set up the Python virtual environment

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

  // Convert to speech and save to a file
  final audioPath = await tts.textToSpeech("Hello, world!", outputPath: "output.wav");

  // Change voice
  await tts.restartWithVoice("arngeir");

  // Get available voices
  final voices = await tts.getAvailableVoices();
  print("Available voices: $voices");
}
```

## The Nine Voices — Each a Thinking Mode

Voice files live in `voices/` as `.onnx` files; the default is `arngeir`. These aren't just costumes — each Skyrim character maps to a mode of engineering focus, so switching voice is a way of switching *how you're thinking about the work*.

| Voice | Character | Focus |
| --- | --- | --- |
| **arngeir** | Arngeir, the serene Greybeard | architecture, design intent, high-level direction, calm pacing |
| **tulius** | General Tullius | robustness, error handling, defensive execution |
| **mirabelleervine** | Mirabelle Ervine | testing, validation, protocol, order |
| **irileth** | Irileth, the vigilant Housecarl | security, threat assessment, vulnerability hunting |
| **septimus** | Septimus Signus | deep investigation, edge cases, anomaly hunting |
| **kodlakwhitemane** | Kodlak Whitemane | refactoring, technical debt, clean craft |
| **jzargo** | J'zargo | performance, optimization, speed |
| **ancano** | Ancano | API elegance, taming complex interfaces |
| **ulfric** | Ulfric Stormcloak | decisive cuts, removing boilerplate, bold simplification |

**Voice Model Credits**: The Skyrim voice models used in this project are sourced from the [Mantella mod](https://github.com/art-from-the-machine/Mantella) for Skyrim. Mantella brings AI-powered NPCs to Skyrim using speech-to-text, LLMs, and text-to-speech. We're grateful to the original author (art-from-the-machine) for making these voice models available.

- [GitHub Repository](https://github.com/art-from-the-machine/Mantella)
- [Nexus Mods Page](https://www.nexusmods.com/skyrimspecialedition/mods/98631)

### Download More Voices

Explore the official Piper TTS voice gallery for additional voices:
- [Piper Voice Samples](https://rhasspy.github.io/piper-samples/) — listen to and download various voice models
- [Piper Voices on Hugging Face](https://huggingface.co/rhasspy/piper-voices) — a large collection of pre-trained voices

### Adding New Voices

1. Download voice models from the galleries above
2. Place `.onnx` files in the `voices/` directory
3. Use the voice name (without the `.onnx` extension) when calling `speak()` or `restartWithVoice()`

## Speaking as Reasoning: the Balcony

The one-sentence idea: **speech is not narration, it's an external channel for the agent's reasoning.** When an agent says "I'm going to refactor the gate logic now," that utterance is a *claim about intent* — and once you have a stream of claims, you can check them against reality.

Piper's **Balcony** does exactly that. It steps off the dance floor and watches the *actual* git state — files changed, churn, which modules, whether tests moved, recent commits — and looks for divergence between the story and the truth ("said small, did large"; "claimed done, committed nothing"; "tests pass" but no test changed). It costs zero tokens; it's just `git`.

Feedback is spent as a ladder — you only climb a rung when the one below says it's worth it:

1. **Observe** (free) — read the git ground truth.
2. **Tripwire** (free) — cheap heuristics decide whether anything's even worth a closer look.
3. **Gate** (mostly free, stateful) — a novelty-aware ledger so a true-but-stale concern is said *once*, not every turn.
4. **Judge** (paid, only when earned) — an LLM diagnoses divergence and severity; only high-severity findings ever speak aloud, in the best-fit persona.

And the loop runs **both ways**. The observed agent can answer a concern via the `speak` tool's `feedback` field, and the observer honors it until the change materially escalates. The agent's acknowledgements double as a free dataset that flags which signals fire too eagerly. See **[ARCHITECTURE.generated.md](ARCHITECTURE.generated.md)** for the pipeline as the code actually runs it.

## MCP Integration

Piper ships an MCP (Model Context Protocol) server exposing two tools:

- **`speak`** — speak your current thinking in a chosen voice; returns a grounded cue (observation, concerns, judgement). Accepts an optional `feedback` object to answer a prior concern.
- **`speak_skill`** — returns the full playbook (voices as thinking-modes, immersion discipline, how the observer/feedback loop works). Call it once at the start of a conversation.

### Recommended: register globally with the Claude CLI

```bash
claude mcp add piper-tts -s user -- dart run /path/to/piper/piper_mcp_server.dart
```

`-s user` makes the tools available in every project. Replace the path with the actual location of `piper_mcp_server.dart` on your system.

### Or: MCP config file (Claude Desktop / Windsurf)

```json
{
  "mcpServers": {
    "piper-tts": {
      "command": "dart",
      "args": ["run", "/path/to/piper/piper_mcp_server.dart"],
      "disabled": false
    }
  }
}
```

### Available MCP servers

- `piper_mcp_server.dart` — standard stdio MCP server (the `speak` / `speak_skill` tools + the Balcony)
- `piper_http_mcp_server.dart` — HTTP variant, including `POST /tts` → sanitized `audio/wav` bytes for a client to play. See **[README_HTTP_MCP.md](README_HTTP_MCP.md)** and **[COMMUNICATION_PROTOCOL.md](COMMUNICATION_PROTOCOL.md)**.

## Advanced Speech & Log Infrastructure

Built for high-frequency interactive LLM programming and maximum speech immersion.

### 🎙️ Persona-Preserving Speech Normalization

A dedicated pipeline filters out synthesis bugs and robotic vocalizations before playback:
* **Typography Cleanup**: normalizes punctuation spam (`!!!` ➡️ `!`, `???` ➡️ `?`, `.....` ➡️ `…`).
* **Persona-Preserving Rewrites**: unstable interjections like `hmph`, `tch`, `ugh` are replaced with character-authentic, randomized spoken cadences per voice (e.g., General Tullius: *"As expected."*, J'zargo: *"J'zargo expected as much."*, Arngeir: *"Patience."*).
* **Immersive Fallbacks**: global unstable sounds like `pfft`, `grrr`, `tsk` become setting-appropriate words (*"Nonsense"*, *"By the gods"*, *"Careless"*) rather than literal stage directions.
* **Punctuation Preservation**: the trailing punctuation of the original match is propagated onto the replacement to protect sentence rhythm.

### 📦 Transaction-Safe Log Compaction

High-frequency sessions generate a large volume of speech logs. The compaction engine keeps them bounded:
* **Threshold-Triggered**: compaction runs when a workspace's log exceeds roughly 10 entries or 3000 characters (and there are at least a few entries to meaningfully summarize).
* **Rolling History**: the most recent entries are retained verbatim for high-fidelity feedback; older ones are synthesized by the free on-device model into a single `[SUMMARY OF PREVIOUS CONTEXT]: ...` line.
* **Transaction Safety**: the read-summarize-write lifecycle is performed via a temporary file swap, so an interrupted process never loses data.

## API Reference

### PiperTTS Class

#### Constructor

```dart
PiperTTS({String host = 'localhost', int port = 5000})
```

#### Methods

- `Future<void> startServer({String? voice})` — starts the Piper TTS HTTP server
- `Future<void> stopServer()` — stops the server
- `Future<void> restartWithVoice(String voice)` — restarts the server with a different voice
- `Future<void> ensureServerRunning({String? voice})` — ensures the server is running
- `Future<String> textToSpeech(String text, {String? outputPath})` — converts text to speech
- `Future<void> playAudio(String filePath)` — plays an audio file using ffplay
- `Future<void> speak(String text, {String? voice})` — converts text to speech and plays it
- `Future<List<String>> getAvailableVoices()` — returns the list of available voices
- `Future<bool> isServerRunning()` — checks whether the server is running

## Project Structure

```
piper/
├── piper_tts.dart              # Core TTS wrapper (Piper backend + playback)
├── piper_mcp_server.dart       # stdio MCP server: speak / speak_skill + the Balcony
├── piper_http_mcp_server.dart  # HTTP MCP server variant (POST /tts)
├── report_calibration.dart     # Calibration report (reads workspace_logs/)
├── src/
│   ├── observation/            # The Balcony: git observer, tripwire, judge, ledger, co-change
│   ├── feedback/               # Feedback engine + calibration (false-positive stats)
│   ├── llm/                    # Cloud + on-device LLM clients
│   ├── persona/                # Voice descriptions + speech normalizer rules
│   ├── speech_queue/           # Serialized utterance playback
│   ├── core/                   # Persistence + log compaction
│   └── models/                 # JSON-RPC types
├── tool/gen_arch.dart          # Architecture generator (AST → ARCHITECTURE.generated.md)
├── test/                       # Tests
├── voices/                     # Voice model files (.onnx)
├── requirements.txt            # Python dependencies
├── setup_venv.sh               # Unix setup script
├── ARCHITECTURE.generated.md   # Generated architecture reference (do not hand-edit)
└── README.md                   # This file
```

For the exhaustive, always-current structure — signatures, dependency graph, the speak pipeline, and tuning knobs — see **[ARCHITECTURE.generated.md](ARCHITECTURE.generated.md)** (regenerate with `dart run tool/gen_arch.dart`).

## Troubleshooting

### Server fails to start

- Check that the Python virtual environment is set up correctly
- Verify voice model files exist in the `voices/` directory
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
