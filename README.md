# continuous-sample-typescript

A realistic sample agent that ships on [Continuous](https://continuouslabs.ai) —
CI/CD for AI agents. It's a **customer-support agent for "Acme"**, a fictional
SaaS company, built on the **Anthropic Claude Agent SDK** and served through the
**Continuous TypeScript Worker SDK**.

The point of the sample: the thing you ship is not a model, it's a full
**`model × prompt × skill`** composition — a _variant_. Continuous scores each
variant against an eval set in CI, replays recorded production traffic through
it, mirrors a candidate behind live traffic (shadow), and watches the shipped
composition for drift (monitor).

> A Python twin of this repo lives at **continuous-sample-python** — same
> scenario, same variants, mirror-image SDK.

## The variants

Each variant is a directory under [`agent/variants/`](agent/variants), declared
in [`.continuous/config.yml`](.continuous/config.yml). They differ on exactly
one axis at a time, so the eval scores tell a clean story:

| Variant | Model      | Prompt                   | Skill                | Role                                                  |
| ------- | ---------- | ------------------------ | -------------------- | ----------------------------------------------------- |
| **v1**  | Haiku 4.5  | terse, generic           | —                    | weak baseline (live traffic)                          |
| **v2**  | Sonnet 4.6 | policy-aware, empathetic | —                    | **shadow candidate** (v1 traffic mirrored through it) |
| **v3**  | Sonnet 4.6 | same as v2               | **`billing-policy`** | **CI candidate** (the PR)                             |

Acme's real refund/proration/trial rules are proprietary — the model can't guess
them. So v1 and v2 confidently invent plausible-but-wrong specifics (a
"30-day refund" when the real window is 14 days), while **v3** reads the
[`billing-policy` skill](https://github.com/continuous-labs-ai/continuous-sample-typescript/blob/add-v3-billing-skill/.claude/skills/billing-policy/SKILL.md)
and gets the exact terms right. The eval set
([`datasets/billing-support/`](datasets/billing-support), judged by its
`tests/judge.toml`) is built so **v1 < v2 < v3**.

## How it works

[`src/worker.ts`](src/worker.ts) is the whole integration:

```ts
const worker = new ManagedAgentWorker({
  agent: "support-agent-ts",
  managedAgents: { v1: optsV1, v2: optsV2 },
});
startWorker(worker); // one subscription advertises variants v1,v2
```

You supply `managedAgents` — one Agent SDK `Options` per variant (its composed
`model × prompt × skill`). The adapter picks `managedAgents[dispatch.variant]`, runs
it against the dispatched instruction, converts the transcript to an **ATIF v1.7
Trajectory** (`toAtif`), harvests usage, and returns the steps — **no score**. The
SDK's in-process rubric judge then scores the trajectory against the Dataset's
`tests/judge.toml`, whose REQUIRED `[judge].model` declares the judge model
(Anthropic-only, `anthropic/<id>`). Judging happens on the worker, against your own
judge model endpoint (`CONTINUOUS_JUDGE_API_KEY`, falling back to
`ANTHROPIC_API_KEY`), before the result is reported.

## Setup

```bash
# 1. Install the Continuous CLI and log in.
curl -fsSL https://app.continuouslabs.ai/install.sh | sh
continuous auth login

# 2. Install dependencies.
npm install

# 3. Two keys in the environment:
export CONTINUOUS_API_KEY=ck_...        # worker key — minted in the dashboard (Admin → Worker API keys)
export CONTINUOUS_API_URL=https://api.continuouslabs.ai   # or your local/dev stack
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

The canonical runbook — prerequisites, the cast (v1/v2/v3), and the five flows
packaged as `just` recipes (`just --list`) — lives in **[DEMO.md](DEMO.md)**;
**[VALIDATION.md](VALIDATION.md)** is the validation log. The current CLI has one
launch verb: `continuous run --dataset-id <ds>` runs a variant over a Dataset, and
the surface is derived from the Dataset's kind (`static` → eval, `historical` →
replay, `live` → shadow). So each flow is `continuous dataset create <dir>` then
`continuous run` (see DEMO.md).

- **A — Eval:** score every variant locally with `just eval` (no PR).
- **B — CI:** arm a Trigger over the eval Dataset (`just trigger`), then open the
  pre-staged `add-v3-billing-skill` PR (`just pr`); the Trigger auto-runs the
  variant on the PR head and posts a check-run.
- **C — Replay:** `just replay` — freeze a `historical` Dataset over a window of
  recorded production traffic and run each variant over it (re-runnable benchmark).
- **D — Shadow:** `just shadow` — run a candidate over a `live` Dataset with a
  `--deadline`, mirroring sampled traffic out of band.
- **E — Monitor:** `just monitor` — hold the shipped variant and re-score it per
  period over a historical Dataset.

## Layout

```
.continuous/config.yml        # agent + variants (read by the worker; not parsed by the platform)
agent/variants/v{1,2}/        # one model × prompt × skill composition each (main)
datasets/billing-support/     # primary eval Dataset (0004 §8.3):
  dataset.toml                #   [aggregation] — the two-stage reward reduction
  tests/judge.toml            #   rewardkit judge; [judge].model is the judge model
  tasks/<t>/instruction.md    #   the customer question (the agent's input)
  tasks/<t>/task.toml         #   [task].name (Harbor org/name)
  tasks/<t>/expected.md       #   the correct resolution (the judge grades against it)
datasets/escalation/          # second, non-blocking eval: escalate-vs-handle scenarios
datasets/recorded/            # historical/live judge for replay/shadow/monitor:
  tests/acme-billing-policy.md#   the policy the judge grades recorded traffic against
src/                          # the worker + production-traffic simulator
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
- `ManagedAgentWorker` is imported from the `@continuous/sdk/anthropic` subpath
  (same package, no extra dependency); the core worker entry point `startWorker`
  comes from `@continuous/sdk`.
- Production capture is input-only: [`src/simulate.ts`](src/simulate.ts) calls
  `client.record(agent, input)` with the recorded input as a plain **text** string
  (no output, usage, or score), and the SDK's `builtinAnonymize` scrubs PII from
  the input text before it ships.
- Pin `@anthropic-ai/claude-agent-sdk` — its 0.x API moves between minor
  versions.
