import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

import 'piper_tts.dart';

// ============================================================
// CALIBRATION: the feedback loop is a free labeled dataset
// ============================================================
//
// Every ack the agent sends is a label on the balcony's own output. A
// "disagree" or "not-applicable" says "this concern was wrong here";
// "intentional"/"addressing" says "right, and I own it". Aggregated per concern,
// this tells us — deterministically, no model — which tripwire thresholds
// over-fire and deserve a higher bar. The cheap loop generating the data to
// improve the cheap loop.
//
// Stats are global (the tripwire thresholds in evaluateTripWire are global), so
// patterns aggregate across every workspace.

const Set<String> _falsePositiveAcks = {'disagree', 'not-applicable'};
const int _minSampleForAdvice = 5;
const double _noisyThreshold = 0.6;

File _statsFile() {
  final scriptDir = PiperTTS.getScriptDir();
  final logsDir = Directory(path.join(scriptDir, 'workspace_logs'));
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  return File(path.join(logsDir.path, 'concern_stats.json'));
}

Future<Map<String, dynamic>> _readStats() async {
  try {
    final f = _statsFile();
    if (!await f.exists()) return {};
    final c = await f.readAsString();
    if (c.trim().isEmpty) return {};
    return jsonDecode(c) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('Error reading concern stats: $e');
    return {};
  }
}

// Tally one ack against its concern.
Future<void> recordAckStat(String concernId, String ack) async {
  if (concernId.isEmpty || ack.isEmpty) return;
  try {
    final stats = await _readStats();
    final entry = (stats[concernId] is Map)
        ? (stats[concernId] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    entry[ack] = ((entry[ack] as int?) ?? 0) + 1;
    stats[concernId] = entry;
    await _statsFile().writeAsString(jsonEncode(stats));
  } catch (e) {
    stderr.writeln('Error recording ack stat: $e');
  }
}

// Per-concern calibration: total acks, false positives, and the false-positive
// rate, noisiest first. Pure arithmetic over the ack history.
Future<List<Map<String, dynamic>>> calibrationReport() async {
  final stats = await _readStats();
  final out = <Map<String, dynamic>>[];
  stats.forEach((concern, raw) {
    if (raw is! Map) return;
    final counts = raw.cast<String, dynamic>();
    var total = 0, fp = 0;
    counts.forEach((ack, n) {
      final c = (n as int?) ?? 0;
      total += c;
      if (_falsePositiveAcks.contains(ack)) fp += c;
    });
    if (total == 0) return;
    out.add({
      'concern': concern,
      'total': total,
      'falsePositives': fp,
      'fpRate': fp / total,
      'counts': counts,
    });
  });
  out.sort((a, b) => (b['fpRate'] as double).compareTo(a['fpRate'] as double));
  return out;
}

// Concerns whose false-positive rate is high over a meaningful sample — the
// tripwire fires them too eagerly and their bar should be raised. ADVISORY: we
// surface this to the human/agent rather than auto-muting, because silencing a
// genuine concern is worse than an occasional false positive. Auto-tuning is the
// natural follow-on once these numbers are trusted.
Future<List<Map<String, dynamic>>> noisyConcerns() async {
  final report = await calibrationReport();
  return report
      .where(
        (r) =>
            (r['total'] as int) >= _minSampleForAdvice &&
            (r['fpRate'] as double) >= _noisyThreshold,
      )
      .toList();
}
