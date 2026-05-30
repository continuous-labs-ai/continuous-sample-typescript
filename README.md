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

## Demo 1 — CI: open a PR for v3

When you open a pull request, Continuous evaluates the variants whose files the
diff touches, then posts a check-run and a comment with the per-variant scores.
`block_pr: true` gates the merge on the result.

```bash
git checkout -b add-v3-billing-skill

# The PR introduces v3: a new variant entry + its prompt, plus the skill.
#   .continuous/config.yml                       # add the v3 variant
#   agent/variants/v3/{prompt.md,variant.yaml}   # model + prompt + skills:[billing-policy]
#   .claude/skills/billing-policy/SKILL.md        # Acme's real policy

git add -A && git commit -m "Add v3: billing-policy skill"
git push -u origin add-v3-billing-skill
gh pr create --fill
```

Because v3's `paths` glob matches the diff, Continuous runs the
`billing-support` eval for **v3 against the baseline** and comments with the
score delta. v3 should win on the policy questions — that's the skill earning
its place.

**No GitHub App yet?** Dispatch the same eval from your laptop against your
running worker — no PR required:

```bash
continuous eval billing-support
```

---

## Demo 2 — CD: roll out v1 → v2, pause after two stages

Promote v2 (the current candidate) over the v1 baseline through a staged ramp,
and hold it after two completed stages. The plan
[`ramp`](.continuous/rollouts.yml) is `10 → 25 → 50 → 100`.

```bash
# Start the rollout. baseline = current main (v1), candidate = v2.
# This enters stage 0 (10%) immediately and tails the live event stream.
continuous rollout start support-agent v2 --plan ramp
#   Started rol_01HK...  Watch: continuous rollout show rol_01HK...

# From a second terminal, drive the stages (use the rol_ id printed above):
continuous rollout advance rol_01HK...   # stage 0 done -> stage 1 (25%)   [1 completed]
continuous rollout advance rol_01HK...   # stage 1 done -> stage 2 (50%)   [2 completed]
continuous rollout pause   rol_01HK...   # hold at stage 2, status = paused

continuous rollout show rol_01HK...
#   Rollout rol_01HK... — paused (stage 2/4)
#   v1 -> v2
#   Actions: advance by you: applied ... / advance by you: applied ... / pause by you: applied
```

The rollout now sits **paused at 50%**, non-terminal — it waits indefinitely
until you `continuous rollout resume` (continue the ramp), `rollback` (back to
v1), or `cancel`.

### Variant, autonomous canary

To watch the **Canary Agent** gate the rollout on real traffic instead of
driving it by hand, use the fast plan and feed it production trajectories:

```bash
continuous rollout start support-agent v2 --plan ramp-fast   # 2-minute bakes
npm run simulate -- 40                                        # live traffic -> candidate + baseline
```

At each stage gate the canary compares candidate vs baseline judgments and emits
`advance`, `retreat`, or `pause` on its own.

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
