# Demo runbook — Continuous end-to-end (TypeScript sample)

Operator runbook for taking the Acme billing-support agent through Continuous
end-to-end against the **dev** stack. A Python twin lives in
`continuous-sample-python/DEMO.md` — same flow, mirror-image commands.

Five flows, **all runnable** — together they cover the four post-merge features
Continuous ships: **eval** (A/B), **rollout** (C), **experiment** (D), **shadow** (E):

1. **Eval-as-code** — author evals (dataset + judge + config) that score each variant.
2. **CI, on-demand dispatch** — open a PR that adds a candidate variant (v3 + the
   `billing-policy` skill); Continuous posts a PR comment with an **eval × variant
   checkbox table**; you tick _which eval(s)_ to run; scores come back inline and
   gate the merge.
3. **CD, staged rollout** — promote v2 over the v1 baseline through a
   `10 → 25 → 50 → 100` ramp and **pause after 2 of 4 stages**, with the simulator
   feeding live traffic so the canary gates for real.
4. **Experiment (A/B on live traffic)** — carve a slice of production traffic and
   split it across v1/v2, judging each variant independently for a symmetric
   per-variant report.
5. **Shadow** — sample real v1 traffic and replay it through the v2 candidate _out
   of band_ (no user ever sees it), for a baseline-vs-candidate paired report.

Every flow is packaged as a **`just` recipe** (`just --list`) — `just eval`,
`just rollout`, `just experiment`, `just shadow`, with `just worker` + `just simulate`
driving the agent and its traffic. The recipes are this runbook, made repeatable.

> Status: **built and pre-staged on `main`** — the runbook below is runnable end-to-end.

---

## Topology

```
            ┌─────────────────────────────────────────┐
            │  Continuous platform  (DEV, deployed)    │
            │  api-dev / dashboard-dev .continuouslabs │
            │  real WorkOS · real GitHub App · judge   │
            └──▲──────────────▲───────────────▲────────┘
   real GitHub  │ webhooks     │ poll          │ poll/report (worker key)
   PR + comment │              │               │
       ┌────────┘   ┌──────────┴─────────┐  ┌──┴─────────────────────┐
       │            │  Agent on the HOST │  │  Agent in TILT (Docker)│
       │            │  local dev regime  │  │  preview/prod regime   │
       │            │  queue user:@host  │  │  queue sha:<git_sha>   │
       └────────────┤  → Demo A (CLI)    │  │  → Demo B (PR) / sim   │
                    └────────────────────┘  └────────────────────────┘
```

The platform is the **dev** stack (real GitHub App on `continuous-labs-ai`, so PRs
get real comments and real scores). The agent runs in **two setups**, because
Continuous routes work by queue identity (§D) and the two regimes map onto two real
deployment situations:

- **On the host** = _local development_ (`user:@host` queue) — what the
  `continuous eval` CLI matches. **Enables Demo A.**
- **In Tilt** = a _preview/production deployment_ (`sha:<git_sha>` queue, pinned to a
  commit just like a Vercel/Railway/Fly preview) — what a PR Run matches. **Enables
  Demo B.** The CD simulator (Demo C) also lives here as the production app.

---

## The cast (variants)

| Variant | Model                                   | Prompt         | Skill                | Role in the demo                   |
| ------- | --------------------------------------- | -------------- | -------------------- | ---------------------------------- |
| **v1**  | Haiku 4.5 (`claude-haiku-4-5-20251001`) | terse, generic | —                    | weak baseline / `main_variant`     |
| **v2**  | Sonnet 4.6 (`claude-sonnet-4-6`)        | policy-aware   | —                    | **CD candidate** (rollout v1 → v2) |
| **v3**  | Sonnet 4.6                              | same as v2     | **`billing-policy`** | **CI candidate** (the PR)          |

`main` declares **v1 + v2**. Branch **`add-v3-billing-skill`** is pre-pushed and
adds v3 + the skill; its **PR is intentionally not open yet** — opening it _is_ the
CI demo.

---

## Prerequisites

### A. Platform (one-time, dev)

| Requirement                                                                      | How / where                                                                                                                                                                                                                                                                                                                                               | Status       |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| GitHub App **`continuous-ci-dev`** installed on the **`continuous-labs-ai`** org | <https://github.com/apps/continuous-ci-dev/installations/new>                                                                                                                                                                                                                                                                                             | ✅ installed |
| A Continuous **workspace** for the org                                           | Sign in at <https://dashboard-dev.continuouslabs.ai> with a GitHub account that belongs to `continuous-labs-ai`; sign-in provisions the workspace. Note the **workspace id** from the URL (`/w/<wsId>`); the one used so far is `ws_01KSY1HJ4XSPD1JQESEBXECTY7`.                                                                                          | ✅           |
| A **Worker API key**                                                             | Dashboard → workspace → **Admin → Worker API keys** (`/w/<wsId>/admin/tokens`) → **Mint**. It's a WorkOS org API key; the full value is **shown once** on mint — copy it. (`.env.example` uses `ck_…` as a placeholder; use whatever the dashboard shows.)                                                                                                | ⬜ mint      |
| **Variant catalog + plan mirror registered**                                     | Both register when a push to `main` touches `.continuous/config.yml` **or** `.continuous/rollouts.yml` (0004 §15.2): the server reads both files at that SHA and upserts the variant catalog (`main_variant=v1`, variants `v1,v2`) and the plan mirror (`ramp`, `ramp-fast`). Verify in the dashboard the `support-agent` shows v1/v2 with **main = v1**. | ⬜           |

### B. Local toolchain (per operator)

- **Docker** + **Tilt** — to run this repo's worker/simulator stack.
- **The `continuous` CLI** — build from the monorepo (**Go 1.26+**) and put on `PATH`:
  ```bash
  go build -o continuous ./cli/cmd/continuous   # in a checkout of continuous-labs-ai/continuous
  ```
- **`ANTHROPIC_API_KEY`** — the Claude Agent SDK spawns Claude Code (a subprocess)
  that calls Anthropic; the key needs access to **Haiku 4.5 and Sonnet 4.6**.
- **`git`** + **`gh`**, with `gh` authenticated for `continuous-labs-ai` (`gh auth status`).
- **Node ≥ 18** — to run the agent on the host (Setup 1). Both setups resolve
  `@continuous/sdk` from a sibling **`../continuous`** monorepo checkout (host: the
  `file:` path; container: via the Docker build context), so clone the monorepo next
  to this repo.

### C. Two credentials — don't conflate them

| Who                              | Credential                                                                                           | Used by                                                                 |
| -------------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| **Operator** (you)               | sealed session from `continuous login` (browser handshake → `~/.config/continuous/credentials.toml`) | `continuous eval`, `continuous rollout`, `continuous runs/logs/workers` |
| **Worker** (the Tilt deployment) | the worker key (`CONTINUOUS_API_KEY=…`)                                                              | the worker + simulator containers                                       |

### D. Queue identity

A worker only receives Tasks whose **`queue` string matches its own** (0003 §6.3),
auto-derived (never declared):

| Regime       | Queue string                 | When                                                 |
| ------------ | ---------------------------- | ---------------------------------------------------- |
| **Deployed** | `sha:<git_commit_sha>`       | `CONTINUOUS_GIT_SHA` set (the Tilt worker sets this) |
| **Local**    | `user:<username>@<hostname>` | no `CONTINUOUS_GIT_SHA` (host-run worker)            |

Match the two sides:

- **A PR Run (Demo B)** dispatches `queue = sha:<pr_head_sha>` (from
  `pull_request.head.sha`). → the Tilt worker must run with
  `CONTINUOUS_GIT_SHA = <pr_head_sha>`. Bringing the stack up on the PR checkout does
  this automatically (`git_sha` defaults to `git rev-parse HEAD`).
- **`continuous eval` (Demo A)** submits `sha:<CONTINUOUS_GIT_SHA>` when that env is
  set, else `user:<you>@<host>`. → to reuse the Tilt worker, run
  `CONTINUOUS_GIT_SHA=<same sha> continuous eval …`.

A cell stuck "awaiting" almost always means a queue mismatch — the Task is `queued`
with no worker on that queue (`continuous workers list` shows each worker's queue).

### E. Environment

The Tilt stack reads these from your shell (it passes them into the containers):

```bash
export CONTINUOUS_API_URL=https://api-dev.continuouslabs.ai
export CONTINUOUS_API_KEY=...            # worker key (shown once on mint)
export ANTHROPIC_API_KEY=sk-ant-...
# operator commands, once:
export CONTINUOUS_DASHBOARD_URL=https://dashboard-dev.continuouslabs.ai
continuous login
```

---

## Run the agent — two setups

The agent runs **its own local files** — the server sends only a `variant` name +
input — so the checkout you run determines what each variant does (v3 reads the skill
only when v3's files are present). The two setups differ only in **queue regime**:

| Setup            | How                                                          | Queue               | Simulates                     | Drives                         |
| ---------------- | ------------------------------------------------------------ | ------------------- | ----------------------------- | ------------------------------ |
| **1. Local dev** | `npm run worker` on the host, `CONTINUOUS_GIT_SHA` **unset** | `user:<you>@<host>` | a developer iterating locally | **Demo A** (`continuous eval`) |
| **2. Preview**   | `tilt up` on the PR checkout (`git_sha` = head SHA)          | `sha:<head_sha>`    | a per-PR preview deployment   | **Demo B** (GitHub PR)         |

```bash
# Setup 1 — local dev (host). For Demo A. (needs ../continuous sibling for the SDK)
git checkout main            # (or the v3 branch to also serve v3)
npm install
npm run worker                          # → variants [v1,v2], queue user:<you>@<host>

# Setup 2 — preview env (Tilt). For Demo B.
git fetch origin && git checkout add-v3-billing-skill && git reset --hard origin/add-v3-billing-skill
tilt up                                 # → variants [v1,v2,v3], queue sha:<head_sha>
```

`continuous workers list` shows each worker and its queue. (Demo C's production
traffic is the **simulator**, covered in that section — it reports trajectories and
doesn't depend on queue identity, so it runs from either setup.)

---

## Demo A — Create an eval

The eval surface is three files, versioned with the agent: `evals/support.jsonl`
(dataset `{name,input,expected_output}`), `evals/judge.md` (the `[0,1]` rubric), and
the `.continuous/config.yml` `evals:` entry (binds dataset+judge+agent; sets `on`,
`dispatch`, `block_pr`).

Run one without a PR — a **Local Run** — using **Setup 1** (the host worker). Keep
`CONTINUOUS_GIT_SHA` unset in both the worker's shell and here, on the same machine,
so both land on `user:<you>@<host>`:

```bash
continuous eval billing-support        # pushes a temp ref, dispatches, tails SSE
continuous eval                        # all declared evals
```

`evals/escalation.*` is a second worked example — it scores whether the agent
escalates the right requests and handles the routine ones.

---

## Demo B — CI: open the v3 PR, dispatch on demand, pick the eval

1. **Bring up the preview env** (Setup 2 — `tilt up` on the v3 branch) →
   worker on `sha:<head_sha>`, variants `[v1,v2,v3]`.
2. **Open the PR:**
   ```bash
   gh pr create --base main --head add-v3-billing-skill --title "Add v3: billing-policy skill" -F .github/PR_BODY_v3.md
   ```
3. Continuous posts a **check-run** + a **PR comment**: one table per agent —
   **rows = evals (`billing-support`, `escalation`), columns = variants (v1,v2,v3)** — each
   cell a checkbox `<!-- continuous:dispatch:<eval>:<variant> -->` (0002 §7). Nothing
   runs until you tick.
4. **Select which eval to run:** tick e.g. `billing-support × v3` (+ a baseline
   column for the delta), or a shortcut row/column/corner to batch. Continuous
   dispatches that `(eval, variant)` Task to the worker, judges server-side, and
   rewrites the cell to `✓ pass [↗](trajectory)` / `✗ fail` with the score.
   - `billing-support` (`block_pr: true`) gates the merge; `escalation` (`block_pr: false`)
     is advisory.

**Expected:** v3 wins `billing-support` over v1/v2 (the skill earns its place);
`escalation` stays flat (the skill doesn't change escalation judgment). Merge
unblocks once the blocking cells pass. If a cell hangs "awaiting,"
the worker's `CONTINUOUS_GIT_SHA` ≠ the PR head SHA (queue mismatch).

---

## Demo C — CD: roll out v1 → v2, pause after two stages

Plan `ramp` is `10 → 25 → 50 → 100`, 30-minute bake; operator actions override the
bake (0004 §11). The plan name resolves against the registered **plan mirror**.

The **production app** here is the **simulator** — it asks `get_variant` and reports
trajectories, so it doesn't poll a queue (queue identity is irrelevant to Demo C) and
runs from either setup. Start it against `main` so it serves v1 (baseline) + v2
(candidate): `npm run simulate -- 40`.

```bash
continuous rollout start support-agent v2 --plan ramp     # stage 0 (10%), tails events
# second terminal, with the rol_ id printed:
continuous rollout advance rol_01HK...   # → stage 1 (25%)  [1/4]
continuous rollout advance rol_01HK...   # → stage 2 (50%)  [2/4]
continuous rollout pause   rol_01HK...   # hold at stage 2/4 (50%), paused
continuous rollout show    rol_01HK...
```

Paused at 50%, non-terminal — waits until `resume` / `rollback` / `cancel`. With the
**simulator** running, it drives candidate + baseline traffic and the Canary Agent
gates on real judgments; use `--plan ramp-fast` (2-minute bakes) to watch it
`advance`/`retreat`/`pause` on its own. Packaged: `just rollout` (then `just simulate-for 5m`).

---

## Demo D — Experiment: A/B v1 vs v2 on live traffic

A rollout is _asymmetric_ — one candidate ramping over one baseline. An **experiment**
is _symmetric_: it carves a fixed slice of production traffic and splits it across
≥2 variants, judging each independently against the rubric for a per-variant report.
It's the A/B test you reach for when you want to _compare_ compositions on real
traffic without promoting anything.

The lane is live the moment you create it: `getVariant` sends the slice into the
experiment lane (split per your weights) and leaves the rest on `main`. Same
production app as Demo C — the **simulator** — feeds it; keep it on `main` so the
catalog has v1+v2.

```bash
# Carve 40% of traffic, split 50/50 across v1 and v2; judged by evals/judge.md.
continuous experiment start support-agent \
  --slice 40 --variants v1=50,v2=50 --judge evals/judge.md --deadline 1h
# → prints exp_01HK…; the lane is already routing.

# Drive traffic and watch it split — the lane column shows `experiment` vs `main`:
npm run simulate -- 60                     # or: just simulate 60

continuous experiment show exp_01HK…       # per-variant report (n, success/fail rate)
continuous experiment list --agent support-agent
continuous experiment cancel exp_01HK…     # stop early (the deadline ends it anyway)
```

Packaged: `just experiment` (defaults to `--slice 40 --variants v1=50,v2=50`).

**Expected:** v2's `success_rate` clears v1's by a wide margin — the Sonnet,
policy-aware composition beats the Haiku baseline on the same tickets — and the two
variants carry roughly equal `n` (the 50/50 split). The other 60% of traffic stays
on `main` (v1), untouched.

---

## Demo E — Shadow: measure v2 against real traffic, zero user risk

**Shadow** is _try-before-you-buy_. It deterministically samples a fraction of
main-chunk (baseline `v1`) trajectories, **replays each sampled input through the
candidate** out of band — the user already got the baseline answer, so no one is
ever exposed to the candidate — judges both arms against one rubric, and emits a
**paired** baseline-vs-candidate report on identical requests.

Replays run the candidate _for real_ on the worker pool (hence `--confirm`), so
**keep `just worker` running** — it executes the replay tasks. The simulator
supplies the baseline traffic that gets sampled.

```bash
# Sample 50% of v1 traffic; replay through v2; judge both arms with evals/judge.md.
continuous shadow start support-agent \
  --candidates v2 --sample 50 --judge evals/judge.md --deadline 1h --confirm
# → prints shd_01HK… (+ a warning if no worker can serve a candidate yet).

# In another terminal (worker already up), drive baseline traffic to be sampled:
npm run simulate -- 60                     # or: just simulate 60

continuous shadow show shd_01HK…           # baseline arm + candidate arm + paired stat
continuous shadow list --agent support-agent
```

Packaged: `just shadow` (defaults to `--candidates v2 --sample 50`).

**Expected:** the paired block shows v2 winning most comparisons over the v1 baseline
on the _same_ tickets — `candidate_wins` ≫ `baseline_wins`, a positive
`mean_score_delta`. That's the evidence you'd gather _before_ ever starting the Demo C
rollout: shadow proves the candidate on live traffic at zero risk; the rollout then
promotes it.

---

## Where to watch

- **Runs / PR evals:** `https://dashboard-dev.continuouslabs.ai/w/<wsId>` → Runs, and
  the GitHub PR comment/check-run.
- **Rollouts:** the dashboard rollout view, or `continuous rollout show <rol_id>`.
- **Experiments:** the dashboard experiment view, or `continuous experiment show <exp_id>`.
- **Shadows:** the dashboard shadow view, or `continuous shadow show <shd_id>`.
- **Worker subscriptions + queue:** `continuous workers list`.

## Quick reference

| Thing         | Value                                                                                                              |
| ------------- | ------------------------------------------------------------------------------------------------------------------ |
| Platform      | dev — `api-dev` / `dashboard-dev` .continuouslabs.ai (real GitHub App)                                             |
| Run the app   | `tilt up` (this repo); `git_sha` defaults to `HEAD`                                                                |
| Worker key    | dashboard → Admin → Worker API keys (shown once on mint)                                                           |
| Operator auth | `continuous login`                                                                                                 |
| Worker queue  | `sha:<git_sha>` (Tilt deployment) — match the PR head SHA for CI                                                   |
| Rollout plan  | `ramp` = 10/25/50/100 (bake 30m); `ramp-fast` = 2m bakes                                                           |
| Experiment    | `continuous experiment start support-agent --slice 40 --variants v1=50,v2=50 --judge evals/judge.md --deadline 1h` |
| Shadow        | `continuous shadow start support-agent --candidates v2 --sample 50 --judge evals/judge.md --deadline 1h --confirm` |
| v3 PR branch  | `add-v3-billing-skill` (pre-staged; open it for Demo B)                                                            |
| Recipes       | `just --list` — `eval` / `pr` / `rollout` / `experiment` / `shadow`, `worker` + `simulate`                         |
