import '../src/feedback/piper_calibration.dart';

// Deterministic checks for Tier 3 calibration: the ack stream as a labeled
// false-positive dataset. Uses unique concern ids to avoid touching real stats.
Future<void> main() async {
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

  const c = 'zzz-test-concern';
  // 4 dismissals + 1 acceptance => 80% false-positive rate over 5 acks.
  await recordAckStat(c, 'disagree');
  await recordAckStat(c, 'not-applicable');
  await recordAckStat(c, 'disagree');
  await recordAckStat(c, 'not-applicable');
  await recordAckStat(c, 'intentional');

  final report = await calibrationReport();
  final row = report.firstWhere((r) => r['concern'] == c, orElse: () => {});
  check('report tallies total', row['total'] == 5);
  check('report counts false positives (disagree + not-applicable)', row['falsePositives'] == 4);
  check('fp-rate computed', (row['fpRate'] as double) == 0.8);

  final noisy = await noisyConcerns();
  check('noisy flags the over-firing concern', noisy.any((n) => n['concern'] == c));

  // Below the sample floor -> not flagged (one dismissal is not a pattern).
  const c2 = 'zzz-test-concern-rare';
  await recordAckStat(c2, 'disagree');
  final noisy2 = await noisyConcerns();
  check('below-sample concern not flagged', !noisy2.any((n) => n['concern'] == c2));

  print('\n$pass passed, $fail failed');
}
