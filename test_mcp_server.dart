import 'dart:io';
import 'dart:convert';
import 'dart:async';

void main() async {
  print('Starting MCP Server Test...');

  final process = await Process.start('dart', ['piper_mcp_server.dart'],
    workingDirectory: '/Volumes/shared_code/skyrim/piper'
  );

  // Listen to server output
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    print('SERVER: $line');
  });

  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    print('LOG: $line');
  });

  // Helper to send JSON-RPC
  void send(Map<String, dynamic> json) {
    final str = jsonEncode(json);
    print('CLIENT: $str');
    process.stdin.writeln(str);
  }

  // 1. Initialize
  send({
    'jsonrpc': '2.0',
    'method': 'initialize',
    'params': {
      'protocolVersion': '2024-11-05',
      'capabilities': {},
      'clientInfo': {'name': 'test-client', 'version': '1.0'}
    },
    'id': 1
  });

  await Future.delayed(Duration(seconds: 1));

  // 2. List Tools
  send({
    'jsonrpc': '2.0',
    'method': 'tools/list',
    'id': 2
  });

  await Future.delayed(Duration(seconds: 1));

  // 3. Call Speak (Mocking the actual TTS call might be hard without server, but we check if it tries)
  // Note: This will fail if the actual Piper TTS server is not running on localhost:5000
  // But we can check if it receives the request and tries to process it.
  send({
    'jsonrpc': '2.0',
    'method': 'tools/call',
    'params': {
      'name': 'speak',
      'arguments': {'text': 'Hello from MCP test'}
    },
    'id': 3
  });

  await Future.delayed(Duration(seconds: 3));
  
  print('Test finished, killing server.');
  process.kill();
}
