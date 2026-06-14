# Acme billing-support demo — the five flows

The canonical runbook for taking the Acme billing-support agent through
Continuous end-to-end against the **dev** stack. It covers the four v2 surfaces —
**eval** (A/B), **replay** (C), **shadow** (D), **monitor** (E) — across five
runnable flows, then chains them into the detect → fix → verify loop (F). Each
flow is one `just` recipe (`just --list`); the replay/shadow/monitor recipes
also drive the production traffic they need.
**[VALIDATION.md](VALIDATION.md)** is the validation log for these flows.

A Python twin lives in `continuous-sample-python/DEMO.md` — same flows,
`uv` instead of `npm`.

## The cast (variants)

The shipped unit is a full **model × prompt × skill** composition, not a model.

| Variant | Model | Prompt | Skill | Role in the demo |
| ------- | ----- | ------ | ----- | ---------------- |
| **v1** | Haiku 4.5 (`claude-haiku-4-5-20251001`) | terse, generic | — | weak baseline / live traffic |
| **v2** | Sonnet 4.6 (`claude-sonnet-4-6`) | policy-aware | — | **shadow candidate** (v1 traffic mirrored through it) |
| **v3** | Sonnet 4.6 | same as v2 | **`billing-policy`** | **CI candidate** (the PR) |

`main` declares **v1 + v2**. Branch **`add-v3-billing-skill`** is pre-pushed and
adds v3 + the skill; opening its PR *is* the CI flow (B).

> Scores look low? v1 (Haiku) and v2 (Sonnet, no skill) genuinely fail the strict
> billing judge — only **v3**, with the `billing-policy` skill, knows Acme's real
> policy (e.g. the 14-day refund window, not the common-but-wrong 30 days). A wide
> v3 win over v1/v2 is the demo's whole point.

## Setup (once)

### Platform (dev)

- **GitHub App** `continuous-ci-dev` installed on the **`continuous-labs-ai`** org
  (so PRs get real comments + scores).
- A Continuous **workspace** — sign in at <https://dashboard-dev.continuouslabs.ai>
  with a GitHub account in `continuous-labs-ai`; sign-in provisions it.
- A **worker key** — Dashboard → workspace → **Admin → Worker API keys** → **Mint**
  (shown once).
- Your `.continuous/config.yml` lives on `main` — creates snapshot variants + judge
  from a `(repo, sha)` (blank sha = the default-branch HEAD).

### Local

1. **`continuous` CLI** — build from the monorepo and put it on `PATH`:
   ```bash
   go build -o continuous ./cli/cmd/continuous   # in a checkout of continuous-labs-ai/continuous
   ```
2. **Operator auth** (browser handshake):
   ```bash
   CONTINUOUS_API_URL=https://api-dev.continuouslabs.ai \
   CONTINUOUS_DASHBOARD_URL=https://dashboard-dev.continuouslabs.ai \
     continuous login
   ```
3. **`.env`** in this repo (auto-loaded by `just`):
   ```
   CONTINUOUS_API_URL=https://api-dev.continuouslabs.ai
   CONTINUOUS_API_KEY=<worker key>
   ANTHROPIC_API_KEY=<key with Haiku 4.5 + Sonnet 4.6>
   ```
   `ANTHROPIC_API_KEY` does double duty: the Claude Agent SDK runs the variants
   with it, and the Continuous SDK's worker-side rubric judge falls back to it
   (`CONTINUOUS_JUDGE_API_KEY` / `CONTINUOUS_JUDGE_BASE_URL` /
   `CONTINUOUS_JUDGE_MODEL` to override).
4. **Deps:** `npm install`.

> **Containerized worker (optional).** `docker-compose.yml` + `Tiltfile` run the
> same worker as a production-like container pinned to queue `sha:<HEAD>`
> ("Setup 2") — `tilt up` from the PR branch can stand in for `just ci-worker`.
> The five flows below only need the host worker.

### Queue identity (why two workers)

A worker only receives Tasks whose **queue string matches its own**, auto-derived:

| Recipe | Queue | Use |
| ------ | ----- | --- |
| `just worker` | `user:<you>@<host>` (no `CONTINUOUS_GIT_SHA`) | local dev — eval (A), replay (C), shadow (D), monitor (E) |
| `just ci-worker` | `sha:<HEAD>` (`CONTINUOUS_GIT_SHA=$(git rev-parse HEAD)`) | a PR Run dispatches to `sha:<pr_head>` — CI (B) |

A cell stuck "awaiting" almost always means a queue mismatch.

## The five flows

### A — Eval (local CLI)

```bash
just worker                 # terminal 1 — serves the dispatched eval tasks
just eval billing-support   # terminal 2
```
Author evals as code (dataset + judge + `config.yml` entry) and score every variant
locally, no PR. **Expect:** a Run with 20 tasks (10 scenarios × v1/v2), each judged
on the worker; `continuous runs show <run_id>` shows each `succeeded` with a
verdict (v1/v2 `fail`).

### B — CI (GitHub PR — on-demand **and** auto)

```bash
git checkout add-v3-billing-skill
just ci-worker              # terminal 1 — queue sha:<pr_head>, variants v1/v2/v3
just pr                     # terminal 2 — opens the v3 PR
```
Continuous posts a check-run and a comment **per declared eval** (two of each
here), each comment carrying the eval's verdict table — one column per variant.
- **auto** — `escalation · v3` runs automatically (relevance triage marks the
  irrelevant v1/v2 cells `skipped (triage)`).
- **on-demand** — `billing-support` renders a selection menu: one checkbox per
  variant, an `all variants` shortcut, and **`▶ Run selected`**. Tick `v1`, `v2`
  and `v3` (or `all variants`), **then tick `▶ Run selected`** — variant ticks
  alone dispatch nothing, and an unticked variant doesn't run. The menu becomes
  the verdict table: v3 `✓ pass`, v1/v2 `✗ fail` (the skill earns its place).
  `billing-support` (`block_pr: true`) gates the merge.

### C — Replay (a Run over recorded traffic)

```bash
just worker                 # terminal 1 — serves the replayed rows
just replay                 # terminal 2 — drives traffic, launches the replay Run
```
The recipe drives production traffic, then launches

```bash
continuous replay support-agent-ts --window 24h --judge evals/support-judge.md
```

— a replay Run drawing the last day of the agent's recorded production traffic
(newest first), re-running each row's recorded INPUT through every declared
variant. **Expect:** a Run over the drawn rows per variant; `continuous runs
show <run_id>` lists each task with a worker-judged verdict.

**Frozen set — the re-runnable benchmark:**

```bash
just replay-set             # freeze a 7-day draw, then replay against it
```

runs `continuous replay-set create <name> --agent support-agent-ts --from <7d ago>
--to <now> --scrub-pii` (a named, PII-scrubbed draw of recorded rows), then
`continuous replay support-agent-ts --set <name> --judge evals/support-judge.md`.
The same frozen rows score every future candidate; `continuous replay-set list`
shows each set's provenance.

### D — Shadow (with traffic)

```bash
just worker                 # terminal 1 — required; it executes the mirrors
just shadow                 # terminal 2 — samples v1 traffic, mirrors through v2, prints the paired report
```
**Shadow** is *try-before-you-buy*: it samples real production traffic, mirrors
each sampled input through the candidate variant **out of band** (no user sees
it), and scores it on the worker against one rubric. The sampled input is the
anonymized recorded input; the mirror runs against mocked tools. **Expect:** a
per-variant pass-rate over the mirrored rows. Mirrors run the real agent
(~minutes), so re-run `continuous shadow show <id>` as the rows fill.

### E — Monitor (the held-agent series)

```bash
just worker                 # terminal 1 — required; it executes the probes
just monitor                # terminal 2 — drives traffic, creates + backfills the monitor
```
A **monitor** holds one composition (v1) and re-scores it each period against
fresh recorded traffic, plotting `success_rate` over time — drift shows up as a
falling series. The recipe drives traffic, then runs

```bash
continuous monitor create support-agent-ts --variant v1 \
  --judge evals/support-judge.md --period 1h --limit 10
continuous monitor backfill <id> --from <1d ago>
```

so backfill points cover the traffic just driven. **Expect:** backfill points
within minutes (`continuous monitor show <id>` prints the series + alerts); the
next scheduled point builds when the running period closes.

### F — Close the loop (detect → fix → verify)

The flows above each show one surface; F chains them into the product's core
story. Three beats, after D/E have run:

**1. A shadow's failures become a frozen benchmark.** On the shadow detail page
(D), drill into the candidate arm's tasks; failing tasks offer **export as
Replay Set** — a named set frozen from exactly those rows. Re-run any candidate
against it:

```bash
continuous replay support-agent-ts --set <exported-set> --judge evals/support-judge.md
```

**Expect:** a Run over just the exported failures (`continuous replay-set list`
shows the set's provenance); every later re-run against the same set adds a
point to the benchmark series on its dashboard page — apples-to-apples across
candidates.

**2. A standing replay policy fires on the next PR.**

```bash
continuous replay-policy create pr-replay --agent support-agent-ts \
  --window 7d --sample 50 --judge evals/support-judge.md
```

Every later PR whose config declares the agent now gets a replay Run at the PR
head — half of the last week's recorded traffic re-run through the PR's
variants, no config change, no tick. Open a PR (flow B) and **expect** an extra
check-run + comment named `pr-replay` beside the two eval comments.
`continuous replay-policy list` / `delete <id>` manage it.

**3. The debugging drill-down.** On the monitor detail page (E), click a series
point → its failure-shape and locus breakdowns → the point's task list → a
task's steps viewer (the full trace). The same drill-down hangs off every Run,
shadow arm, and replay — and failing tasks there offer **export as Replay Set**
too, which is beat 1 again.

## Where to watch

- **Runs / PR evals:** `https://dashboard-dev.continuouslabs.ai/w/<wsId>` → Runs, and the GitHub PR.
- **Shadows / Monitors:** the dashboard views, or `continuous shadow show <id>` /
  `continuous monitor show <id>`.
- **Replay sets:** `continuous replay-set list` (and `show <id>` for the frozen rows).
- **Workers:** `just workers` (subscriptions + their queue identity).
- **Cost:** the worker reports each run's token usage (eval, replay, shadow,
  monitor — never production capture, which is input-only); the platform prices
  it per model (a dated snapshot resolves to its family rate) into the cost block
  shown beside latency and pass-rate on the run page.

> Production capture (`just simulate` / `just traffic`) records the agent's
> INPUT only — `client.record(agent, input)` — and the SDK anonymizes PII from
> the input before it ships. No output, usage, or score is captured live.

## Reset

`just clean` — cancel + delete every CLI run, shadow, monitor and replay set,
and close the v3 PR (PR runs survive — the run list a CLI session reads is
scoped to `source = cli`; the org + GitHub App install are kept).
