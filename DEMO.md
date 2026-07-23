# Acme billing-support demo — the five flows

The canonical runbook for taking the Acme billing-support agent through Continuous
end-to-end. It covers the four v2 surfaces — **eval** (A/B), **replay** (C),
**shadow** (D), **monitor** (E) — across five runnable flows, then chains them into
the detect → fix → verify loop (F). Each flow is one `just` recipe (`just --list`);
the replay/shadow/monitor recipes also drive the production traffic they need.
**[VALIDATION.md](VALIDATION.md)** is the validation log for these flows.

A Python twin lives in `continuous-sample-python/DEMO.md` — same flows, `uv`
instead of `npm`.

## One launch verb

The current CLI has **one** way to launch work: `continuous run --dataset-id <ds>`
submits a **Job** over an existing **Dataset**, and the surface (eval / replay /
shadow) is **derived from the Dataset's kind** — `static` → eval, `historical` →
replay, `live` → shadow (0002 §3.3). So every flow is two steps:

1. `continuous dataset create <dir> --agent … --name … [--kind …] [--window …]`
   pushes a Dataset directory and prints a `ds_` id (0004 §8.3).
2. `continuous run --dataset-id <ds> --agent … --variant … [--wait]` runs a variant
   over it. The **judge and agent come from the Dataset**, never the command.

A **Dataset is a directory**, not a `.jsonl`: a top-level `dataset.toml`
(`[aggregation]`), a `tests/judge.toml` (a rewardkit judge whose REQUIRED
`[judge].model` is the judge model — `anthropic/<id>`, 0003 §14.1), and, for a
`static` set, `tasks/<task>/{instruction.md, task.toml, expected.md}`. This repo's
sets live under [`datasets/`](datasets).

> **Surface availability (ADR-0011).** A **deployed** bundle (`development`,
> `production`) serves only the **Environment** surface (Simulators/Simulations/
> traces); the eval, replay, shadow, monitor, dataset, and trigger routes are not
> registered there and return 404. The five flows below therefore run against a
> stack that registers the full surface (a `local` bundle). Point
> `CONTINUOUS_API_URL` / `continuous auth login --api-url` at such a stack.

## The cast (variants)

The shipped unit is a full **model × prompt × skill** composition, not a model.

| Variant | Model                                   | Prompt         | Skill                | Role in the demo                                      |
| ------- | --------------------------------------- | -------------- | -------------------- | ----------------------------------------------------- |
| **v1**  | Haiku 4.5 (`claude-haiku-4-5-20251001`) | terse, generic | —                    | weak baseline / live traffic                          |
| **v2**  | Sonnet 4.6 (`claude-sonnet-4-6`)        | policy-aware   | —                    | **shadow candidate** (v1 traffic mirrored through it) |
| **v3**  | Sonnet 4.6                              | same as v2     | **`billing-policy`** | **CI candidate** (the PR)                             |

`main` declares **v1 + v2**. Branch **`add-v3-billing-skill`** is pre-pushed and
adds v3 + the skill; a Trigger over the PR _is_ the CI flow (B).

> Scores look low? v1 (Haiku) and v2 (Sonnet, no skill) genuinely fail the strict
> billing judge — only **v3**, with the `billing-policy` skill, knows Acme's real
> policy (e.g. the 14-day refund window, not the common-but-wrong 30 days). A wide
> v3 win over v1/v2 is the demo's whole point.

## Setup (once)

### Platform

- **GitHub App** installed on the **`continuous-labs-ai`** org (so PRs get real
  comments + check-runs).
- A Continuous **workspace** — sign in at the app and it provisions one.
- A **worker key** — Dashboard → workspace → **Admin → Worker API keys** → **Mint**.

### Local

1. **`continuous` CLI** — build from the monorepo and put it on `PATH`:
   ```bash
   go build -o continuous ./cli/cmd/continuous   # in a checkout of continuous-labs-ai/continuous
   ```
2. **Operator auth** (browser handshake) — point it at the stack that serves the
   full surface (see the ADR-0011 note above):
   ```bash
   CONTINUOUS_API_URL=<api-url> CONTINUOUS_APP_URL=<app-url> continuous auth login
   ```
3. **`.env`** in this repo (auto-loaded by `just`):
   ```
   CONTINUOUS_API_URL=<api-url>
   CONTINUOUS_API_KEY=<worker key>
   ANTHROPIC_API_KEY=<key with Haiku 4.5 + Sonnet 4.6>
   ```
   `ANTHROPIC_API_KEY` does double duty: the Claude Agent SDK runs the variants
   with it, and the Continuous SDK's worker-side rubric judge falls back to it
   (`CONTINUOUS_JUDGE_API_KEY` / `CONTINUOUS_JUDGE_BASE_URL` override the judge key /
   endpoint; the judge **model** comes from each rubric's `[judge].model`).
4. **Deps:** `npm install`, plus `gh` and `jq` on `PATH` (the recipes capture
   `ds_`/`job_` ids from `--json` output with `jq`).

### Queue identity (why two workers)

A worker only receives Trials whose **queue string matches its own**, auto-derived:

| Recipe           | Queue                                                     | Use                                                       |
| ---------------- | --------------------------------------------------------- | --------------------------------------------------------- |
| `just worker`    | `user:<you>@<host>` (no `CONTINUOUS_GIT_SHA`)             | local dev — eval (A), replay (C), shadow (D), monitor (E) |
| `just ci-worker` | `sha:<HEAD>` (`CONTINUOUS_GIT_SHA=$(git rev-parse HEAD)`) | a PR Trigger dispatches to `sha:<pr_head>` — CI (B)       |

A cell stuck "awaiting" almost always means a queue mismatch.

## The five flows

### A — Eval (local CLI)

```bash
just worker                 # terminal 1 — serves the dispatched eval tasks
just eval billing-support   # terminal 2 — pushes the static Dataset, runs each variant
```

`just eval` runs, under the hood:

```bash
ds=$(continuous dataset create ./datasets/billing-support --agent support-agent-ts --name billing-support --json | jq -r .id)
continuous run --dataset-id "$ds" --agent support-agent-ts --variant v1 --wait
continuous run --dataset-id "$ds" --agent support-agent-ts --variant v2 --wait
```

Author evals as code (a Dataset directory + rubric) and score every variant
locally, no PR. **Expect:** one Job per variant over the 10 tasks, each judged on
the worker; `continuous job get <job_id>` shows each Trial with its verdict (v1/v2
`fail`). `--wait` tails the Job and exits non-zero only if it ends failed/cancelled
(a low score still `succeeds`).

### B — CI (GitHub PR — auto-fire Trigger)

```bash
git checkout add-v3-billing-skill
just ci-worker              # terminal 1 — queue sha:<pr_head>, variants v1/v2/v3
just trigger                # terminal 2 — pushes the Dataset + arms a Trigger for v3
just pr                     # terminal 2 — opens the v3 PR
```

A **Trigger** (`continuous trigger create --agent … --variant v3 --dataset-id <ds>
--path 'agent/variants/v3/**'`) auto-runs one `(agent, variant)` over a static or
historical Dataset on **every PR** whose diff matches its `--path` glob (0003
§4.1.9 / §15.7). Opening the PR fires it: Continuous creates a batch Job at the PR
head and posts a **check-run** whose conclusion mirrors the Job's terminal status
(never score-driven — a low score still `succeeds`, so a red check means "did not
run", not "scored badly"). **Expect:** a `billing-support` check-run on the PR; the
Job's Trials show v3 `pass`, and v1/v2 `fail` if you also arm Triggers for them.
Arm one Trigger per variant you want gated (`just trigger v1`, `just trigger v2`).

### C — Replay (a Run over recorded traffic)

```bash
just worker                 # terminal 1 — serves the replayed rows
just replay                 # terminal 2 — drives traffic, freezes a historical set, runs it
```

`just replay` drives production traffic, freezes a **historical Dataset** over a
trailing window, then runs each variant:

```bash
npm run simulate -- 24
ds=$(continuous dataset create ./datasets/recorded --agent support-agent-ts --name replay-24h --kind historical --window 24h --json | jq -r .id)
continuous run --dataset-id "$ds" --agent support-agent-ts --variant v1 --sample 100 --wait
continuous run --dataset-id "$ds" --agent support-agent-ts --variant v2 --sample 100 --wait
```

A `historical` Dataset materializes its rows from the agent's recorded production
**INPUT** within `--window` (newest first), re-running each row through the
variant. The judge is the Dataset's (`datasets/recorded/tests/judge.toml`, which
grades against Acme's policy). **Expect:** one Job per variant; `continuous job get
<job_id>` lists each Trial with a worker-judged verdict.

**Frozen set — the re-runnable benchmark:** a historical Dataset is **immutable**,
so the same `ds_` scores every future candidate — just reuse its id. `continuous
dataset list` shows each set's provenance (kind, window, rows). `--sample <pct>`
draws a fraction of the window each run.

### D — Shadow (with traffic)

```bash
just worker                 # terminal 1 — required; it executes the mirrors
just shadow                 # terminal 2 — live Dataset + --deadline, then the paired report
```

**Shadow** is _try-before-you-buy_: run a candidate over a **live** Dataset with a
`--deadline` — a streaming Job that samples real production traffic and mirrors each
sampled input through the candidate **out of band** (no user sees it), judged on the
worker. `just shadow` runs:

```bash
ds=$(continuous dataset create ./datasets/recorded --agent support-agent-ts --name shadow-live --kind live --json | jq -r .id)
continuous run --dataset-id "$ds" --agent support-agent-ts --variant v2 --sample 100 --deadline 1h --json
```

**Expect:** a streaming Job that fills as traffic arrives. Mirrors run the real
agent (~minutes), so re-run `continuous job get <id>` as the rows fill.

### E — Monitor (the held-agent series)

```bash
just worker                 # terminal 1 — required; it executes the probes
just monitor                # terminal 2 — drives traffic, freezes a historical set, creates the monitor
```

A **monitor** holds one composition (v1) and re-scores it each period against a
historical Dataset's window, plotting `success_rate` over time — drift shows up as a
falling series. `just monitor` runs:

```bash
npm run simulate -- 24
ds=$(continuous dataset create ./datasets/recorded --agent support-agent-ts --name monitor-24h --kind historical --window 24h --json | jq -r .id)
continuous monitor create --dataset-id "$ds" --variant v1 --schedule 1h --limit 10
```

The monitor's agent and judge come from the Dataset. **Expect:** the first point
builds when the first `--schedule` period closes (there is no backfill — the series
runs forward; use a shorter `--schedule` to see one sooner). `continuous monitor get
<id>` prints the series.

### F — Close the loop (detect → fix → verify)

The flows above each show one surface; F chains them into the product's core story.

**1. A named historical Dataset is a re-runnable benchmark.** Freeze one over the
window whose traffic you care about (flow C), then re-run any candidate against the
**same immutable `ds_`**:

```bash
continuous run --dataset-id <historical-ds> --agent support-agent-ts --variant v2 --wait
```

**Expect:** each re-run against the same set adds a comparable point to the
benchmark series on its dashboard page — apples-to-apples across candidates.
(In the app, a shadow's failing tasks offer **export as a Dataset**, which drives
the same `dataset create`.)

**2. A standing replay Trigger fires on the next PR.** Triggers accept a
`historical` Dataset too, so a PR-replay policy is just a Trigger over one:

```bash
continuous trigger create --agent support-agent-ts --variant v2 --dataset-id <historical-ds> --path 'agent/**'
```

Every later PR whose diff matches now gets a replay Job at the PR head — the last
window's recorded traffic re-run through the PR's variant, with its own check-run.
`continuous trigger list` / `continuous trigger delete <id>` manage it.

**3. The debugging drill-down.** In the app, click a Run/monitor series point → its
failure-shape and locus breakdowns → the point's task list → a Task's steps viewer
(the full trace). Failing tasks there offer **export as a Dataset** too — beat 1.

## Where to watch

- **Jobs / PR evals:** the app's Runs view, and the GitHub PR check-runs.
- **Shadows / Monitors:** the app views, or `continuous job get <id>` /
  `continuous monitor get <id>`.
- **Datasets:** `continuous dataset list` (and `continuous dataset get <id>` for
  its first rows).
- **Workers:** `just workers` (`continuous worker list` — subscriptions + queue).
- **Cost:** the worker reports each run's token usage (eval, replay, shadow,
  monitor — never production capture, which is input-only); the platform prices it
  per model into the cost block on the run page.

> Production capture (`just simulate` / `just traffic`) records the agent's INPUT
> only — `client.record(agent, input)` with a plain text string — and the SDK
> anonymizes PII from the input before it ships. No output, usage, or score is
> captured live.

## Reset

`just clean` — delete every CLI-created Dataset (the delete **cascades** its Jobs,
Monitors, and Triggers, 0004 §8.4) and close the v3 PR. The workspace + GitHub App
install are kept.
