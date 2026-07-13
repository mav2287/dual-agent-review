# Research evidence — why a second-agent review, and how much to trust it

Compiled 2026-07-09 from two independent research passes (a multi-source deep-research
harness with 3-vote adversarial claim verification, and a live Codex web pass on the
same brief), reconciled 2026-07-13 into this document. This is the evidence base for
the design; read it before extending the tool, and especially before claiming more
for it than the data supports.

## What the evidence supports

- **External review beats self-review.** Models systematically fail to catch their
  own errors while catching the same errors readily when presented as someone
  else's. Across 14 models the average "self-correction blind spot" was **64.5%**
  (Self-Correction Bench, arXiv 2507.02778). In a Python 2→3 migration study,
  **31.7%** of semantic-drift bugs were self-endorsed by the model that introduced
  them ("Articulate but Wrong", arXiv 2605.21537). Externalizing the error (showing
  it as another agent's output) lifted correction rates by **23–93 percentage
  points** depending on task family.
- **Reviewer comments get acted on.** OpenAI's scaling-code-verification work found
  reviewer comments acted on 52.7% of the time, and that reviewers with repo tools
  + execution beat diff-only reviewers. CriticGPT-style trained critics were
  preferred over human-only review 63% of the time.
- **A fresh context captures most of the gain.** The measured benefit is attributed
  mainly to CONTEXT SEPARATION (the reviewer doesn't share the author's working
  context and rationalizations), not to vendor identity. A fresh same-vendor
  subagent captures most of the improvement; a different-vendor reviewer adds a
  real but smaller increment. **No study cleanly isolates "different vendor" from
  "different context".**

## Caveats that bound the design (do not quietly drop these)

- **The scary numbers come from non-reasoning models.** Both key papers note that
  RL-trained reasoning models mitigate the self-correction blind spot; for a
  frontier reasoning pair the effect is real but smaller than the headline figures.
- **Diminishing returns arrive fast.** Review F1 plateaus around n=5–10 reviewers;
  large accurate models agree ~60% of the time even when BOTH are wrong (correlated
  errors). More agents ≠ more truth. This is why dar runs ONE adversarial reviewer
  with a deterministic gate behind it, not a jury.
- **Deterministic gates remain the merge authority.** Tests, typecheck, lint,
  migration linters, mutation testing — these are the only external feedback that
  cannot be sweet-talked. `dar verify` exists so the model verdict never substitutes
  for them. Never replace a deterministic gate with an LLM judgment.
- **Distrust vendor efficacy claims.** A marketing claim of "76% resolution /
  nearly doubled issues caught" for an AI review product was REFUTED 0–3 on
  adversarial verification of its sourcing. Treat all blog-post percentages about
  review efficacy as unverified.

## Sources

- Self-Correction Bench — arXiv 2507.02778
- "Articulate but Wrong: self-endorsement of semantic drift" — arXiv 2605.21537
- TACL 2024 self-correction surveys (Kamoi et al.; Pan et al.)
- OpenAI, scaling code verification (reviewer-comment action rates; repo-tools+exec
  vs diff-only reviewers)
- CriticGPT (OpenAI) — 63% preference for critic-assisted review
- openai/codex-plugin-cc — the official Codex ⇄ Claude Code dispatch plugin dar
  integrates with (`/codex:adversarial-review` as the manual deeper pass)
