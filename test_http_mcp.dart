#!/usr/bin/env dart

import 'dart:io';
import 'dart:convert';

// Simple client to test the HTTP MCP server
Future<void> main() async {
  final serverUrl = 'http://localhost:3000';
  final client = HttpClient();

  try {
    // Test initialize
    print('Testing initialize...');
    final initResponse = await _sendRequest(client, serverUrl, {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'test-client', 'version': '1.0.0'}
      }
    });
    print('Initialize response: ${jsonEncode(initResponse)}');

    // Test tools/list
    print('\nTesting tools/list...');
    final toolsResponse = await _sendRequest(client, serverUrl, {
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
      'params': {}
    });
    print('Tools response: ${jsonEncode(toolsResponse)}');

    // Test tools/call with speak
    print('\nTesting tools/call (speak)...');
    final speakResponse = await _sendRequest(client, serverUrl, {
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {
        'name': 'speak',
        'arguments': {'text': 'Hello from the HTTP MCP server!'}
      }
    });
    print('Speak response: ${jsonEncode(speakResponse)}');

    // Test ping
    print('\nTesting ping...');
    final pingResponse = await _sendRequest(client, serverUrl, {
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'ping',
      'params': {}
    });
    print('Ping response: ${jsonEncode(pingResponse)}');

  } catch (e) {
    print('Error: $e');
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> _sendRequest(
    HttpClient client, String url, Map<String, dynamic> request) async {
  final uri = Uri.parse(url);
  final requestObj = await client.postUrl(uri);
  
  requestObj.headers.contentType = ContentType.json;
  requestObj.write(jsonEncode(request));
  
  final response = await requestObj.close();
  final responseBody = await response.transform(utf8.decoder).join();
  
  if (response.statusCode != 200) {
    throw Exception('HTTP ${response.statusCode}: $responseBody');
  }
  
  return jsonDecode(responseBody) as Map<String, dynamic>;
}
