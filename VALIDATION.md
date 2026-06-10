# Acme billing-support demo — validate the five flows

The runbook + validation guide for taking the Acme billing-support agent through
Continuous end-to-end against the **dev** stack. It covers the five v2 flows —
**local CLI eval** (A), **CI PR eval** (B), **replay** (C), **shadow** (D),
**monitor** (E). Each flow is one `just` recipe (`just --list`); the
replay/shadow/monitor recipes also drive the production traffic they need and
print the report, so there's no second command to run.

| Flow | Recipe | Status |
| ---- | ------ | ------ |
| A — local CLI eval | `just eval` | **PENDING re-validation** |
| B — CI PR eval | `just pr` | **PENDING re-validation** |
| C — replay | `just replay` | **PENDING re-validation** |
| D — shadow | `just shadow` | **PENDING re-validation** |
| E — monitor | `just monitor` | **PENDING re-validation** |

A Python twin lives in `continuous-sample-python/VALIDATION.md` — same flows,
`uv` instead of `npm`.

## The cast (variants)

The shipped unit is a full **model × prompt × skill** composition, not a model.

| Variant | Model | Prompt | Skill | Role in the demo |
| ------- | ----- | ------ | ----- | ---------------- |
| **v1** | Haiku 4.5 (`claude-haiku-4-5-20251001`) | terse, generic | — | weak baseline / production traffic |
| **v2** | Sonnet 4.6 (`claude-sonnet-4-6`) | policy-aware | — | **shadow candidate** (replayed against v1) |
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
- Your `.continuous/config.yml` lives on `main`. Creates snapshot variants + judge
  from a `(repo, sha)` (blank sha = the default-branch HEAD). The dashboard derives
  `support-agent-ts`'s variants from its runs.

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
   `ANTHROPIC_API_KEY` also feeds the SDK's in-process rubric judge; override
   with `CONTINUOUS_JUDGE_API_KEY` / `CONTINUOUS_JUDGE_BASE_URL` /
   `CONTINUOUS_JUDGE_MODEL` to judge against a different endpoint or model.
4. **Deps:** `npm install`.

### Queue identity (why two workers)

A worker only receives Tasks whose **queue string matches its own**, auto-derived:

| Recipe | Queue | Use |
| ------ | ----- | --- |
| `just worker` | `user:<you>@<host>` (no `CONTINUOUS_GIT_SHA`) | local dev — eval (A), replay (C), shadow (D), monitor (E) |
| `just ci-worker` | `sha:<HEAD>` (`CONTINUOUS_GIT_SHA=$(git rev-parse HEAD)`) | a PR Run dispatches to `sha:<pr_head>` — CI (B) |

A cell stuck "awaiting" almost always means a queue mismatch.

## The five flows

### A — Local CLI eval

```bash
just worker                 # terminal 1 — serves the dispatched eval tasks
just eval billing-support   # terminal 2
```
Author evals as code (dataset + judge + `config.yml` entry) and score every variant
locally, no PR. **Expect:** a Run with 20 tasks (10 scenarios × v1/v2);
`continuous runs show <run_id>` shows each `succeeded` with a worker-judged
verdict (v1/v2 `fail`).

### B — CI PR eval (on-demand **and** auto)

```bash
git checkout add-v3-billing-skill
just ci-worker              # terminal 1 — queue sha:<pr_head>, variants v1/v2/v3
just pr                     # terminal 2 — opens the v3 PR
```
Continuous posts a check-run + a comment with an **eval × variant** table.
- **auto** — `escalation · v3` runs automatically (relevance triage marks the
  irrelevant v1/v2 cells `skipped (triage)`).
- **on-demand** — `billing-support` shows tick-to-dispatch checkboxes. Tick
  `billing-support · v3` → it dispatches + judges → `✓ pass` (the skill earns its
  place; v1/v2 `✗ fail`). `billing-support` (`block_pr: true`) gates the merge.

### C — Replay (with traffic)

```bash
just worker                 # terminal 1 — executes the replay tasks
just replay                 # terminal 2 — drives traffic, then runs the replay-window eval
```
The `replay-recent` eval has no JSONL file: its dataset is generated at
Run-creation from the last 24h of recorded production traffic (the rows
`client.reportTask` captured), and every variant re-runs those real inputs.
**Expect:** a Run whose task inputs are the recorded questions; v2 outscores v1
on identical traffic.

### D — Shadow (with traffic)

```bash
just worker                 # terminal 1 — required; it executes the replays
just shadow                 # terminal 2 — samples v1 traffic, replays through v2, prints the paired report
```
**Shadow** is *try-before-you-buy*: it samples real v1 (baseline) traffic, replays
each sampled input through v2 **out of band** (no user sees it), and scores both
arms against one rubric. **Expect:** baseline vs candidate arms + a **paired** stat
(`candidate_wins`, `mean_score_delta > 0`). Replays run the real agent (~minutes),
so re-run `continuous shadow show <id>` as the candidate arm fills.

### E — Monitor (with traffic)

```bash
just worker                 # terminal 1 — executes the probe replays
just monitor                # terminal 2 — drives traffic, creates the monitor, backfills the last day
```
A **monitor** holds one variant under a scheduled judge: each period it draws
recorded traffic, re-runs the held variant, and scores the results into a
success-rate series. The recipe backfills the last day so the first points cover
the traffic it just drove. **Expect:** `just monitor-show <id>` fills with
per-period points (success_rate per point) over a few minutes; the dashboard
shows the series with drill-down into failing tasks.

## Where to watch

- **Runs / PR evals:** `https://dashboard-dev.continuouslabs.ai/w/<wsId>` → Runs, and the GitHub PR.
- **Shadows / Monitors:** the dashboard views, `continuous shadow show <id>`, or `just monitor-show <id>`.
- **Workers:** `just workers` (subscriptions + their queue identity).
- **Cost:** the worker reports each run's token usage; the platform prices it per model (a dated snapshot resolves to its family rate) into the cost block shown beside latency and pass-rate on the run page and the production surfaces.
