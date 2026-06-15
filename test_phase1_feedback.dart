import 'piper_balcony.dart';
import 'piper_trip_ledger.dart';

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

  final obs = <String, dynamic>{
    'isGitRepo': true,
    'filesChanged': 1,
    'insertions': 10,
    'deletions': 0,
    'modules': {'(root)': 1},
    'moduleSpread': 1,
    'srcTouched': true,
    'testTouched': false,
  };

  final trip = evaluateTripWire(obs, [], 'arngeir');
  final concerns = List<String>.from(trip['concerns'] as List);
  check('tripwire emits stable id "missing-tests"', concerns.contains('missing-tests'));

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

  print('\n$pass passed, $fail failed');
}
