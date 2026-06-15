import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

import 'piper_tts.dart';
import 'piper_ai_client.dart';

const int feedbackWindowSize = 10;

// Loads session state of last voices from session_state.json
Future<Map<String, String>> loadLastVoices() async {
  final scriptDir = PiperTTS.getScriptDir();
  final file = File(
    path.join(scriptDir, 'workspace_logs', 'session_state.json'),
  );
  if (!await file.exists()) {
    return {};
  }
  try {
    final content = await file.readAsString();
    if (content.trim().isEmpty) return {};
    final Map<String, dynamic> jsonMap = jsonDecode(content);
    return jsonMap.map((key, value) => MapEntry(key, value.toString()));
  } catch (e) {
    stderr.writeln('Error loading session_state.json: $e');
    return {};
  }
}

// Saves session state of last voices to session_state.json
Future<void> saveLastVoice(String workspaceId, String voice) async {
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  final file = File(path.join(logsDir.path, 'session_state.json'));

  // Read current states first to merge
  Map<String, String> currentStates = {};
  if (await file.exists()) {
    try {
      final content = await file.readAsString();
      if (content.trim().isNotEmpty) {
        final Map<String, dynamic> jsonMap = jsonDecode(content);
        currentStates = jsonMap.map(
          (key, value) => MapEntry(key, value.toString()),
        );
      }
    } catch (_) {}
  }

  currentStates[workspaceId] = voice;
  await file.writeAsString(jsonEncode(currentStates));
}

// Slugs the workspace path to use as a file name safely
File getLogFileForWorkspace(String workspaceId) {
  if (workspaceId.trim().isEmpty) {
    throw ArgumentError('workspaceId cannot be empty or blank.');
  }

  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }

  // Slug path: replace non-alphanumeric chars with underscores, take last 2 parts
  final cleanPath = workspaceId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-/]'), '_');
  final parts = cleanPath.split('/').where((e) => e.isNotEmpty).toList();
  String slug;
  if (parts.length >= 2) {
    slug = '${parts[parts.length - 2]}_${parts.last}';
  } else if (parts.isNotEmpty) {
    slug = parts.last;
  } else {
    slug = 'default';
  }
  final filename = 'speech_logs_$slug.jsonl';

  return File(path.join(logsDir.path, filename));
}

// ============================================================
// LOGGING
// ============================================================

Future<void> appendSpeechLog({
  required String text,
  required String voice,
  required String workspaceId,
  String source = 'agent',
}) async {
  final file = getLogFileForWorkspace(workspaceId);

  final logEntry = {
    'timestamp': DateTime.now().toIso8601String(),
    'text': text,
    'voice': voice,
    'workspaceId': workspaceId,
    'source': source,
    'length': text.length,
  };

  await file.writeAsString('${jsonEncode(logEntry)}\n', mode: FileMode.append);

  // Trigger dynamic compaction transaction to keep logs compact and token-efficient
  await compactLogsIfNeeded(workspaceId);
}

// Compacts old speech logs into a single summary log entry if logs exceed threshold
Future<void> compactLogsIfNeeded(String workspaceId) async {
  try {
    final file = getLogFileForWorkspace(workspaceId);
    if (!await file.exists()) return;

    final lines = await file.readAsLines();
    final nonEmptyLines = lines.where((e) => e.trim().isNotEmpty).toList();

    // Trigger compaction if we have > 10 entries OR total characters > 3000
    final totalChars = nonEmptyLines
        .map((e) => e.length)
        .fold(0, (a, b) => a + b);
    if (nonEmptyLines.length <= 30 && totalChars <= 9000) {
      return;
    }

    // Must have at least 4 entries to meaningfully compact
    if (nonEmptyLines.length < 4) return;

    stderr.writeln(
      'Compacting speech logs for workspace $workspaceId. Total lines: ${nonEmptyLines.length}, chars: $totalChars',
    );

    // Parse all log entries
    final entries = nonEmptyLines
        .map((e) => jsonDecode(e) as Map<String, dynamic>)
        .toList();

    // We keep the last 3 entries raw, and roll up everything else (including any previous summaries)
    final keepCount = 3;
    final rollupEntries = entries.sublist(0, entries.length - keepCount);
    final keepEntries = entries.sublist(entries.length - keepCount);

    // Format the rollup entries for the AI
    final rollupSummary = rollupEntries
        .map((e) {
          final voice = e['voice'] ?? 'unknown';
          final text = e['text'] ?? '';
          return '[$voice]: "$text"';
        })
        .join('\n');

    String summaryText = '';
    final client = getAIClient();
    if (client != null) {
      final systemPrompt =
          'You are the Sigil Stone Cognitive Compactor.\n'
          'Your job is to condense a sequence of speech log entries from a pair-programming session into a single, extremely brief summary statement (2-5 sentences).\n'
          'Identify what tasks were active, which voice personas spoke, and their primary focus or outcomes.\n'
          'Keep your output professional, concise, and dense with context.\n\n'
          'OUTPUT FORMAT:\n'
          'Return ONLY a single valid JSON object containing exactly the following key:\n'
          '- "summary": "The highly concise summary statement."\n\n'
          'CRITICAL: Return ONLY raw JSON. Do not include markdown backticks or formatting.';

      final prompt =
          'Speech Logs to Compact:\n'
          '$rollupSummary\n\n'
          'Write the JSON summary for the above logs.';

      final jsonResult = await client.generateJsonCompletion(
        prompt,
        systemPrompt: systemPrompt,
        temperature: 0.5,
        maxTokens: 200,
      );

      summaryText = jsonResult?['summary'] ?? '';
    }

    // Fallback if AI call failed or returned empty
    if (summaryText.isEmpty) {
      final voices = rollupEntries.map((e) => e['voice']).toSet().join(', ');
      summaryText =
          'Development continued with contributions from active voices ($voices) focusing on coding tasks.';
    }

    final compactedSummaryEntry = {
      'timestamp': DateTime.now().toIso8601String(),
      'text': '[SUMMARY OF PREVIOUS CONTEXT]: $summaryText',
      'voice': 'system',
      'workspaceId': workspaceId,
      'length': summaryText.length + 30,
    };

    // Construct the compacted lines
    final List<Map<String, dynamic>> compactedEntries = [
      compactedSummaryEntry,
      ...keepEntries,
    ];

    // Atomically write compacted logs using a temporary file (as Mirabelle Ervine protocol dictates!)
    final tempFile = File('${file.path}.tmp');
    final buffer = StringBuffer();
    for (final entry in compactedEntries) {
      buffer.writeln(jsonEncode(entry));
    }
    await tempFile.writeAsString(buffer.toString());
    await tempFile.rename(file.path);

    stderr.writeln(
      'Compaction transaction completed successfully for workspace $workspaceId.',
    );
  } catch (e) {
    stderr.writeln('Error compacting speech logs: $e');
  }
}

Future<List<Map<String, dynamic>>> readRecentLogs(String workspaceId) async {
  final file = getLogFileForWorkspace(workspaceId);

  if (!await file.exists()) {
    return [];
  }

  final lines = await file.readAsLines();

  final recent = lines
      .where((e) => e.trim().isNotEmpty)
      .toList()
      .reversed
      .take(feedbackWindowSize)
      .toList()
      .reversed;

  return recent.map((line) {
    return jsonDecode(line) as Map<String, dynamic>;
  }).toList();
}

// ============================================================
// AUDIO-BUSY STATE (FILE-BACKED, CROSS-PROCESS)
// ============================================================
//
// An MCP server speaks over stdin and is volatile: there can be more than one
// process (multiple agents/IDEs, or an on-the-fly second Piper instance), and
// in-memory flags are invisible across them. Audio output is a single shared
// device, so "who is speaking" must live in a file that every process can see.
// A staleness timeout means a crashed speaker never deadlocks the channel.

const Duration _channelStaleAfter = Duration(seconds: 120);

File _channelLockFile(String channel) {
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  return File(path.join(logsDir.path, '$channel.lock'));
}

// Generic named audio-channel lock, coordinated across volatile MCP processes
// so playback never overlaps. The foreground voice uses the 'speaking' channel;
// the channel name is a parameter so other channels could be added later
// without duplicating this logic.
Future<void> acquireChannel(
  String channel,
  String voice,
  String workspaceId,
) async {
  try {
    await _channelLockFile(channel).writeAsString(
      jsonEncode({
        'since': DateTime.now().toIso8601String(),
        'voice': voice,
        'pid': pid,
        'workspaceId': workspaceId,
      }),
    );
  } catch (e) {
    stderr.writeln('Error acquiring channel $channel: $e');
  }
}

Future<void> releaseChannel(String channel) async {
  try {
    final f = _channelLockFile(channel);
    if (await f.exists()) await f.delete();
  } catch (e) {
    stderr.writeln('Error releasing channel $channel: $e');
  }
}

// Returns the live holder of [channel] if one exists and the lock is fresh;
// null if free or stale (a crashed holder's lock expires via the TTL).
Future<Map<String, dynamic>?> channelState(String channel) async {
  try {
    final f = _channelLockFile(channel);
    if (!await f.exists()) return null;
    final content = await f.readAsString();
    if (content.trim().isEmpty) return null;
    final m = jsonDecode(content) as Map<String, dynamic>;
    final since = DateTime.tryParse(m['since']?.toString() ?? '');
    if (since == null) return null;
    if (DateTime.now().difference(since) > _channelStaleAfter) {
      return null; // stale lock from a crashed holder
    }
    return m;
  } catch (_) {
    return null;
  }
}

// Backward-compatible wrappers for the main foreground channel.
Future<void> markSpeaking(String voice, String workspaceId) =>
    acquireChannel('speaking', voice, workspaceId);
Future<void> clearSpeaking() => releaseChannel('speaking');
Future<Map<String, dynamic>?> currentSpeakingState() =>
    channelState('speaking');
