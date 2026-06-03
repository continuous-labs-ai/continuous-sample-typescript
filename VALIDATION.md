# Acme billing-support demo — validate the five flows

The runbook + validation guide for taking the Acme billing-support agent through
Continuous end-to-end against the **dev** stack. It covers the four post-merge
features — **eval** (A/B), **rollout** (C), **experiment** (D), **shadow** (E) —
across five runnable flows. Each flow is one `just` recipe (`just --list`); the
rollout/experiment/shadow recipes also drive the production traffic and print the
report, so there's no second command to run.

A Python twin lives in `continuous-sample-python/VALIDATION.md` — same flows,
`uv` instead of `npm`.

## The cast (variants)

The shipped unit is a full **model × prompt × skill** composition, not a model.

| Variant | Model | Prompt | Skill | Role in the demo |
| ------- | ----- | ------ | ----- | ---------------- |
| **v1** | Haiku 4.5 (`claude-haiku-4-5-20251001`) | terse, generic | — | weak baseline / `main_variant` |
| **v2** | Sonnet 4.6 (`claude-sonnet-4-6`) | policy-aware | — | **CD candidate** (rollout v1 → v2) |
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
- Your `.continuous/config.yml` (+ `rollouts.yml`) live on `main`. There is no
  catalog or plan mirror to register — creates snapshot variants + judge from a
  `(repo, sha)` (blank sha = the default-branch HEAD). The dashboard derives
  `support-agent`'s variants from its runs; `main_variant` is seeded the first time
  you start a rollout/experiment/shadow.

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
4. **Deps:** `npm install`.

### Queue identity (why two workers)

A worker only receives Tasks whose **queue string matches its own**, auto-derived:

| Recipe | Queue | Use |
| ------ | ----- | --- |
| `just worker` | `user:<you>@<host>` (no `CONTINUOUS_GIT_SHA`) | local dev — eval (A) + shadow (E) |
| `just ci-worker` | `sha:<HEAD>` (`CONTINUOUS_GIT_SHA=$(git rev-parse HEAD)`) | a PR Run dispatches to `sha:<pr_head>` — CI (B) |

A cell stuck "awaiting" almost always means a queue mismatch.

## The five flows

### A — Eval (CLI)

```bash
just worker                 # terminal 1 — serves the dispatched eval tasks
just eval billing-support   # terminal 2
```
Author evals as code (dataset + judge + `config.yml` entry) and score every variant
locally, no PR. **Expect:** a Run with 20 tasks (10 scenarios × v1/v2);
`continuous runs show <run_id>` shows each `succeeded` with a verdict (v1/v2 `fail`).

### B — CI (GitHub PR — on-demand **and** auto)

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

### C — Rollout (CD, with traffic)

```bash
just rollout                # starts v1→v2 (plan ramp-fast), drives traffic, prints status
```
A staged canary promotes v2 over the v1 baseline. **Expect:**
`continuous rollout show <id>` shows the canary gating on real judgments. Operator
actions: `continuous rollout advance|pause|resume|rollback <id>`.

### D — Experiment (with traffic)

```bash
just experiment             # carves a 40% lane (v1=50/v2=50), drives traffic, prints the report
```
Where a rollout is *asymmetric* (one candidate ramping over one baseline), an
**experiment** is *symmetric*: a fixed traffic slice split across ≥2 variants, each
judged independently. **Expect:** the per-variant report shows **v2 success_rate >
v1** on identical live traffic; the rest of traffic stays on `main`.

### E — Shadow (with traffic)

```bash
just worker                 # terminal 1 — required; it executes the replays
just shadow                 # terminal 2 — samples v1 traffic, replays through v2, prints the paired report
```
**Shadow** is *try-before-you-buy*: it samples real v1 (baseline) traffic, replays
each sampled input through v2 **out of band** (no user sees it), and scores both
arms against one rubric. **Expect:** baseline vs candidate arms + a **paired** stat
(`candidate_wins`, `mean_score_delta > 0`). Replays run the real agent (~minutes),
so re-run `continuous shadow show <id>` as the candidate arm fills.

## Where to watch

- **Runs / PR evals:** `https://dashboard-dev.continuouslabs.ai/w/<wsId>` → Runs, and the GitHub PR.
- **Rollouts / Experiments / Shadows:** the dashboard views, or `continuous {rollout|experiment|shadow} show <id>`.
- **Workers:** `just workers` (subscriptions + their queue identity).
