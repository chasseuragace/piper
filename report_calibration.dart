import 'src/feedback/piper_calibration.dart';

// Prints the balcony's self-calibration: which tripwire concerns the developer
// keeps dismissing. Pure arithmetic over the ack history — no model involved.
//   dart run report_calibration.dart
Future<void> main() async {
  final report = await calibrationReport();
  if (report.isEmpty) {
    print('No acks recorded yet — nothing to calibrate.');
    return;
  }

  print('Concern calibration (noisiest first):\n');
  print('  ${'concern'.padRight(24)}${'total'.padLeft(6)}${'false+'.padLeft(8)}${'fp-rate'.padLeft(9)}');
  for (final r in report) {
    final concern = (r['concern'] as String).padRight(24);
    final total = (r['total'] as int).toString().padLeft(6);
    final fp = (r['falsePositives'] as int).toString().padLeft(8);
    final rate = '${((r['fpRate'] as double) * 100).toStringAsFixed(0)}%'.padLeft(9);
    print('  $concern$total$fp$rate');
  }

  final noisy = await noisyConcerns();
  if (noisy.isNotEmpty) {
    print('\nNoisy tripwires (raise the bar):');
    for (final n in noisy) {
      print('  - ${n['concern']}: dismissed ${n['falsePositives']}/${n['total']}');
    }
  } else {
    print('\nNo concern is over-firing past the noise threshold yet.');
  }
}
