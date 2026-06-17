import 'dart:io';
import 'dart:convert';
import '../src/feedback/piper_feedback_engine.dart';

void main() async {
  print('=== Piper Log Compaction Engine Test ===');

  final testWorkspace = '/test/compaction_workspace';

  // 1. Clean up any existing test logs for this workspace
  final logFile = getLogFileForWorkspace(testWorkspace);
  if (await logFile.exists()) {
    print('Cleaning up old test log file: ${logFile.path}');
    await logFile.delete();
  }

  // 2. Append 11 speech entries in a loop.
  // Each entry is a realistic Skyrim voice persona narration.
  final voices = ['irileth', 'tulius', 'arngeir', 'septimus', 'jzargo', 'mirabelleervine', 'kodlakwhitemane', 'ancano'];
  
  print('\nAppended 11 speech logs to simulate active usage:');
  for (int i = 1; i <= 11; i++) {
    final voice = voices[i % voices.length];
    final text = 'This is speech log entry number $i spoken by $voice. We are pair programming on refactoring and testing our MCP server.';
    
    print(' - Appending entry $i [$voice]: "$text"');
    await appendSpeechLog(
      text: text,
      voice: voice,
      workspaceId: testWorkspace,
    );
  }

  // 3. Verify compaction
  print('\nVerifying log file state...');
  if (!await logFile.exists()) {
    print('ERROR: Log file was not created!');
    exit(1);
  }

  final lines = await logFile.readAsLines();
  print('Compacted log file total lines: ${lines.length}');
  
  if (lines.isEmpty) {
    print('ERROR: Log file is empty!');
    exit(1);
  }

  // Parse lines to verify structure
  final entries = lines.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();

  // First line should be the system summary entry!
  final first = entries.first;
  print('\nFirst Entry in Log (Expected System Summary):');
  print(' - Voice: ${first['voice']}');
  print(' - Text: ${first['text']}');
  print(' - Timestamp: ${first['timestamp']}');

  if (first['voice'] != 'system' || !first['text'].contains('[SUMMARY OF PREVIOUS CONTEXT]')) {
    print('ERROR: First entry is NOT the system summary!');
    exit(1);
  }

  // Remaining entries should be the raw entries kept
  print('\nRemaining Entries (Expected Kept Raw Entries):');
  for (int i = 1; i < entries.length; i++) {
    print(' - Entry $i [${entries[i]['voice']}]: "${entries[i]['text']}"');
  }

  if (entries.length != 4) {
    print('ERROR: Expected exactly 4 entries after compaction (1 summary + 3 kept), but got ${entries.length}!');
    exit(1);
  }

  print('\n🎉 Success! Piper Log Compaction Engine validated successfully.');
}
