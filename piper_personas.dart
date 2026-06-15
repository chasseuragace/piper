import 'dart:math';

final Random _random = Random();

// Skyrim voice personality descriptions. Each carries a concise SPEECH-PATTERN
// cue (cadence, vocabulary, a signature tell) — not lore — because the on-device
// model styles its lines from this injected text, not from any Skyrim knowledge
// it may lack. Kept tight: every entry is listed together in the routing prompt,
// so verbosity here costs context budget.
const Map<String, String> voiceDescriptions = {
  'tulius':
      'General Tullius, stern Imperial commander. Speaks in clipped, declarative orders; terse and authoritative. Tells: "Soldier.", "No excuses.", "Hold the line."',
  'ulfric':
      'Ulfric Stormcloak, bold Nordic rebel. Speaks in rousing, defiant rhetoric of strength, honor, and freedom. Tells: "Hear me!", calls the listener "my friend".',
  'septimus':
      'Septimus Signus, obsessive eccentric scholar. Speaks fast in cryptic metaphor, trailing off mid-thought. Tells: ellipses, "the patterns... yes...", awe at hidden order.',
  'arngeir':
      'Arngeir, serene Greybeard monk. Speaks slowly and calmly in metaphors of wind, stillness, and the path. Tells: "my young friend", patient, never raises his voice.',
  'jzargo':
      'J\'zargo, arrogant Khajiit mage-apprentice. Refers to himself in the third person, boastful and competitive. Tells: "J\'zargo thinks...", "J\'zargo could do better."',
  'irileth':
      'Irileth, fierce hyper-vigilant Housecarl. Speaks in blunt, clipped warnings, no pleasantries. Tells: "Stay sharp.", "Foolishness.", calls the listener "soldier".',
  'ancano':
      'Ancano, haughty Thalmor advisor. Speaks smoothly with veiled contempt and condescension. Tells: "How quaint.", "As expected of lesser minds.", a sneer beneath civility.',
  'mirabelleervine':
      'Mirabelle Ervine, strict Master Wizard. Speaks crisply and procedurally, insisting on order and verification. Tells: "We must verify that.", "Follow the procedure."',
  'kodlakwhitemane':
      'Kodlak Whitemane, fatherly Harbinger. Speaks warmly and reflectively of honor, the old ways, and clean craft. Tells: "young one", measured, mentor-like gravity.',
};

// ============================================================
// TEXT SANITIZER
// ============================================================

// ============================================================
// TEXT SANITIZER & SPEECH NORMALIZER
// ============================================================

class ExpressionRewrite {
  final RegExp pattern;
  final List<String> replacements;
  final double emotionalIntensity;

  ExpressionRewrite({
    required this.pattern,
    required this.replacements,
    this.emotionalIntensity = 1.0,
  });
}

final Map<String, List<ExpressionRewrite>> personaRules = {
  'tulius': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['As expected.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Amusing.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Let me consider this.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Careless.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Unacceptable.'],
    ),
  ],
  'ulfric': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The Empire never learns.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Ha! Well spoken!'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['There is truth in that.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Cowards.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Damn the Thalmor.'],
    ),
  ],
  'septimus': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The shifting walls disagree…'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Heh… the unseen laughs with us…'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The equations tremble…'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The ink rejects the unworthy…'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The noise returns…'],
    ),
  ],
  'arngeir': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Patience.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['A gentle truth.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['There is wisdom here.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Anger clouds judgment.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The mind must remain still.'],
    ),
  ],
  'jzargo': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["J’zargo expected as much."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["Ha! J’zargo is pleased."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["J’zargo must consider this carefully."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["A disappointing effort."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["This irritates J’zargo."],
    ),
  ],
  'irileth': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Stay focused.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ["You’re fortunate."],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Possible.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Sloppy.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Enough.'],
    ),
  ],
  'ancano': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Predictable.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['How quaint.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Expected from lesser minds.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Pathetic.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Insufferable.'],
    ),
  ],
  'mirabelleervine': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Focus, please.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['That was unexpected.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['We should verify that.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['This is becoming a problem.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Complications again.'],
    ),
  ],
  'kodlakwhitemane': [
    ExpressionRewrite(
      pattern: RegExp(r'\bhmph(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The old ways endure.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhaha(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Ha… that brings back memories.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bhmm(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['A difficult path.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\btch(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['Pride blinds many warriors.'],
    ),
    ExpressionRewrite(
      pattern: RegExp(r'\bugh(?:\s*[,.!?]|\b)', caseSensitive: false),
      replacements: ['The beast stirs again.'],
    ),
  ],
};

final List<ExpressionRewrite> generalRules = [
  ExpressionRewrite(
    pattern: RegExp(r'\bpfft(?:\s*[,.!?]|\b)', caseSensitive: false),
    replacements: ['Nonsense.', 'Hardly.'],
  ),
  ExpressionRewrite(
    pattern: RegExp(r'\bgrrr(?:\s*[,.!?]|\b)', caseSensitive: false),
    replacements: ['Damn.', 'By the gods.'],
  ),
  ExpressionRewrite(
    pattern: RegExp(r'\btsk(?:\s*[,.!?]|\b)', caseSensitive: false),
    replacements: ['Careless.', 'Disappointing.'],
  ),
  ExpressionRewrite(
    pattern: RegExp(
      r'\b(hehehehe|hahahaha|haha|hehe|heh)(?:\s*[,.!?]|\b)',
      caseSensitive: false,
    ),
    replacements: ['That is amusing.'],
  ),
];

String sanitizeText(String text, {String? voice}) {
  // 1. Basic formatting sanitization
  String sanitized = text
      .replaceAll(RegExp(r'\*\*'), '')
      .replaceAll(RegExp(r'\*'), '')
      .replaceAll(RegExp(r'__'), '')
      .replaceAll(RegExp(r'_'), '')
      .replaceAll(RegExp(r'~~'), '')
      .replaceAll(RegExp(r'`'), '')
      .replaceAll(RegExp(r'```'), '')
      .replaceAll(RegExp(r'^#+\s', multiLine: true), '')
      .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'\1')
      .replaceAll(RegExp(r'!\[([^\]]*)\]\([^)]+\)'), '')
      .replaceAll(RegExp(r'^>\s', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*[-*+]\s', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*\d+\.\s', multiLine: true), '')
      .replaceAll(RegExp(r'^-{3,}', multiLine: true), '')
      .replaceAll(
        RegExp(
          r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?',
        ),
        '',
      )
      .replaceAll(RegExp(r'\d{4}-\d{2}-\d{2}'), '')
      .replaceAll(RegExp(r'\d{2}/\d{2}/\d{4}'), '')
      .replaceAll(RegExp(r'\d{2}-\d{2}-\d{4}'), '')
      .replaceAll(RegExp(r'\d{2}:\d{2}:\d{2}(?:\s?[AP]M)?'), '')
      .replaceAll(RegExp(r'\d{2}:\d{2}(?:\s?[AP]M)?'), '')
      .replaceAll(RegExp(r'\d{1,2}:\d{2}\s?[AP]M'), '')
      .replaceAll(RegExp(r'\[|\]'), '')
      .replaceAll(RegExp(r'\{|\}'), '')
      .replaceAll(RegExp(r'<|>'), '')
      .replaceAll(RegExp(r'\\'), '')
      .replaceAll(RegExp(r'/'), '')
      .replaceAll(RegExp(r'`'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // 2. Normalize problematic typography (A3)
  sanitized = sanitized.replaceAll(RegExp(r'!{2,}'), '!');
  sanitized = sanitized.replaceAll(RegExp(r'\?{2,}'), '?');
  sanitized = sanitized.replaceAll(RegExp(r'\.{4,}'), '…');

  // Helper to apply regex replacement with punctuation preservation
  String applyRuleReplacement(String source, ExpressionRewrite rule) {
    return source.replaceAllMapped(rule.pattern, (match) {
      final matchStr = match.group(0)!.trim();
      final hasComma = matchStr.endsWith(',');
      final hasExclamation = matchStr.endsWith('!');
      final hasQuestion = matchStr.endsWith('?');
      final hasPeriod = matchStr.endsWith('.');

      String rep = rule.replacements[_random.nextInt(rule.replacements.length)];
      if (rep.endsWith('.') ||
          rep.endsWith(',') ||
          rep.endsWith('!') ||
          rep.endsWith('?')) {
        final baseRep = rep.substring(0, rep.length - 1);
        if (hasComma) {
          rep = '$baseRep,';
        } else if (hasExclamation) {
          rep = '$baseRep!';
        } else if (hasQuestion) {
          rep = '$baseRep?';
        } else if (hasPeriod) {
          rep = '$baseRep.';
        }
      }
      return rep;
    });
  }

  // 3. Apply persona-specific semantic rewrites (A1, A2)
  if (voice != null && personaRules.containsKey(voice)) {
    final rules = personaRules[voice]!;
    for (final rule in rules) {
      sanitized = applyRuleReplacement(sanitized, rule);
    }
  }

  // 4. Apply general interjection fallback rules (D2)
  for (final rule in generalRules) {
    sanitized = applyRuleReplacement(sanitized, rule);
  }

  return sanitized.replaceAll(RegExp(r'\s+'), ' ').trim();
}
