import '../src/feedback/piper_feedback_engine.dart';

void main() {
  print('=== Running Persona Speech Normalization Tests ===');

  final testCases = {
    'tulius': {
      'Hmph. We must defend the province.': 'As expected. We must defend the province.',
      'Haha, the rebels think they can win.': 'Amusing, the rebels think they can win.',
      'Hmm. Let me look at the map.': 'Let me consider this. Let me look at the map.',
      'Tch! You are careless.': 'Careless! You are careless.',
      'Ugh. The cold is unbearable.': 'Unacceptable. The cold is unbearable.',
      'Ah, the legion has arrived.': 'I see, the legion has arrived.',
    },
    'arngeir': {
      'Hmph, the Greybeards wait.': 'Patience, the Greybeards wait.',
      'Haha, a fine question.': 'A gentle truth, a fine question.',
      'Hmm, the way of the voice is long.': 'There is wisdom here, the way of the voice is long.',
      'Tch, do not be angry.': 'Anger clouds judgment, do not be angry.',
      'Ugh, do not speak so loud.': 'The mind must remain still, do not speak so loud.',
      'Ah, you hear it.': 'You begin to understand, you hear it.',
    },
    'jzargo': {
      'Hmph, J\'zargo will try.': 'J’zargo expected as much, J\'zargo will try.',
      'Haha, J\'zargo knows many things.': 'Ha! J’zargo is pleased, J\'zargo knows many things.',
      'Hmm, how does this work?': 'J’zargo must consider this carefully, how does this work?',
      'Tch, this is too slow.': 'A disappointing effort, this is too slow.',
      'Ugh, this is boring.': 'This irritates J’zargo, this is boring.',
      'Ah, J\'zargo sees it.': 'Ah, now J’zargo understands, J\'zargo sees it.',
    }
  };

  int passed = 0;
  int total = 0;

  testCases.forEach((voice, cases) {
    print('\nTesting voice: $voice');
    cases.forEach((raw, expected) {
      total++;
      final result = sanitizeText(raw, voice: voice);
      if (result == expected) {
        print('✅ PASS: "$raw" -> "$result"');
        passed++;
      } else {
        print('❌ FAIL: "$raw"\n  Expected: "$expected"\n  Got:      "$result"');
      }
    });
  });

  print('\n=== Typography Normalization Tests ===');
  final typoCases = {
    'Hello!!!': 'Hello!',
    'What???': 'What?',
    'This is..... amazing': 'This is… amazing',
  };

  typoCases.forEach((raw, expected) {
    total++;
    final result = sanitizeText(raw);
    if (result == expected) {
      print('✅ PASS: "$raw" -> "$result"');
      passed++;
    } else {
      print('❌ FAIL: "$raw"\n  Expected: "$expected"\n  Got:      "$result"');
    }
  });

  print('\n=== General Rules Fallback Tests ===');
  final generalTestCases = {
    'Pfft, that is not a problem.': ['Nonsense, that is not a problem.', 'Hardly, that is not a problem.'],
    'Grrr, don\'t worry.': ['Damn, don\'t worry.', 'By the gods, don\'t worry.'],
    'Tsk! We will fix it.': ['Careless! We will fix it.', 'Disappointing! We will fix it.'],
  };

  generalTestCases.forEach((raw, expectedList) {
    total++;
    final result = sanitizeText(raw);
    if (expectedList.contains(result)) {
      print('✅ PASS: "$raw" -> "$result" (matches expected variant)');
      passed++;
    } else {
      print('❌ FAIL: "$raw"\n  Expected one of: $expectedList\n  Got:             "$result"');
    }
  });

  print('\nResults: $passed / $total passed.');
  if (passed == total) {
    print('🎉 Perfect! All speech normalization assertions passed!');
  } else {
    print('🚨 Normalization failures detected!');
  }
}
