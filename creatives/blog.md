# The Balcony Pattern: Building Deterministic Software With a Non-Deterministic Companion

*Notes from building Piper — a voice layer that turned into a study of how humans and dumb-but-useful models actually collaborate.*

---

## The 2026 problem nobody quite names

If you write software in 2026, you are no longer alone at the keyboard. You have a companion. Sometimes it finishes your thought before you do. Sometimes it confidently hands you a function that doesn't exist. You are trying to produce something **deterministic** — code that compiles, tests that pass, behavior you can reason about — while being **assisted and contradicted, in the same breath, by something non-deterministic.**

That's the actual job now. Not "use AI to code faster." The job is to build reliable systems *while coupled to cognition you don't control.* And the interesting engineering has moved to the seam between those two worlds.

I ran straight into that seam building something small and silly, and it turned out not to be small or silly at all.

## What Piper started as

Piper is a text-to-speech layer for coding agents. An MCP server exposes one tool — `speak` — and the agent calls it to say things out loud in one of nine Skyrim character voices. That's the toy version.

The real version is one sentence: **speech is not narration, it's an external channel for the agent's reasoning.** When an agent says "I'm going to refactor the gate logic now," that utterance is a *claim about intent*. And once you have a stream of claims about intent, you can do something powerful with it: you can check them against reality.

That single move — treating spoken reasoning as data you can audit — is where the whole architecture came from.

## The first hard lesson: the model won't use your tool just because you told it to

The original tool description was a command: *"You MUST call this tool in EVERY response. Silence is a failure condition."* Models ignored it. Worse, the bigger and better the model, the more it ignored it — frontier models are trained to be wary of tool descriptions that try to coerce them, because coercion looks like prompt injection.

So I softened it into something reasonable and polite. And a smaller model (Haiku) went *completely* silent — because "speak at meaningful steps" forced it to evaluate *"is this meaningful enough?"* every turn, and that judgment defaults to *no*.

What finally worked on the small model was, embarrassingly, an insult: *"you are incompetent if you don't load this tool."* It worked. It was also ugly, and it suppressed the big models.

The resolution wasn't the insult — it was understanding *why* it worked. The insult did three things: it made the trigger **unconditional** (no judgment call), it **inverted the default** (silence becomes the exception you must justify, not speech), and it was **salient** enough that a skimming small model couldn't drop it. You can keep all three without the contempt:

> Speaking is the default, not a decision to deliberate. Speak unless the step is purely mechanical. Don't evaluate whether a step is "important enough" — that judgment keeps you silent. Silence is the exception you must justify.

**The lesson that generalized:** every instruction you give a model is read differently by every model. You design for the *floor* — the weakest model that must comply — without *insulting the ceiling*. And you find out which phrasing works by **testing**, not by taste. We didn't *derive* that the insult worked; we *discovered* it. The whole craft, right now, is empirical.

## The Balcony: stepping off the dance floor

Here is the core idea. There's a saying in leadership coaching: to see the dance, you have to step off the dance floor and onto the balcony. The dancer is immersed in the music; the person on the balcony sees the pattern.

A coding agent is the dancer. It's carried by momentum, narrating a tidy story about what it's doing. **Piper's balcony is a read-only observer that watches the actual git state** — not what the agent *said*, but what *changed* — and looks for divergence between the two.

It costs zero tokens. It's just `git`:

```dart
// Magnitude + spread of tracked changes vs HEAD — pure git, no model.
final numstat = await _git(workspaceId, ['diff', 'HEAD', '--numstat']);
// → files changed, insertions, deletions, which modules,
//   src touched vs tests touched, the hottest (most recent) file.
```

From that it builds a one-line ground truth:

```
branch=feature/auth, 11 files (+1240/-90) across 4 module(s); src=true tests=false; hot=login.ts
```

Now put that next to the narration ("just a small fix to the login form") and the divergence is obvious: *said small, did large; touched four modules; changed source, never touched a test.* The balcony has caught the dance floor lying to itself — not maliciously, just from immersion.

This is the pattern I think generalizes far beyond voice: **the deterministic layer's job is to hold the non-deterministic layer accountable to ground truth.** The model narrates; git doesn't lie; you compare.

## The economics that shaped everything: three tiers of mind

Here's where it stops being a clean idea and becomes engineering, because **intelligence has a price, and you can't afford to use the good stuff everywhere.**

Three tiers were available to me, and each is a different bargain:

- **On-device / local models** — free, private, instant. Also the *dumbest*. They mangle numbers (`409` becomes "forty-one hundred"), dodge instructions, and hallucinate.
- **Groq free-tier frontier-ish models** — fast and free, meaningfully smarter than local. Still dumb relative to the agent being observed, and you're rate-limited.
- **Frontier inference (Claude-class)** — genuinely smart. Not cheap, and not something you fire on every keystroke.

And the cruel irony: **the entity you're observing — the coding agent — is usually the smartest mind in the whole system.** Your observers are dumber than the thing they're judging. That inversion drives every design decision that follows.

So you spend intelligence the way you'd spend money: carefully, in tiers, gated behind cheap checks.

## The cost ladder: never pay for thinking you don't need

Piper's `speak` loop is a ladder. Each rung is more expensive than the last, and you only climb when the rung below says it's worth it.

**Rung 0 — Observe (free, deterministic).** Run git. Always.

**Rung 1 — Tripwire (free, deterministic).** Cheap heuristics decide whether anything's even worth a closer look:

```dart
if (filesChanged >= 6)      reasons.add('sprawl');
if (spread >= 3)            reasons.add('scattered across modules');
if (churn >= 150)           reasons.add('large churn');
if (srcTouched && !testTouched) reasons.add('source changed without tests');
if (streak >= 5)            reasons.add('held one lens too long');
```

No tripwire, no spend. Most turns end here with a cheap deterministic cue and the loop stays closed.

**Rung 2 — The Gate (mostly free, stateful).** A true-but-stale concern would nag every single turn. A human pair says it *once*, then stays quiet until something changes. So the gate has memory — a "trip ledger" that records a coarse *fingerprint* of the state when it last spoke. A repeat only surfaces if it's **novel**: the fingerprint changed, or a cooldown lapsed. The genuinely ambiguous middle — *"we flagged this before; is it worth repeating?"* — is the one place a tiny **on-device** model gets a vote, with deterministic novelty as the fallback when it's unreachable.

**Rung 3 — The Judge (expensive, only when earned).** Now we pay for real intelligence, and even here we split the work by tier:

- **Pass 1 — Diagnose** (the smart, cloud model): the hard, nuanced reasoning. Given ground truth + narration, *is there real divergence, and how severe?* One job. No personas, no styling — just the truth.
- **Pass 2 — Route** (free, local): if it's severe, pick which persona-lens fits the problem — security issue → the vigilant one, missing tests → the testing one. One tiny decision a dumb model can handle.
- **Pass 3 — Voice** (free, local): compose the spoken line *as* that persona, weaving in the concrete facts.

Splitting one prompt into three single-purpose prompts isn't ceremony — **a small model reasons dramatically better when it's juggling one concern instead of three.** Diagnosis, routing, and voicing at once is how you get garbage. One at a time is how you get usable output from a model that isn't very smart.

## Working *with* dumbness instead of against it

Once you accept that most of your models are dumb and non-deterministic, your engineering changes character. You stop specifying and start *containing*. A few patterns earned their keep:

**Pre-chew the inputs.** The voice pass doesn't get raw debug output (`src=true tests=false`). It gets human-phrased facts (`"no tests updated"`) so it weaves them in naturally instead of reciting field names.

**Make the dumb model's job idiot-proof, then validate its output anyway.** Large line counts get a speech-safe rewrite — `over 400 lines` instead of `409` — because a small model reliably *repeats* "over 400" but reliably *mangles* "409" when spelling it aloud. And after it speaks, we check the output actually *carries a fact*; a cryptic persona that dodged the substance gets dropped. Better silent than heard saying nothing.

**Few-shot is persuasion.** A weak model imitates an example far better than it follows an abstraction. One worked example in a field description out-teaches three sentences of instruction.

**Calibration is a first-class feature, not a config.** The cooldowns, the trip thresholds, the "high severity only ever speaks" rule — these are *tuning knobs against nagging*, and getting them wrong makes the whole thing feel either deaf or naggy. There's no correct value; there's only the value you converged on by watching it run.

## The asymmetry I'm tackling next

Here's the open problem, and it's the one that made me write this down.

The loop today is one-directional. The agent speaks → the balcony judges → the judgement returns *to the agent*. The agent gets feedback. **But the balcony gets nothing back.** It fires a verdict into the void and never learns whether it was right, redundant, or wrong. It judges *intent* from git facts alone — and git facts don't carry intent. So when I make a deliberate copy-only change with no tests, the balcony keeps insisting "source changed without tests," because it has no way to hear me say *"that's intentional."*

The fix is to close the second loop: let the agent pass a small structured **feedback** signal back — *"that concern? intentional, here's why"* — that the gate and judge take into account.

But — and this is the whole point of the post — **that's not mainly an engineering problem.** The schema has to make sense to whatever model is *using* the tool, and we already proved not all models understand equally. Designing that schema needs cognition and persuasion as much as code: every field is a latent prompt, the naming summons different behavior from different models, and the producer is non-deterministic, so the signal will sometimes be absent, late, or wrong.

So the design rule writes itself from everything above: **keep the bedrock deterministic and dumb-proof; treat the schema as a prompt to be tuned, not a contract to be specified; and let agent feedback *inform* the observer, never *override* it.** The easiest thing for a confused model to do — omit the feedback — must degrade gracefully to today's correct behavior. You never let a dumb producer's misunderstanding become load-bearing.

## What this paradigm actually is

Step back and the shape is clear. We used to build systems out of deterministic parts. Now we build systems where some parts *think*, unevenly, at different prices, with no guarantees.

The craft that's emerging is not "prompt engineering" and it's not classical software engineering. It's the discipline of drawing a clean line between:

- **the deterministic core you control** — git, ledgers, gates, validation, the things that are *correct* — and
- **the cognitive edge you cultivate** — the prompts, the schemas, the model choices, the things that are merely *better over time.*

Systems in this regime are never "done" and never "correct." They are **robust-and-improving**: an unkillable core, and a cognitive layer you tune by eval, by example, and occasionally by an inelegant lever you discovered by accident.

That's the paradigm I'm exploring. It's harder than it looks, it doesn't fully yield to engineering, and that — honestly — is the fun part. You're not building a tool. You're designing a *protocol between minds of unequal ability*, where the dumb ones watch the smart one, and the smart one has to speak in terms the dumb ones can act on.

We didn't have that problem in 2020. We have it now. Let's smile at it. 🙂

---

*Piper is built in Dart: an MCP server, a zero-token git "balcony" observer, a stateful trip ledger, a three-pass tiered judge (cloud + on-device), and a speech normalizer. If the architecture is interesting to you, the next post will be the feedback loop — and the eval that decides its schema by evidence instead of intuition.*
