import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

import '../../piper_tts.dart';

// ============================================================
// CO-CHANGE COUPLING: learned structure, not a heuristic
// ============================================================
//
// "scattered" as pure module-dispersion has a blind spot: a change that spreads
// across files which HISTORICALLY move together (e.g. api + ui + model for one
// feature) is coherent, not a shotgun edit. Co-change coupling — mined from git
// history — tells the two apart. Adapted from the activity-intelligence engine's
// co-change miner, with one deliberate change: it mines ALL authors, not just
// the current user. Coupling is a property of the codebase, not of one person.
//
// Cost is controlled by the caller (consulted only when 'scattered' fires) and
// by a TTL cache here. Pure Dart + a single read-only `git log`.

const Duration _couplingTtl = Duration(hours: 6);
const int _maxCommits = 400; // bound the history window
const int _maxFrequentFiles = 300; // bound the O(n^2) pairing
const int _minSharedCommits = 2;
const double _minCouplingRatio = 0.5;
const double _coupledChangeFraction = 0.6;

File _couplingFile(String workspaceId) {
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  final slug = workspaceId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  final short = slug.length > 60 ? slug.substring(slug.length - 60) : slug;
  return File(path.join(logsDir.path, 'cochange_$short.json'));
}

// Build a file -> {coupled files} adjacency map from `git log --numstat` output.
// Pure and testable. Two files are coupled if they share >= 2 commits and that
// overlap is >= 50% of the rarer file's appearances.
Map<String, Set<String>> parseCoChange(String gitLog) {
  final commits = <Set<String>>[];
  Set<String>? cur;
  for (final line in gitLog.split('\n')) {
    if (line.startsWith('@@@')) {
      cur = <String>{};
      commits.add(cur);
      continue;
    }
    if (cur == null || line.trim().isEmpty) continue;
    final cols = line.split('\t');
    if (cols.length < 3) continue;
    final p = cols[2].trim();
    if (p.isNotEmpty) cur.add(p);
  }

  // file -> set of commit indices it appears in
  final fileToCommits = <String, Set<int>>{};
  for (var i = 0; i < commits.length; i++) {
    for (final f in commits[i]) {
      fileToCommits.putIfAbsent(f, () => {}).add(i);
    }
  }

  // Only files seen in >= 2 commits can couple; bound the pairing cost by
  // keeping the most-frequently-touched files.
  final frequent =
      fileToCommits.entries.where((e) => e.value.length >= _minSharedCommits).toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
  final capped = frequent.take(_maxFrequentFiles).toList();

  final adj = <String, Set<String>>{};
  for (var i = 0; i < capped.length; i++) {
    for (var j = i + 1; j < capped.length; j++) {
      final a = capped[i], b = capped[j];
      final shared = a.value.intersection(b.value).length;
      if (shared < _minSharedCommits) continue;
      final minApp =
          a.value.length < b.value.length ? a.value.length : b.value.length;
      if (shared / minApp >= _minCouplingRatio) {
        adj.putIfAbsent(a.key, () => {}).add(b.key);
        adj.putIfAbsent(b.key, () => {}).add(a.key);
      }
    }
  }
  return adj;
}

// Is this change coherent coupling rather than scatter? True when most of the
// changed files have a coupling partner that is ALSO in the changeset — i.e. the
// change tracks the codebase's own grain. Pure and testable.
bool changeIsCoupled(List<String> changed, Map<String, Set<String>> coupling) {
  if (changed.length < 2 || coupling.isEmpty) return false;
  final set = changed.toSet();
  var coupled = 0;
  for (final f in changed) {
    final partners = coupling[f];
    if (partners != null && partners.any(set.contains)) coupled++;
  }
  return coupled / changed.length >= _coupledChangeFraction;
}

Future<Map<String, Set<String>>> _mineCoupling(String workspaceId) async {
  try {
    final r = await Process.run('git', [
      'log',
      '-n',
      '$_maxCommits',
      '--no-merges',
      '--pretty=format:@@@%H',
      '--numstat',
    ], workingDirectory: workspaceId);
    if (r.exitCode != 0) return {};
    return parseCoChange(r.stdout as String);
  } catch (_) {
    return {};
  }
}

// The coupling map for the workspace, cached with a TTL. On a cache miss it
// mines git history once and writes the cache. Returns {} on any failure (the
// caller then falls back to pure module-dispersion 'scattered').
Future<Map<String, Set<String>>> couplingMap(String workspaceId) async {
  final f = _couplingFile(workspaceId);
  if (await f.exists()) {
    try {
      if (DateTime.now().difference(f.statSync().modified) < _couplingTtl) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return data.map(
          (k, v) => MapEntry(k, Set<String>.from(v as List)),
        );
      }
    } catch (_) {}
  }
  final adj = await _mineCoupling(workspaceId);
  try {
    await f.writeAsString(
      jsonEncode(adj.map((k, v) => MapEntry(k, v.toList()))),
    );
  } catch (_) {}
  return adj;
}
