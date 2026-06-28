import 'dart:io';
import 'package:path/path.dart' as path;

import '../persona/piper_personas.dart';
import '../llm/piper_ai_client.dart';
import '../llm/piper_local_llm.dart';

// ============================================================
// THE BALCONY: READ-ONLY WORKSPACE OBSERVATION (ZERO TOKENS)
// ============================================================

// Runs a read-only git command in [dir]. Never writes, never runs project
// code/hooks. Returns stdout on success, empty string otherwise.
Future<String> _git(String dir, List<String> args) async {
  try {
    final r = await Process.run('git', args, workingDirectory: dir);
    if (r.exitCode != 0) return '';
    return (r.stdout as String);
  } catch (_) {
    return '';
  }
}

// Buckets a repo-relative path into a coarse "module" key (first 1-2 segments)
// so we can tell whether change is concentrated or smeared across the tree.
String _moduleOf(String relPath) {
  final parts = relPath.split('/').where((e) => e.isNotEmpty).toList();
  if (parts.length <= 1) return '(root)';
  if (parts.length == 2) return parts.first;
  return '${parts[0]}/${parts[1]}';
}

bool _looksLikeTest(String p) {
  final lower = p.toLowerCase();
  return lower.contains('/test/') ||
      lower.startsWith('test/') ||
      lower.contains('/tests/') ||
      lower.endsWith('_test.dart') ||
      lower.endsWith('.test.ts') ||
      lower.endsWith('.test.js') ||
      lower.endsWith('_spec.rb') ||
      lower.contains('spec/');
}

// Steps off the dance floor: observes the *actual* state of the workspace
// (git ground truth) rather than what the agent narrated. Cheap, no LLM.
//
// [since] marks the narration window start (oldest in-window log entry).
// Narration tracks *activity*, and activity is commits + working tree — but the
// tree goes blank the instant work is committed, which is exactly when narration
// says "done, tests pass". We read the last several commits by COUNT (so a
// commit made just BEFORE the window — the one being claimed — is still seen)
// and tag each as in-window (ts >= since) or older. Window commits drive the
// rollups + clean-tree guard; the older trail gives the judge the session arc
// and lets feedback say "last commit was N ago" instead of "no commit".
Future<Map<String, dynamic>> observeWorkspace(
  String workspaceId, {
  DateTime? since,
}) async {
  final result = <String, dynamic>{
    'isGitRepo': false,
    'filesChanged': 0,
    'insertions': 0,
    'deletions': 0,
    'modules': <String, int>{},
    'moduleSpread': 0,
    'srcTouched': false,
    'testTouched': false,
    'recentFile': null,
    'dirtyPaths': <String>[],
    'branch': null,
    // Commits made within the narration window (trimmed to stats, no diffs).
    'recentCommits': <Map<String, dynamic>>[],
    // Commits OLDER than the window — session trajectory / claim-freshness.
    'olderCommits': <Map<String, dynamic>>[],
    'committedFiles': 0,
    'committedChurn': 0,
    // Age (seconds) of the newest commit overall, or null if none.
    'lastCommitAgeSeconds': null,
    // Tests touched in the window by EITHER the tree or an in-window commit.
    'anyTestInWindow': false,
    // Standing fact: does the repo contain ANY test-shaped file at all? Lets us
    // tell "this change skipped tests" (repo tests, you didn't) from "no test
    // harness exists" (a property of the repo, not the change).
    'repoHasTests': false,
  };

  try {
    final dir = Directory(workspaceId);
    if (!dir.existsSync()) return result;

    final inside = await _git(workspaceId, [
      'rev-parse',
      '--is-inside-work-tree',
    ]);
    if (inside.trim() != 'true') return result;
    result['isGitRepo'] = true;

    final branch = await _git(workspaceId, [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ]);
    if (branch.trim().isNotEmpty) result['branch'] = branch.trim();

    // STANDING FACT: does this repo have ANY test-shaped file at all? ONE git
    // listing — names only, never contents, never per-commit — narrowed by
    // pathspecs that mirror _looksLikeTest, then confirmed through that same
    // authority so there's a single definition of "test". git stops emitting at
    // the first match candidate set; we break on the first confirmed hit. This
    // separates a per-change omission ("missing-tests") from a repo property
    // ("no-test-harness") so the latter doesn't re-fire every time the diff grows.
    final testListing = await _git(workspaceId, [
      'ls-files',
      '--',
      '*_test.dart',
      '*.test.ts',
      '*.test.js',
      '*_spec.rb',
      'test/*',
      '*/test/*',
      '*/tests/*',
      'spec/*',
      '*/spec/*',
    ]);
    for (final line in testListing.split('\n')) {
      final p = line.trim();
      if (p.isEmpty) continue;
      if (_looksLikeTest(p)) {
        result['repoHasTests'] = true;
        break;
      }
    }

    // Magnitude + spread of tracked changes vs HEAD.
    final numstat = await _git(workspaceId, ['diff', 'HEAD', '--numstat']);
    final modules = <String, int>{};
    int filesChanged = 0, insertions = 0, deletions = 0;
    bool srcTouched = false, testTouched = false;
    final changedPaths = <String>[];

    for (final line in numstat.split('\n')) {
      if (line.trim().isEmpty) continue;
      final cols = line.split('\t');
      if (cols.length < 3) continue;
      final ins = int.tryParse(cols[0]) ?? 0; // '-' for binary => 0
      final del = int.tryParse(cols[1]) ?? 0;
      final p = cols[2].trim();
      if (p.isEmpty) continue;
      filesChanged++;
      insertions += ins;
      deletions += del;
      modules[_moduleOf(p)] = (modules[_moduleOf(p)] ?? 0) + 1;
      if (_looksLikeTest(p)) {
        testTouched = true;
      } else {
        srcTouched = true;
      }
      changedPaths.add(p);
    }

    // Untracked files (new work git diff won't show). -uall lists each file
    // individually; without it git collapses an untracked directory into one
    // entry (?? scratch/), undercounting fresh work to a single file.
    final status = await _git(workspaceId, [
      'status',
      '--porcelain',
      '-uall',
    ]);
    for (final line in status.split('\n')) {
      if (line.length < 4) continue;
      if (line.startsWith('??')) {
        final p = line.substring(3).trim();
        if (p.isEmpty) continue;
        modules[_moduleOf(p)] = (modules[_moduleOf(p)] ?? 0) + 1;
        if (_looksLikeTest(p)) {
          testTouched = true;
        } else {
          srcTouched = true;
        }
        if (!changedPaths.contains(p)) {
          changedPaths.add(p);
          filesChanged++;
        }
      }
    }

    // Most-recently-modified changed file (where the heat is right now).
    String? recentFile;
    DateTime? recentMtime;
    for (final p in changedPaths) {
      try {
        final f = File(path.join(workspaceId, p));
        if (!f.existsSync()) continue;
        final m = f.statSync().modified;
        if (recentMtime == null || m.isAfter(recentMtime)) {
          recentMtime = m;
          recentFile = p;
        }
      } catch (_) {}
    }

    result['filesChanged'] = filesChanged;
    result['insertions'] = insertions;
    result['deletions'] = deletions;
    result['modules'] = modules;
    result['moduleSpread'] = modules.length;
    result['srcTouched'] = srcTouched;
    result['testTouched'] = testTouched;
    result['recentFile'] = recentFile;
    result['dirtyPaths'] = changedPaths.take(20).toList();

    // ----------------------------------------------------------------
    // COMMIT ACTIVITY — last N by count, partitioned by the window
    // ----------------------------------------------------------------
    // Read the last several commits by COUNT (not --since), trimmed to the SAME
    // shape as the tree observation (subject + numstat rollups, never diff
    // bodies) plus a committer timestamp. Pure git, zero model cost. By-count so
    // a commit made just BEFORE the window — the one an "I committed it" claim
    // refers to — is still seen; we then split in-window vs older by timestamp.
    bool anyCommittedTest = false;
    final log = await _git(workspaceId, [
      'log',
      '--no-merges',
      '--numstat',
      // \u001f-prefixed header line separates each commit's
      // "hash<TAB>unixtime<TAB>subject" from the tab-separated numstat rows
      // that follow it. %ct is the committer date as a unix timestamp.
      '--format=\u001f%h\t%ct\t%s',
      '-n',
      '12',
    ]);

    final allCommits = <Map<String, dynamic>>[];
    Map<String, dynamic>? cur;
    Set<String> curModules = <String>{};
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sinceMs = since?.millisecondsSinceEpoch;
    for (final line in log.split('\n')) {
      if (line.startsWith('\u001f')) {
        final parts = line.substring(1).split('\t');
        final ts = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
        curModules = <String>{};
        cur = {
          'hash': parts.isNotEmpty ? parts[0] : '',
          'subject': parts.length > 2 ? parts[2] : '',
          'ageSeconds': ts > 0 ? nowSec - ts : null,
          // In-window iff committed at/after the narration started.
          'inWindow': sinceMs != null && ts * 1000 >= sinceMs,
          'files': 0,
          'insertions': 0,
          'deletions': 0,
          'moduleSpread': 0,
          'testTouched': false,
        };
        allCommits.add(cur);
      } else if (cur != null && line.trim().isNotEmpty) {
        final cols = line.split('\t');
        if (cols.length < 3) continue;
        final ins = int.tryParse(cols[0]) ?? 0; // '-' for binary => 0
        final del = int.tryParse(cols[1]) ?? 0;
        final p = cols[2].trim();
        if (p.isEmpty) continue;
        cur['files'] = (cur['files'] as int) + 1;
        cur['insertions'] = (cur['insertions'] as int) + ins;
        cur['deletions'] = (cur['deletions'] as int) + del;
        curModules.add(_moduleOf(p));
        cur['moduleSpread'] = curModules.length;
        if (_looksLikeTest(p)) cur['testTouched'] = true;
      }
    }

    // Partition: window commits drive the rollups + clean-tree guard; the older
    // trail (capped) is context only. Rollups stay window-scoped so the
    // missing-tests fix and the line-279 guard keep their Part A semantics.
    final recentCommits =
        allCommits.where((c) => c['inWindow'] == true).toList();
    final olderCommits =
        allCommits.where((c) => c['inWindow'] != true).take(7).toList();
    int committedFiles = 0, committedChurn = 0;
    for (final c in recentCommits) {
      committedFiles += c['files'] as int;
      committedChurn += (c['insertions'] as int) + (c['deletions'] as int);
      if (c['testTouched'] == true) anyCommittedTest = true;
    }

    result['recentCommits'] = recentCommits;
    result['olderCommits'] = olderCommits;
    result['committedFiles'] = committedFiles;
    result['committedChurn'] = committedChurn;
    result['lastCommitAgeSeconds'] =
        allCommits.isNotEmpty ? allCommits.first['ageSeconds'] : null;

    // Tests count as present in the window if the tree OR any in-window commit
    // touched them — this is what stops "missing-tests" from firing right after
    // the tests were committed (they leave the dirty tree, but the work is done).
    result['anyTestInWindow'] = testTouched || anyCommittedTest;
  } catch (e) {
    stderr.writeln('Error observing workspace: $e');
  }
  return result;
}

// A compact one-liner summary of an observation, for prompts/returns.
String summarizeObservation(Map<String, dynamic> obs) {
  if (obs['isGitRepo'] != true) return 'No git ground truth available.';
  final modules = (obs['modules'] as Map).keys.join(', ');
  final base =
      'branch=${obs['branch']}, ${obs['filesChanged']} files '
      '(+${obs['insertions']}/-${obs['deletions']}) across '
      '${obs['moduleSpread']} module(s) [$modules]; '
      'src=${obs['srcTouched']} tests=${obs['testTouched']}; '
      'hot=${obs['recentFile'] ?? '-'}';

  String trimSubj(Map m) {
    final subj = (m['subject'] ?? '').toString();
    return subj.length > 50 ? '${subj.substring(0, 49)}…' : subj;
  }

  // In-window commits are part of ground truth: their subjects carry the
  // developer's own committed claims, and the work the tree no longer shows.
  final commits = (obs['recentCommits'] as List?) ?? const [];
  var out = base;
  if (commits.isNotEmpty) {
    final commitStr = commits.map((c) {
      final m = c as Map;
      final tests = m['testTouched'] == true ? ' +tests' : '';
      return '${m['hash']} "${trimSubj(m)}" '
          '(${m['files']}f +${m['insertions']}/-${m['deletions']}$tests)';
    }).join(' | ');
    out = '$out; commits[${commits.length}]: $commitStr';
  }

  // The older trail (subjects only) gives the judge the session arc — what has
  // actually landed before this window — without re-stating full stats.
  final older = (obs['olderCommits'] as List?) ?? const [];
  if (older.isNotEmpty) {
    final olderStr =
        older.map((c) => '${(c as Map)['hash']} "${trimSubj(c)}"').join(', ');
    out = '$out; earlier: $olderStr';
  }
  return out;
}

// ============================================================
// TRIP-WIRE: should we pay for the LLM judge? (cheap, no tokens)
// ============================================================

Map<String, dynamic> evaluateTripWire(
  Map<String, dynamic> obs,
  List<Map<String, dynamic>> logs,
  String voice,
) {
  // Each fired signal carries a STABLE id (for deterministic ack-matching) and a
  // human reason (for the judge prompt). The two lists stay index-aligned.
  final concerns = <String>[];
  final reasons = <String>[];
  void fire(String id, String reason) {
    concerns.add(id);
    reasons.add(reason);
  }

  final filesChanged = (obs['filesChanged'] as int?) ?? 0;
  final churn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);
  final spread = (obs['moduleSpread'] as int?) ?? 0;

  if (filesChanged >= 6) fire('sprawl', 'sprawl: $filesChanged files touched');
  // Scattered = sprayed thin, not merely "many modules". A coherent change of 9
  // files in 3 modules is NOT scattered; 4 files in 4 modules (one per module)
  // is. Measure dispersion as modules-per-file: near 1 means each file lives in
  // its own module — a shotgun edit.
  if (filesChanged >= 4 && spread >= 3 && spread / filesChanged >= 0.6) {
    fire('scattered', 'scattered: $spread modules for $filesChanged files');
  }
  if (churn >= 150) fire('large-churn', 'large churn ($churn lines)');
  // Tests committed earlier in the window count — otherwise this nags on the
  // very next source edit after you commit the tests (they left the dirty tree).
  final testsInWindow =
      obs['testTouched'] == true || obs['anyTestInWindow'] == true;
  if (obs['srcTouched'] == true && !testsInWindow) {
    if (obs['repoHasTests'] == true) {
      // The repo tests, this change didn't — a real per-change omission.
      fire('missing-tests', 'source changed without tests');
    } else {
      // No test-shaped file exists anywhere — there's nothing to hang a test on.
      // This is a property of the repo, not the change, so it carries no severity
      // point (see prescoreSeverity) and rides a distinct id: meant as a one-time
      // soft note, not a tripwire that revives on every diff-growth.
      fire('no-test-harness',
          'no test harness in repo — source changed with nothing to test against');
    }
  }

  int streak = 1;
  for (final entry in logs.reversed) {
    if (entry['voice'] == voice && entry['source'] != 'observer') {
      streak++;
    } else {
      break;
    }
  }
  if (streak >= 5) {
    fire('lens-streak', 'held the $voice lens for $streak turns');
  }

  return {
    'tripped': reasons.isNotEmpty,
    'reasons': reasons,
    'concerns': concerns,
    'streak': streak,
  };
}

// A deterministic severity prior from the raw facts alone — no model. Magnitude
// (churn, files) plus qualitative concerns the magnitude misses (scattered,
// missing-tests). The LLM judge anchors to this instead of inventing a severity
// from scratch, which is where it tends to hallucinate.
String prescoreSeverity(Map<String, dynamic> obs, List<String> concerns) {
  final files = (obs['filesChanged'] as int?) ?? 0;
  final churn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);

  var points = 0;
  if (churn >= 400) {
    points += 2;
  } else if (churn >= 150) {
    points += 1;
  }
  if (files >= 12) {
    points += 2;
  } else if (files >= 6) {
    points += 1;
  }
  if (concerns.contains('scattered')) points += 1;
  if (concerns.contains('missing-tests')) points += 1;
  // A claim that contradicts ground truth (said tests pass / committed / done
  // when git disagrees) is the documented #1 agent failure — weight it.
  if (concerns.contains('test-claim')) points += 1;
  if (concerns.contains('completion-claim')) points += 1;

  if (points >= 4) return 'high';
  if (points >= 2) return 'medium';
  if (points >= 1) return 'low';
  return 'none';
}

// ============================================================
// CLAIM DETECTION: narration-vs-reality contradictions (zero tokens)
// ============================================================
//
// The agent's CURRENT utterance is the freshest claim; git (tree + commits,
// including the older trail) is reality. We match formulaic AI claim phrasing —
// these are repetitive verbal tics, not creative prose, so keyword matching is
// reliable here — and fire ONLY when a claim co-occurs with a contradicting
// fact. A claim alone never fires; reality must disagree. Each fire is
// {id, reason}, the same shape the tripwire emits, so it flows through the
// existing suppress / gate / ack / calibration path untouched.
List<Map<String, String>> detectClaims(
  String currentText,
  Map<String, dynamic> obs,
) {
  final fires = <Map<String, String>>[];
  final text = currentText.toLowerCase();

  // True iff one of [phrases] appears AND is not negated/questioned nearby.
  bool claimed(List<String> phrases) {
    for (final p in phrases) {
      var from = 0;
      while (true) {
        final idx = text.indexOf(p, from);
        if (idx < 0) break;
        from = idx + p.length;
        // Negation guard: a negator in the ~24 chars before the match flips it
        // ("this is NOT done", "yet to verify", "about to commit", "should I").
        final preStart = (idx - 24) < 0 ? 0 : idx - 24;
        final pre = text.substring(preStart, idx);
        final negated = RegExp(
          r"\b(not|isn'?t|aren'?t|wasn'?t|no|don'?t|doesn'?t|didn'?t|won'?t|"
          r"can'?t|hardly|never|yet to|need(s)? to|about to|trying to|going to|"
          r"want to|should i|do i|will i|let me|to)\b\s*$",
        ).hasMatch(pre);
        // Question guard: a '?' within ~24 chars after means it's not a claim.
        final postEnd = (from + 24) > text.length ? text.length : from + 24;
        final questioned = text.substring(idx, postEnd).contains('?');
        if (!negated && !questioned) return true;
      }
    }
    return false;
  }

  final filesChanged = (obs['filesChanged'] as int?) ?? 0;
  final srcTouched = obs['srcTouched'] == true;
  final recentCommits = (obs['recentCommits'] as List?) ?? const [];
  final noWindowCommit = recentCommits.isEmpty;
  final lastAge = obs['lastCommitAgeSeconds'] as int?;
  // A commit made just BEFORE the agent started narrating sits outside the
  // window (which is a story boundary, not a ground-truth one), so it won't
  // appear in recentCommits. But a genuinely fresh commit IS the "I committed
  // it" the agent is claiming. Freshness — not window membership — is what
  // separates an honest claim (committed 15s ago, tree clean) from a stale one
  // (last commit an hour ago, work still dirty). 120s mirrors _tripCooldown.
  final hasFreshCommit = lastAge != null && lastAge <= 120;

  // Phrase the staleness of the newest commit for a concrete reason line.
  String commitTrail() {
    if (lastAge == null) return 'no commits found';
    final mins = lastAge ~/ 60;
    if (mins < 1) return 'last commit <1 min ago';
    if (mins < 90) return 'last commit ${mins}m ago, before this work';
    return 'last commit ${lastAge ~/ 3600}h ago, before this work';
  }

  // --- test-claim: said tests pass/verified, but no tests in the window ---
  final saysTestsPass = claimed([
    'tests pass',
    'test passes',
    'tests passing',
    'all green',
    'all-green', // real 2026 agent tic (esp. weaker agents: "verified all-green")
    'are green',
    'go green',
    'went green',
    'verified',
    'added tests',
    'wrote tests',
    'test coverage',
  ]);
  if (saysTestsPass && srcTouched && obs['anyTestInWindow'] != true) {
    fires.add({
      'id': 'test-claim',
      'reason': 'narration claims tests pass/verified, but no test changed in '
          'the window (tree or commits)',
    });
  }

  // --- completion-claim: said committed/shipped/done, but git disagrees ---
  // Two sub-rules, one concern. Commit-claim is the rock-solid form (Part A);
  // done-claim is the softer "premature done" (claimed finished, work still
  // uncommitted in the tree).
  final saysCommitted = claimed([
    'committed',
    'pushed',
    'shipped',
    'landed it',
    'merged',
  ]);
  final saysDone = claimed([
    'done',
    'successfully',
    'should now work',
    'now works',
    'fully implemented',
    'fully working',
    'wired in',
    'all set',
    'good to go',
    // "complete" is the #1 AI completion word but also a goal ("complete the
    // port"); only the phrase forms below are claims, never bare "complete".
    'is complete',
    'now complete',
    'fully complete',
    'finalized',
  ]);
  if (saysCommitted && noWindowCommit && !hasFreshCommit) {
    fires.add({
      'id': 'completion-claim',
      'reason':
          'narration claims work was committed/shipped, but no commit landed '
          'in this window (${commitTrail()})',
    });
  } else if (saysDone && filesChanged > 0 && noWindowCommit) {
    fires.add({
      'id': 'completion-claim',
      'reason': 'narration claims the work is done, but it is still uncommitted '
          'in the tree ($filesChanged file(s) dirty, ${commitTrail()})',
    });
  }

  return fires;
}

// ============================================================
// THE JUDGE: grounded intervention (LLM, only when tripped)
// ============================================================

// Looks at ground truth + narration together, decides whether the balcony
// should intervene, how severely, in which persona-lens, and with what (if
// any) spoken line. Returns null on failure.
Future<Map<String, dynamic>?> judgeWorkspace({
  required String workspaceId,
  required String voice,
  required List<Map<String, dynamic>> logs,
  required Map<String, dynamic> obs,
  required List<String> tripReasons,
  List<Map<String, String>> acknowledged = const [],
  String prescore = 'none',
}) async {
  try {
    // Nothing in the working tree AND nothing committed in the window -> nothing
    // to diverge from; skip the judge so it cannot hallucinate drift against
    // stale narration. But a clean tree with in-window COMMITS is not empty: the
    // tree going clean is exactly the "done, shipped" moment, and the commits
    // are the ground truth to check the narration against — so we proceed.
    final treeClean = (((obs['filesChanged'] as int?) ?? 0) == 0);
    final noCommits = ((obs['recentCommits'] as List?) ?? const []).isEmpty;
    if (treeClean && noCommits) return null;

    final client = getAIClient();
    if (client == null) return null;

    final narration = logs.isEmpty
        ? 'No prior narration. Session is just beginning.'
        : logs
              .map(
                (l) =>
                    '- [${l['voice']}${l['source'] == 'observer' ? '/balcony' : ''}]: "${l['text']}"',
              )
              .join('\n');

    // PASS 1 — DIAGNOSE (cloud, nuanced): divergence + severity + verdict only.
    // No persona, no voice — just the truth. A single-purpose prompt reasons
    // far better than one juggling diagnosis, routing, and voicing at once.
    final diag = await _diagnose(
      client: client,
      workspaceId: workspaceId,
      voice: voice,
      obs: obs,
      narration: narration,
      tripReasons: tripReasons,
      acknowledged: acknowledged,
      prescore: prescore,
    );
    if (diag == null) return null;

    final severity = (diag['severity'] ?? 'low').toString();
    final result = <String, dynamic>{
      'severity': severity,
      'verdict': (diag['verdict'] ?? '').toString(),
      'divergence': (diag['divergence'] ?? '').toString(),
      'recommendedVoice': voice,
      'spokenLine': '',
      'observation': summarizeObservation(obs),
    };

    // Only a high-severity finding ever speaks, so only then do we pay for the
    // two focused follow-up passes — both free, on-device.
    if (severity == 'high') {
      // PASS 2 — ROUTE (local, focused): pick the best-fit lens for THIS issue,
      // judged on the diagnosis alone, not anchored to the current voice.
      final lens = await _routeLens(diag) ?? voice;
      result['recommendedVoice'] = lens;
      // PASS 3 — VOICE (local, focused): compose the line AS that persona,
      // carrying the concrete facts so the heard channel delivers real feedback.
      result['spokenLine'] = await _composeSpokenLine(lens, diag, obs) ?? '';
    }

    return result;
  } catch (e) {
    stderr.writeln('Error in judgeWorkspace: $e');
    return null;
  }
}

// PASS 1 — DIAGNOSE: detect story-vs-reality divergence and score it. The hard,
// nuanced reasoning — kept on the cloud model. Knows nothing of personas.
Future<Map<String, dynamic>?> _diagnose({
  required dynamic client,
  required String workspaceId,
  required String voice,
  required Map<String, dynamic> obs,
  required String narration,
  required List<String> tripReasons,
  List<Map<String, String>> acknowledged = const [],
  String prescore = 'none',
}) async {
  final systemPrompt =
      'You are the Balcony: an outside observer of a live coding session. The '
      'developer is immersed and carried by momentum; you are not. You weigh '
      'two things they cannot: GROUND TRUTH (real git facts) and NARRATION '
      '(what they said they were doing).\n\n'
      'Detect DIVERGENCE between story and reality. Examples: said "small fix" '
      'but the diff is large; narrated one module but edited another; claimed '
      'done/tests pass but no test changed; long narration, nothing changed '
      '(spinning); many changes, no narration (going dark).\n\n'
      'GROUND TRUTH may include recent COMMITS (hash, subject, stats) alongside '
      'the working tree. Commit SUBJECTS are the developer\'s own claims, not '
      'proof — a subject saying "verified", "all-green" or "all tests passing" '
      'is NOT evidence. A "done"/"committed" claim IS satisfied by a listed '
      'commit existing (so do not flag drift just because the uncommitted diff '
      'is empty), but a "tests pass" claim is satisfied ONLY by a commit shown '
      'with +tests (it actually changed tests), never by the subject wording.\n\n'
      'The developer may have ACKNOWLEDGED some concerns (intentional, '
      'not-applicable, being-addressed, or disputed). A listed acknowledgement '
      'is SETTLED: do not raise that concern again. Only override it if the '
      'change has clearly grown much larger than the acknowledgement implies.\n\n'
      'Be SPARING — most turns are fine. Reserve "high" for genuine, '
      'worth-interrupting divergence.\n\n'
      'A deterministic PRE-SCORE (from raw size facts) is given as your prior. '
      'Start from it; move off it only for a clear story-vs-reality reason.\n\n'
      'Return ONLY JSON: {"severity": "none|low|medium|high", "verdict": '
      '"1-2 neutral sentences for the developer to read", "divergence": "what '
      'drifted, or empty"}. Raw JSON only, no markdown.';

  final ackBlock = acknowledged.isEmpty
      ? '(none)'
      : acknowledged
            .map(
              (a) =>
                  '- ${a['concern']}: ${a['ack']}${a['why'] != null ? ' (${a['why']})' : ''}',
            )
            .join('\n');

  final prompt =
      'GROUND TRUTH (git):\n${summarizeObservation(obs)}\n'
      'Changed paths: ${(obs['dirtyPaths'] as List).join(', ')}\n\n'
      'CHEAP SIGNALS THAT FIRED: ${tripReasons.isEmpty ? '(none — routine check)' : tripReasons.join('; ')}\n\n'
      'DETERMINISTIC PRE-SCORE (severity prior from raw size facts): $prescore\n\n'
      'DEVELOPER ACKNOWLEDGEMENTS (already settled — do not re-flag these):\n$ackBlock\n\n'
      'NARRATION HISTORY (what the developer said):\n$narration\n\n'
      'Diagnose the divergence and score its severity.';

  return client.generateJsonCompletion(
    prompt,
    systemPrompt: systemPrompt,
    temperature: 0.5,
    maxTokens: 200,
  );
}

// PASS 2 — ROUTE: pick the persona-lens whose focus best fits the diagnosed
// problem. One decision, judged on the problem alone (not the current voice),
// which is exactly why it routes accurately. Free, on-device.
Future<String?> _routeLens(Map<String, dynamic> diag) async {
  final voiceList = voiceDescriptions.entries
      .map((e) => '- ${e.key}: ${e.value}')
      .join('\n');
  final systemPrompt =
      'Choose the single best-fit reviewer for a coding concern. Match the '
      'concern to the reviewer whose focus fits it (e.g. security issue -> the '
      'vigilant one; missing tests -> the testing one; sprawling change -> the '
      'simplifier or the architect). Return ONLY JSON: {"voice": "<key>"} using '
      'one key from the list. Raw JSON only.';
  final prompt =
      'Reviewers:\n$voiceList\n\n'
      'Concern: ${diag['verdict']}\n'
      'Divergence: ${diag['divergence']}\n\n'
      'Which reviewer fits best?';

  final r = await cheapJson(prompt, systemPrompt: systemPrompt, maxTokens: 40);
  final key = (r?['voice'] ?? '').toString();
  return voiceDescriptions.containsKey(key) ? key : null;
}

// PASS 3 — VOICE: compose the spoken line AS the chosen persona. One job —
// styling the diagnosis in-character — so the voice discipline actually sticks.
// Free, on-device.
Future<String?> _composeSpokenLine(
  String lens,
  Map<String, dynamic> diag,
  Map<String, dynamic> obs,
) async {
  final persona = voiceDescriptions[lens] ?? 'A wise mentor.';

  // Curated, human-phrased facts — NOT the raw debug summary, so the persona
  // weaves real numbers in naturally instead of reciting "src=true tests=false".
  final files = (obs['filesChanged'] as int?) ?? 0;
  final churn =
      ((obs['insertions'] as int?) ?? 0) + ((obs['deletions'] as int?) ?? 0);
  final noTests = obs['srcTouched'] == true && obs['testTouched'] != true;
  // Large line counts get a speech-safe "over N00" phrasing — a small model
  // tends to mangle exact figures (409 -> "forty-one hundred") when it spells
  // them out, but "over 400" it just repeats, and it is never wrong. Small
  // counts (files, low churn) stay exact.
  final churnPhrase = churn >= 100 ? 'over ${(churn ~/ 100) * 100} lines' : '$churn lines';
  final facts = [
    '$files files changed',
    churnPhrase,
    if (noTests) 'no tests updated',
  ].join(', ');

  final systemPrompt =
      'You ARE this character: $persona\n\n'
      'Say AT MOST TWO short sentences to a fellow craftsman, in your own diction '
      'and cadence. THIS IS HEARD ALOUD and is the only feedback the listener '
      'gets, so weave in the two or three most telling facts so they learn WHAT '
      'is wrong — not merely that something is. Use the numbers EXACTLY as given '
      '(as digits). Speak naturally as that character; do NOT recite field names, '
      'branch names, or file paths like a report. Be brief — no sermons. Flavour '
      'wraps the facts; it never replaces them. Address the listener as your '
      'character would (comrade, apprentice, soldier). NEVER use the words '
      '"agent", "AI", "assistant", "user", or "model". Return ONLY JSON: '
      '{"line": "<your words>"}.';
  final prompt =
      'Key facts: $facts.\n'
      'The contradiction: ${diag['divergence']}\n\n'
      'Say your concise piece — name the most telling facts, in your voice.';

  final r = await cheapJson(prompt, systemPrompt: systemPrompt, maxTokens: 90);
  final line = (r?['line'] ?? '').toString().trim();
  if (line.isEmpty) return null;
  // Hard cap: verbose personas (e.g. Arngeir) ignore "be brief" — enforce it.
  final capped = _firstSentences(line, 2);
  // Drop fact-free output: a cryptic persona (e.g. Septimus) can dodge the
  // substance entirely ("the patterns..."). Better silent than a heard line
  // that says nothing — the factual verdict still reaches the agent.
  // A real intervention names a concrete number (file/line counts) or speaks to
  // tests. Require a DIGIT or an explicit "test(s)" mention — a bare "files" or
  // "line" with no number is exactly how a rambling persona sneaks past ("Zero
  // files altered, yet the narrative expands...").
  final carriesFact =
      RegExp(r'\d').hasMatch(capped) ||
      RegExp(r'\btests?\b', caseSensitive: false).hasMatch(capped);
  return carriesFact ? capped : null;
}

// Returns the first [n] sentences of [s], trimmed, skipping empty/punctuation-
// only fragments. A backstop so a rambling persona line can never run on past
// two sentences when heard aloud.
String _firstSentences(String s, int n) {
  final out = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    buf.write(s[i]);
    if ('.!?'.contains(s[i])) {
      final seg = buf.toString().trim();
      buf.clear();
      if (seg.replaceAll(RegExp(r'[.!?\s]'), '').isEmpty) continue;
      out.add(seg);
      if (out.length >= n) break;
    }
  }
  if (out.length < n && buf.toString().trim().isNotEmpty) {
    out.add(buf.toString().trim());
  }
  return out.join(' ').trim();
}
