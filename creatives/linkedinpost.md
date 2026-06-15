# LinkedIn Post

I'm exploring a new paradigm of AI engineering, and I want to name the problem I think most of us are quietly living in 2026:

**We're trying to build deterministic software while being assisted — and contradicted — by non-deterministic companions.**

Not "use AI to code faster." Something stranger. You're writing code that has to compile, pass, and behave predictably — while coupled to a mind you don't control, that finishes your sentences *and* confidently hands you functions that don't exist. The real engineering has moved to the seam between those two worlds.

I've been building Piper — a voice layer for coding agents that turned into a study of how humans and dumb-but-useful models actually collaborate. A few things I learned the hard way:

🎙️ **An agent's spoken reasoning is data you can audit.** When the agent says "just a small fix," you can check that claim against `git`. Said small, changed 11 files across 4 modules, never touched a test? Your deterministic layer just caught the AI's story diverging from reality — for zero tokens. I call it "the balcony": step off the dance floor, see the pattern.

💸 **Intelligence has a price, so you spend it in tiers.** On-device models: free, private, *dumb* (they'll read "409" as "forty-one hundred"). Groq free tier: smarter, rate-limited. Frontier (Claude-class): genuinely smart, not cheap. You gate the expensive thinking behind cheap deterministic checks and only climb the cost ladder when a free rung says it's worth it.

🤔 **The model you're observing is usually the smartest mind in the system.** Your observers are dumber than the thing they're judging. That inversion changes everything: you push the hard reasoning *up* to the smart agent and keep the dumb observers deterministic.

🧪 **You don't specify behavior anymore — you cultivate it.** The same instruction lands differently on every model. A polite nudge left a small model silent; a blunt one moved it (an *insult* literally worked — inelegant, but it worked). The lesson wasn't "be rude." It was: design for the weakest model without insulting the strongest, and find out what works by **eval, not taste.**

The pattern underneath all of it: draw a hard line between **the deterministic core you control** (git, gates, validation) and **the cognitive edge you cultivate** (prompts, schemas, model choice). Systems in this regime are never "correct." They're **robust-and-improving** — an unkillable core, and a thinking layer you tune over time.

This isn't prompt engineering and it isn't classic software engineering. It's designing a *protocol between minds of unequal ability.*

We didn't have this problem a few years ago. We have it now. Honestly? It's the most fun I've had building in a long time. 🙂

Full write-up in the comments. Curious how others are drawing that deterministic/cognitive line in your own stacks.

#AIEngineering #LLM #SoftwareEngineering #DeveloperTools #AIAgents #MCP #BuildingInPublic
