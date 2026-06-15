import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

class PiperTTS {
  final String host;
  final int port;
  Process? _serverProcess;
  String _currentVoice = 'arngeir';

  // True while audio is actually being rendered/played. Lets callers reason
  // about whether a voice switch (which restarts the server) would interrupt
  // in-flight speech. The serialized speech queue is the real guarantee that a
  // restart never lands mid-playback; this flag is observability on top of it.
  bool _isSpeaking = false;
  bool get isSpeaking => _isSpeaking;
  String get currentVoice => _currentVoice;

  PiperTTS({this.host = 'localhost', this.port = 5000});

  /// Gets the directory where the script is located
  static String getScriptDir() {
    final scriptUri = Platform.script;
    final scriptDir = path.dirname(scriptUri.toFilePath());
    return scriptDir;
  }

  /// Gets the Python executable path based on the platform
  static String getPythonPath(String scriptDir) {
    if (Platform.isWindows) {
      return path.join(scriptDir, 'venv', 'Scripts', 'python.exe');
    } else {
      return path.join(scriptDir, 'venv', 'bin', 'python3');
    }
  }

  /// Gets the list of available voices from the voices directory
  Future<List<String>> getAvailableVoices() async {
    final scriptDir = getScriptDir();
    final voicesDir = Directory(path.join(scriptDir, 'voices'));
    final voices = <String>[];
    
    if (await voicesDir.exists()) {
      await for (final entity in voicesDir.list()) {
        if (entity is File && entity.path.endsWith('.onnx')) {
          final fileName = path.basename(entity.path);
          final voiceName = fileName.replaceAll('.onnx', '');
          voices.add(voiceName);
        }
      }
    }
    
    return voices;
  }

  /// Checks if the server is running by attempting a connection
  Future<bool> isServerRunning() async {
    try {
      final socket = await Socket.connect(host, port, timeout: Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Starts the Piper TTS server in the background
  Future<void> startServer({String? voice}) async {
    try {
      final selectedVoice = voice ?? _currentVoice;
      final scriptDir = getScriptDir();
      final pythonPath = getPythonPath(scriptDir);
      final modelPath = path.join(scriptDir, 'voices', '$selectedVoice.onnx');

      stderr.writeln('Starting Piper TTS server with voice: $selectedVoice...');
      
      // Bind explicitly to this instance's host/port so separate instances can
      // coexist without colliding on the default port. The log is port-scoped
      // so concurrent instances don't clobber each other's output.
      final serverArgs =
          '-m piper.http_server -m $modelPath --host $host --port $port';

      // Start the server detached
      if (Platform.isWindows) {
        // Windows: use start /B to run in background
        await Process.run('cmd', [
          '/c',
          'start /B $pythonPath $serverArgs > %TEMP%\\piper_server_$port.log 2>&1'
        ]);
      } else {
        // Unix: use nohup to run in background
        await Process.run('bash', [
          '-c',
          'nohup $pythonPath $serverArgs > /tmp/piper_server_$port.log 2>&1 &'
        ]);
      }

      // Give the server time to start
      await Future.delayed(Duration(seconds: 3));

      // Verify server is running with timeout
      int attempts = 0;
      while (attempts < 10) {
        if (await isServerRunning()) {
          stderr.writeln('Piper TTS server started successfully');
          _currentVoice = selectedVoice;
          return;
        }
        await Future.delayed(Duration(milliseconds: 500));
        attempts++;
      }
      
      throw Exception('Server failed to start after 5 seconds');
    } catch (e) {
      stderr.writeln('Error starting server: $e');
      rethrow;
    }
  }

  /// Stops the Piper TTS server
  Future<void> stopServer() async {
    try {
      if (Platform.isWindows) {
        // Windows: use taskkill
        await Process.run('taskkill', ['/F', '/IM', 'python.exe', '/FI', 'WINDOWTITLE eq piper.http_server*']);
      } else {
        // Unix: kill only the instance bound to THIS port, so restarting one
        // instance never takes down a sibling instance.
        await Process.run('bash', [
          '-c',
          'pkill -f "piper.http_server.*--port $port"'
        ]);
      }
      await Future.delayed(Duration(seconds: 1));
      stderr.writeln('Piper TTS server stopped');
    } catch (e) {
      stderr.writeln('Error stopping server: $e');
    }
  }

  /// Restarts the server with a different voice
  Future<void> restartWithVoice(String voice) async {
    await stopServer();
    await startServer(voice: voice);
  }

  /// Ensures the server is running, starting it if necessary
  Future<void> ensureServerRunning({String? voice}) async {
    if (voice != null && voice != _currentVoice) {
      await restartWithVoice(voice);
    } else if (!await isServerRunning()) {
      await startServer(voice: voice);
    }
  }

  /// Converts text to speech and saves it to a file
  /// Returns the path to the generated audio file
  Future<String> textToSpeech(String text, {String? outputPath}) async {
    try {
      final url = Uri.parse('http://$host:$port');
      
      // Make the POST request to the TTS server
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text}),
      );

      if (response.statusCode == 200) {
        // If no output path is provided, create a temporary file with a unique name
        final tempDir = Directory.systemTemp;
        final tempFile = await File('${tempDir.path}/piper_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}.wav').create(recursive: true);
        final file = outputPath != null 
            ? File(outputPath) 
            : tempFile;
            
        await file.writeAsBytes(response.bodyBytes);
       
        return file.path;
      } else {
        throw Exception('Failed to generate speech: ${response.statusCode} ${response.reasonPhrase}');
      }
    } catch (e) {
      stderr.writeln('Error: $e');
      rethrow;
    }
  }

  /// Plays the generated speech using appropriate player based on OS
  Future<void> playAudio(String filePath, {double volume = 1.0}) async {
    _isSpeaking = true;
    try {
      String command;
      List<String> args;

      if (Platform.isMacOS) {
        // afplay -v takes a linear gain (1.0 = normal); lets callers lower the
        // playback volume when needed.
        command = 'afplay';
        args = ['-v', volume.toStringAsFixed(2), filePath];
      } else {
        // ffplay -volume is 0-100.
        command = 'ffplay';
        final vol = (volume * 100).clamp(0, 100).round();
        args = ['-nodisp', '-autoexit', '-volume', '$vol', filePath];
      }

      final process = await Process.run(command, args);
      
      if (process.exitCode != 0) {
        throw Exception('Failed to play audio: ${process.stderr}');
      }
    } catch (e) {
      stderr.writeln('Error playing audio: $e');
      rethrow;
    } finally {
      _isSpeaking = false;
    }
  }

  /// Converts text to speech and plays it
  Future<void> speak(String text, {String? voice, double volume = 1.0}) async {
    var audioFile;
    try {
      await ensureServerRunning(voice: voice);
      audioFile = await textToSpeech(text);
      await playAudio(audioFile, volume: volume);
      // Clean up the temporary file
      await File(audioFile).delete();
    } catch (e) {
      if (audioFile is String) await File(audioFile).delete();
      stderr.writeln('Error in speak(): $e');
      rethrow;
    }
  }
}

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    print('Usage: dart piper_tts.dart "Text to speak"');
    return;
  }

  final tts = PiperTTS();
  final text = arguments.join(' ');

  try {
    await tts.speak(text);
  } catch (e) {
    print('Error: $e');
    exit(1);
  }
}
