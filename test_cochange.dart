import 'piper_cochange.dart';

// Deterministic checks for co-change coupling: parsing git-log numstat into a
// coupling graph, and deciding whether a change is coherent coupling vs scatter.
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

  // a appears in h1,h2,h3; b in h1,h2; c only in h3.
  // a&b share 2 commits (>=2, ratio 1.0) -> coupled. c is not frequent.
  const log = '@@@h1\n'
      '1\t0\ta.dart\n'
      '1\t0\tb.dart\n'
      '@@@h2\n'
      '2\t1\ta.dart\n'
      '0\t1\tb.dart\n'
      '@@@h3\n'
      '1\t0\ta.dart\n'
      '1\t0\tc.dart\n';

  final adj = parseCoChange(log);
  check('a and b are coupled', adj['a.dart']?.contains('b.dart') == true);
  check('coupling is symmetric', adj['b.dart']?.contains('a.dart') == true);
  check('c is not coupled (single commit)', !(adj.containsKey('c.dart')));

  check('changed coupled files -> coherent (not scatter)', changeIsCoupled(['a.dart', 'b.dart'], adj));
  check('changed uncoupled files -> scatter stands', !changeIsCoupled(['a.dart', 'c.dart'], adj));
  check('single file -> not coupled', !changeIsCoupled(['a.dart'], adj));
  check('empty coupling map -> not coupled', !changeIsCoupled(['a.dart', 'b.dart'], {}));

  print('\n$pass passed, $fail failed');
}
