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
[`billing-policy` skill](.claude/skills/billing-policy/SKILL.md) and gets the
exact terms right. The eval set ([`evals/support.jsonl`](evals/support.jsonl),
scored by [`evals/judge.md`](evals/judge.md)) is built so **v1 < v2 < v3**.

## How it works

[`src/worker.ts`](src/worker.ts) is the whole integration:

```ts
const worker = new ManagedAgentWorker({ agent: "support-agent", agentFactory });
startWorkersForVariants(worker, ["v1", "v2"]); // one poll loop per variant
```

The factory reads `task.variant`, composes that variant's
`model × prompt × skill` into the Agent SDK `Options`, runs the Claude Agent SDK,
and returns the trajectory. Continuous judges it server-side against
`evals/judge.md`.

## Setup

```bash
# 1. Install the Continuous CLI (Go) and log in.
continuous login

# 2. Install dependencies.
npm install

# 3. Two keys in the environment:
export CONTINUOUS_API_KEY=ck_...        # Continuous (from `continuous login`)
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

The full end-to-end runbook — prerequisites (GitHub App, worker key, env), the
on-demand-dispatch CI flow, and the staged CD rollout — lives in
**[DEMO.md](DEMO.md)**:

- **Demo A — Create an eval:** author a dataset + judge + config entry and score
  the agent (`continuous eval billing-support`, no PR required).
- **Demo B — CI:** open the pre-staged `add-v3-billing-skill` PR; pick which eval
  to dispatch from the PR-comment checkbox table; scores gate the merge.
- **Demo C — CD:** roll out v1 → v2 through a `10 → 25 → 50 → 100` ramp and pause
  after 2 of 4 stages.

## Layout

```
.continuous/config.yml        # agent + variants + the eval (the variant catalog)
.continuous/rollouts.yml      # CD ramp plans
.claude/skills/billing-policy/ # the proprietary policy v3 reads (an Agent Skill)
agent/variants/v{1,2,3}/      # one model × prompt × skill composition each
evals/support.jsonl           # eval dataset: {name, input, expected_output}
evals/judge.md                # the rubric Continuous scores against
src/                          # the worker (CI) + simulator (CD)
```

## Notes

- The Continuous SDKs aren't on npm yet, so [`package.json`](package.json)
  resolves `@continuous/sdk` from the monorepo via a relative `file:` path
  (`../continuous/sdk/typescript`) — clone this repo next to the `continuous`
  monorepo. Once published this becomes a plain `@continuous/sdk` dependency.
- Pin `@anthropic-ai/claude-agent-sdk` — its 0.x API moves between minor
  versions.
