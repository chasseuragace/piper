# Session Resume — piper / balcony

Handoff for the next session. Branch: **`improve-speak-tool-affordance`** (well ahead of `main`; not yet merged/pushed).

> ⚠️ The MCP server must be **reloaded** (`/mcp` reconnect) to pick up committed changes. The running server can lag the source. Ledgers live in `workspace_logs/` (gitignored runtime state).

---

## What this project is

Piper is a TTS layer for coding agents whose real purpose is **speech as an external reasoning channel**, not narration. On top of that sits the **balcony**: a deterministic, zero-token observer that compares what the agent *says* (narration via the `speak` tool) against **git ground truth** and flags divergence — in a Skyrim-persona voice when it's serious.

Core thesis driving every decision: **draw a hard line between the deterministic core you control (git, ledgers, gates, validation) and the cognitive edge you cultivate (prompts, schemas, model choice).** Make the core correct without the model; scope the (dumb, non-deterministic, cheap) LLM to the irreducible remainder. Systems here aren't "correct," they're *robust-and-improving*.

Model tiers in play: on-device (free, dumbest), Groq free (smarter, rate-limited), frontier (smart, costly). The agent being observed is usually smarter than either observer — so push understanding *up* to the agent and keep observers deterministic.

---

## The speak loop (piper_mcp_server.dart `_handleCallTool`)

1. sanitize + log the agent utterance; enqueue speech (serialized, never overlaps)
2. detect voice switch
3. **observe** workspace — `observeWorkspace` (git ground truth, zero tokens)
4. **agent feedback** — record any `feedback` ack, then suppress acked concerns (deterministic)
5. co-change refine + ack-suppress → `liveConcerns`
6. **tripwire** (`evaluateTripWire`) → cheap deterministic concerns
7. **gate** (`evaluateGate`, stateful novelty/debounce; on-device LLM for the ambiguous middle)
8. **judge** (`judgeWorkspace`, only when gated) → 3 passes: diagnose (cloud) → route lens (local) → compose spoken line (local); high severity speaks through the queue
9. return `{ observation, gate, prescore, concerns, suppressed?, calibration?, judgements }`

## Layout

Entry points stay at repo root (external MCP configs + `speak.sh` reference them by path; `getScriptDir()` resolves assets relative to the running entry point): `piper_tts.dart`, `piper_mcp_server.dart` (stdio), `piper_http_mcp_server.dart` (http). `report_calibration.dart` also stays at root (reads root `workspace_logs/`). Library code lives under `src/` (concern-grouped); tests under `test/`.

## Module map (all re-exported via `src/feedback/piper_feedback_engine.dart` barrel)

- `src/observation/piper_balcony.dart` — observeWorkspace, evaluateTripWire, **prescoreSeverity**, judgeWorkspace + 3 judge passes
- `src/observation/piper_trip_ledger.dart` — stateful gate, fingerprint/debounce, **ack ledger** (recordAck/suppressedConcerns/standingAcks/forgetWorkspaceLedger)
- `src/observation/piper_cochange.dart` — **co-change coupling** (parseCoChange/changeIsCoupled/couplingMap)
- `src/feedback/piper_calibration.dart` — **ack-stream calibration** (recordAckStat/calibrationReport/noisyConcerns)
- `src/feedback/piper_feedback.dart` — generateRealFeedback / generatePseudoFeedback (transition nudges, fast cue)
- `src/persona/piper_personas.dart`, `src/core/piper_persistence.dart`, `src/llm/piper_ai_client.dart`, `src/llm/piper_local_llm.dart`

---

## What this session shipped (commits, newest last)

- `88718ac` rebalance speak-tool copy — firm default, **no coercion** (load-at-start, speaking is default, silence is the exception to justify; dropped the "you are incompetent" framing)
- `1738001` creatives: `creatives/blog.md` + `creatives/linkedinpost.md` (the balcony pattern essay)
- `e0dfa3f` **Phase 1** — close the second loop: `feedback {re, ack, why}` param; ack ledger; deterministic suppression of acked concerns; escalation breaks through
- `b1700f5` **Phase 2** — ack-aware judge: standingAcks fed into `_diagnose` so the voice-switch path also respects settled intent
- `300c975` fix — empty-obs guard (clean tree never reaches the judge) + tighten `carriesFact`
- `175713e` harden `feedback.re` matching (eval round 2): "copy id verbatim" wording + lowercase/trim normalize
- `66ba6f6` fix — undercount: `git status -uall` (untracked dirs were counted as 1 file)
- `3558469` **Tier 3** — self-calibration from the ack stream (disagree/not-applicable = labeled false positives → noisyConcerns); `report_calibration.dart`
- `40b782b` **Tier 1.2** — `scattered` = dispersion (modules-per-file ≥ 0.6, ≥4 files), not raw module count; **prescoreSeverity** anchors the judge
- `ff5f31a` **co-change coupling** — refine `scattered` with git-history coupling (cross-pollination from `the_mcp` activity-intelligence; mines ALL authors, cached, consulted only when scattered fires)

Tests (maintained, deterministic): `test/test_phase1_feedback.dart` (17/17), `test/test_calibration.dart` (5/5), `test/test_cochange.dart` (7/7). Run: `dart run test/test_<x>.dart`. Analyze: `dart analyze .`. (`test/test_compaction.dart` + `test/test_normalization.dart` are LLM-endpoint integration tests — model-dependent, not part of the deterministic suite.)

---

## The `feedback` schema (chosen by eval, not taste)

```
feedback: { re: "<concern id, copy verbatim from prior return's `concerns`>",
            ack: "intentional" | "addressing" | "not-applicable" | "disagree",
            why: "<short>" }
```
Eval findings: weak (Haiku-tier) agents populate it correctly **unprompted** when the field describes it; all four `ack` values are discriminable; `re` matches reliably **only** when the return includes `concerns` AND the field says "verbatim" (1/8 → 5/5). Concern ids are canonical lowercase-kebab from the tripwire: `missing-tests, sprawl, large-churn, scattered, lens-streak`.

---

## Roadmap (open)

1. **Tier 2** — gate the judge harder (only fire when determinism is genuinely uncertain; the `prescore` can short-circuit clear cases) + a deterministic **"spinning" signal** (narration with zero churn over N turns).
2. **Auto-tuning** — once calibration numbers are trusted, let a noisy concern's threshold raise itself (deterministic; the labeled ack data already exists).
3. **Per-repo adaptive thresholds** — learn what "large churn" means for *this* repo from its commit-magnitude history (activity-intelligence already computes this).
4. **Cross-project consolidation** — there are now **three** `git log --numstat` parsers across piper + `the_mcp` (and `the_mcp`'s MCP wrapper duplicates its own engine). If these keep cross-pollinating, factor a shared **`git-ground-truth` Dart package** (pure Dart, no deps). Not urgent; named so it doesn't rot.

## Related project (context, not in this repo)

`/Users/ajaydahal/v4/the_mcp/src` — **activity-intelligence**: the balcony's mirror image. Same deterministic-git DNA but *past-tense/descriptive* (multi-repo activity reports: rhythm, hotspots, churn ratio, co-change, commit magnitude) where the balcony is *present-tense/judgmental*. Honest critiques noted: its "consciousness" layer is narrative dressing over a genuinely good engine; its MCP wrapper reimplements (and has drifted from) its own core engine.

## Guiding philosophy agreed this session

The binding limit is **not the model's IQ** — it's how much of "what matters" you can express deterministically (set by your understanding, not your GPU). Most practical value is front-loaded and cheap; the asymptotic tail is human territory. Scarcity *generated* this architecture rather than just taxing it. The understanding is the appreciating asset; the tool depreciates. Keep the bedrock deterministic; treat schemas as prompts to be tuned by eval, not specified.
