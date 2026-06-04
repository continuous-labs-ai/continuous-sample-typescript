# continuous-sample-typescript

A realistic sample agent that ships on [Continuous](https://continuouslabs.ai) —
CI/CD for AI agents. It's a **customer-support agent for "Acme"**, a fictional
SaaS company, built on the **Anthropic Claude Agent SDK** and served through the
**Continuous TypeScript Worker SDK**.

The point of the sample: the thing you ship is not a model, it's a full
**`model × prompt × skill`** composition — a *variant*. Continuous runs each
variant against an eval set in CI and ramps the winner into production with a
staged CD rollout.

> A Python twin of this repo lives at **continuous-sample-python** — same
> scenario, same variants, mirror-image SDK.

## The variants

Each variant is a directory under [`agent/variants/`](agent/variants), declared
in [`.continuous/config.yml`](.continuous/config.yml). They differ on exactly
one axis at a time, so the eval scores tell a clean story:

| Variant | Model | Prompt | Skill | Role |
| ------- | ----- | ------ | ----- | ---- |
| **v1** | Haiku 4.5 | terse, generic | — | weak baseline |
| **v2** | Sonnet 4.6 | policy-aware, empathetic | — | **CD candidate** (v1 → v2) |
| **v3** | Sonnet 4.6 | same as v2 | **`billing-policy`** | **CI candidate** (the PR) |

Acme's real refund/proration/trial rules are proprietary — the model can't guess
them. So v1 and v2 confidently invent plausible-but-wrong specifics (a
"30-day refund" when the real window is 14 days), while **v3** reads the
[`billing-policy` skill](https://github.com/continuous-labs-ai/continuous-sample-typescript/blob/add-v3-billing-skill/.claude/skills/billing-policy/SKILL.md) and gets the
exact terms right. The eval set ([`evals/support.jsonl`](evals/support.jsonl),
scored by [`evals/support-judge.md`](evals/support-judge.md)) is built so **v1 < v2 < v3**.

## How it works

[`src/worker.ts`](src/worker.ts) is the whole integration:

```ts
const worker = new ManagedAgentWorker({ agent: "support-agent", agentFactory });
startWorkersForVariants(worker, ["v1", "v2"]); // one poll loop per variant
```

The factory reads `task.variant`, composes that variant's
`model × prompt × skill` into the Agent SDK `Options`, runs the Claude Agent SDK,
and returns the trajectory. Continuous judges it server-side against
`evals/support-judge.md`.

## Setup

```bash
# 1. Install the Continuous CLI (Go) and log in.
continuous login

# 2. Install dependencies.
npm install

# 3. Two keys in the environment:
export CONTINUOUS_API_KEY=ck_...        # worker key — minted in the dashboard (Admin → Worker API keys)
export CONTINUOUS_API_URL=https://api.continuouslabs.ai   # or your dev stack
export ANTHROPIC_API_KEY=sk-ant-...     # the Claude Agent SDK calls Anthropic
```

> The Claude Agent SDK bundles and spawns a native Claude Code engine as a
> subprocess, so each worker needs `ANTHROPIC_API_KEY` and the ability to spawn
> a child process. The Continuous SDK itself is a thin HTTP client.

Run the worker from the repo root (the Agent SDK resolves `.claude/skills`
relative to it):

```bash
npm run worker
```

---

## Demos

The full runbook + validation guide — prerequisites, the cast (v1/v2/v3), and the
five flows packaged as `just` recipes (`just --list`) — lives in
**[VALIDATION.md](VALIDATION.md)**:

- **A — Eval:** score every variant locally with `just eval` (no PR).
- **B — CI:** open the pre-staged `add-v3-billing-skill` PR (`just pr`); pick which
  eval cells to dispatch from the PR comment (on-demand + auto); scores gate the merge.
- **C — Rollout:** `just rollout` — ramp v1 → v2 with live canary traffic.
- **D — Experiment:** `just experiment` — A/B v1 vs v2 on a live traffic slice.
- **E — Shadow:** `just shadow` — replay sampled traffic through the candidate, out of band.

## Layout

```
.continuous/config.yml        # agent + variants + the eval
.continuous/rollouts.yml      # CD ramp plans
agent/variants/v{1,2}/        # one model × prompt × skill composition each (main)
evals/support.jsonl           # primary eval dataset: {name, input, expected_output}
evals/support-judge.md                # support rubric: did the agent take the correct action? (binary)
evals/escalation.jsonl        # second, non-blocking eval: escalate-vs-handle scenarios
evals/escalation-judge.md     # escalation rubric: did the agent escalate correctly? (binary)
src/                          # the worker (CI) + simulator (CD)
#
# On the pre-staged add-v3-billing-skill branch (the CI demo):
#   agent/variants/v3/             # v2 + the billing-policy skill
#   .claude/skills/billing-policy/ # the proprietary policy v3 reads (an Agent Skill)
```

## Notes

- The Continuous SDKs aren't on npm yet, so [`package.json`](package.json)
  resolves `@continuous/sdk` from the monorepo via a relative `file:` path
  (`../continuous/sdk/typescript`) — clone this repo next to the `continuous`
  monorepo. Once published this becomes a plain `@continuous/sdk` dependency.
- Pin `@anthropic-ai/claude-agent-sdk` — its 0.x API moves between minor
  versions.
