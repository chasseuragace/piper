import '../src/observation/piper_balcony.dart';
import '../src/observation/piper_trip_ledger.dart';

// Deterministic checks for the Phase 1 agent-feedback loop: tripwire concern
// ids, ack suppression, and the escalation-always-breaks-through guarantee.
Future<void> main() async {
  const ws = '/tmp/piper_phase1_test_ws';
  var pass = 0, fail = 0;
  void check(String name, bool cond) {
    if (cond) {
      pass++;
      print('PASS: $name');
    } else {
      fail++;
      print('FAIL: $name');
    }
  }

  // Hermetic start: the trip/ack ledger persists to disk keyed by workspace, so
  // a prior run's acks would otherwise pre-suppress concerns and flake the
  // "no ack -> nothing suppressed" check on the second run.
  await forgetWorkspaceLedger(ws);

  final obs = <String, dynamic>{
    'isGitRepo': true,
    'filesChanged': 1,
    'insertions': 10,
    'deletions': 0,
    'modules': {'(root)': 1},
    'moduleSpread': 1,
    'srcTouched': true,
    'testTouched': false,
    // Repo has a test harness; this change just skipped it -> "missing-tests"
    // (the per-change omission), not the standing "no-test-harness" note.
    'repoHasTests': true,
  };

  final trip = evaluateTripWire(obs, [], 'arngeir');
  final concerns = List<String>.from(trip['concerns'] as List);
  check('tripwire emits stable id "missing-tests"', concerns.contains('missing-tests'));

  // Same untested change in a repo with NO test harness: standing condition, not
  // a per-change omission -> "no-test-harness", and never the per-change id.
  final noHarnessObs = Map<String, dynamic>.from(obs)..['repoHasTests'] = false;
  final noHarness =
      List<String>.from(evaluateTripWire(noHarnessObs, [], 'arngeir')['concerns'] as List);
  check('no test harness -> emits "no-test-harness"', noHarness.contains('no-test-harness'));
  check('no test harness -> does NOT emit "missing-tests"',
      !noHarness.contains('missing-tests'));
  check('"no-test-harness" carries no severity point (stays low/none)',
      prescoreSeverity({'filesChanged': 1, 'insertions': 5, 'deletions': 0},
              ['no-test-harness']) ==
          'none');

  final before = await suppressedConcerns(ws, concerns, obs);
  check('no ack -> nothing suppressed', !before.contains('missing-tests'));

  await recordAck(ws, concernId: 'missing-tests', ack: 'not-applicable', why: 'docs only', obs: obs);
  final after = await suppressedConcerns(ws, concerns, obs);
  check('ack "not-applicable" -> concern suppressed', after.contains('missing-tests'));

  // Churn jumps from 10 (<50 bucket) to 600 (500+ bucket): must break through.
  final escalated = Map<String, dynamic>.from(obs)..['insertions'] = 600;
  final esc = await suppressedConcerns(ws, concerns, escalated);
  check('escalation breaks through suppression', !esc.contains('missing-tests'));

  // Same magnitude, one extra line: dismissal must hold (no nag on tiny edits).
  final tiny = Map<String, dynamic>.from(obs)..['insertions'] = 12;
  final held = await suppressedConcerns(ws, concerns, tiny);
  check('small follow-on edit keeps suppression', held.contains('missing-tests'));

  await recordAck(ws, concernId: 'missing-tests', ack: 'addressing', obs: obs);
  final addr = await suppressedConcerns(ws, concerns, obs);
  check('ack "addressing" (fresh) -> suppressed within TTL', addr.contains('missing-tests'));

  // Phase 2: standing acks handed to the judge (settled-intent picture).
  await recordAck(ws, concernId: 'missing-tests', ack: 'not-applicable', why: 'docs only', obs: obs);
  final standing = await standingAcks(ws, obs);
  check('standingAcks surfaces the settled concern',
      standing.any((a) => a['concern'] == 'missing-tests' && a['ack'] == 'not-applicable'));
  final standingEsc = await standingAcks(ws, escalated);
  check('standingAcks drops escalated acks (judge re-raises)',
      !standingEsc.any((a) => a['concern'] == 'missing-tests'));

  // Empty-obs guard: a clean tree must never reach the judge (no hallucinated
  // divergence from stale narration). Returns null before any client call.
  final emptyObs = <String, dynamic>{
    'isGitRepo': true,
    'filesChanged': 0,
    'insertions': 0,
    'deletions': 0,
    'modules': {},
    'moduleSpread': 0,
    'srcTouched': false,
    'testTouched': false,
    'dirtyPaths': [],
    'branch': 'x',
  };
  final nullJudge = await judgeWorkspace(
    workspaceId: ws,
    voice: 'arngeir',
    logs: [
      {'voice': 'arngeir', 'text': 'did a huge refactor', 'source': 'agent'},
    ],
    obs: emptyObs,
    tripReasons: const [],
  );
  check('empty obs -> judge returns null (no hallucinated divergence)', nullJudge == null);

  // Tier 1.2: "scattered" is dispersion (modules per file), not raw module count.
  Map<String, dynamic> mk(int files, int spread, {int churn = 0}) => {
    'isGitRepo': true,
    'filesChanged': files,
    'insertions': churn,
    'deletions': 0,
    'modules': {},
    'moduleSpread': spread,
    'srcTouched': true,
    'testTouched': true, // suppress missing-tests so we isolate "scattered"
    'dirtyPaths': [],
    'branch': 'x',
  };
  check('scattered: 4 files across 3 modules -> scattered',
      (evaluateTripWire(mk(4, 3), [], 'arngeir')['concerns'] as List).contains('scattered'));
  check('concentrated: 10 files across 3 modules -> NOT scattered',
      !(evaluateTripWire(mk(10, 3), [], 'arngeir')['concerns'] as List).contains('scattered'));

  // Tier 1.2: deterministic severity pre-score.
  check('prescore: large + scattered + untested -> high',
      prescoreSeverity({'filesChanged': 15, 'insertions': 500, 'deletions': 0}, ['scattered', 'missing-tests']) == 'high');
  check('prescore: tiny untested change -> low',
      prescoreSeverity({'filesChanged': 1, 'insertions': 5, 'deletions': 0}, ['missing-tests']) == 'low');
  check('prescore: clean tree -> none',
      prescoreSeverity({'filesChanged': 0, 'insertions': 0, 'deletions': 0}, const []) == 'none');

  // Claim-detection: "committed" claims gate on commit FRESHNESS, not on the
  // narration window. A commit made just before the agent spoke falls outside
  // the window (recentCommits empty) but is still real ground truth.
  List<String> claimIds(String text, Map<String, dynamic> o) =>
      detectClaims(text, o).map((f) => f['id'] as String).toList();

  // Base: clean tree, no in-window commit. lastCommitAgeSeconds varies below.
  Map<String, dynamic> commitObs(int? lastAge) => {
    'isGitRepo': true,
    'filesChanged': 0,
    'srcTouched': false,
    'recentCommits': const [],
    'lastCommitAgeSeconds': lastAge,
    'anyTestInWindow': false,
  };

  check('"committed" + fresh commit just before window -> no completion-claim',
      !claimIds('committed the refactor', commitObs(15)).contains('completion-claim'));
  check('"committed" + stale last commit, nothing fresh -> fires completion-claim',
      claimIds('committed the refactor', commitObs(3600)).contains('completion-claim'));
  check('"committed" + no commits at all -> fires completion-claim',
      claimIds('committed the refactor', commitObs(null)).contains('completion-claim'));
  // Boundary: a commit older than the 120s freshness window is no longer proof.
  check('"committed" + commit just past freshness window -> fires completion-claim',
      claimIds('committed the refactor', commitObs(121)).contains('completion-claim'));
  // "done" with a still-dirty tree is a separate catch freshness must NOT excuse.
  final doneDirty = commitObs(15)..['filesChanged'] = 3;
  check('"done" + fresh commit but tree still dirty -> still fires completion-claim',
      claimIds('all done', doneDirty).contains('completion-claim'));

  print('\n$pass passed, $fail failed');
}
