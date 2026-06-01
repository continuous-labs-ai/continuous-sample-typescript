# Demo runbook — Continuous end-to-end (TypeScript sample)

This is the operator runbook **and** the implementation plan for taking the Acme
billing-support agent through Continuous end-to-end against the **dev** stack. A
Python twin lives in `continuous-sample-python/DEMO.md` — same flow, mirror-image
commands.

We demo three flows, **all runnable** once this repo ships its own Tilt stack
(below):

1. **Eval-as-code** — author evals (dataset + judge + config) that score each variant.
2. **CI, on-demand dispatch** — open a PR that adds a candidate variant (v3 + the
   `billing-policy` skill); Continuous posts a PR comment with an **eval × variant
   checkbox table**; you tick *which eval(s)* to run; scores come back inline and
   gate the merge.
3. **CD, staged rollout** — promote v2 over the v1 baseline through a
   `10 → 25 → 50 → 100` ramp and **pause after 2 of 4 stages**, with the simulator
   feeding live traffic so the canary gates for real.

> Status: pre-staged but **not yet built** — see
> [Step 0](#step-0--what-to-build-first). Land those, then run the demo.

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

- **On the host** = *local development* (`user:@host` queue) — what the
  `continuous eval` CLI matches. **Enables Demo A.**
- **In Tilt** = a *preview/production deployment* (`sha:<git_sha>` queue, pinned to a
  commit just like a Vercel/Railway/Fly preview) — what a PR Run matches. **Enables
  Demo B.** The CD simulator (Demo C) also lives here as the production app.

---

## The cast (variants)

| Variant | Model | Prompt | Skill | Role in the demo |
| ------- | ----- | ------ | ----- | ---------------- |
| **v1** | Haiku 4.5 (`claude-haiku-4-5-20251001`) | terse, generic | — | weak baseline / `main_variant` |
| **v2** | Sonnet 4.6 (`claude-sonnet-4-6`) | policy-aware | — | **CD candidate** (rollout v1 → v2) |
| **v3** | Sonnet 4.6 | same as v2 | **`billing-policy`** | **CI candidate** (the PR) |

`main` declares **v1 + v2**. Branch **`add-v3-billing-skill`** is pre-pushed and
adds v3 + the skill; its **PR is intentionally not open yet** — opening it *is* the
CI demo.

---

## Prerequisites

### A. Platform (one-time, dev)

| Requirement | How / where | Status |
| ----------- | ----------- | ------ |
| GitHub App **`continuous-ci-dev`** installed on the **`continuous-labs-ai`** org | <https://github.com/apps/continuous-ci-dev/installations/new> | ✅ installed |
| A Continuous **workspace** for the org | Sign in at <https://dashboard-dev.continuouslabs.ai> with a GitHub account that belongs to `continuous-labs-ai`; sign-in provisions the workspace. Note the **workspace id** from the URL (`/w/<wsId>`); the one used so far is `ws_01KSY1HJ4XSPD1JQESEBXECTY7`. | ✅ |
| A **Worker API key** | Dashboard → workspace → **Admin → Worker API keys** (`/w/<wsId>/admin/tokens`) → **Mint**. It's a WorkOS org API key; the full value is **shown once** on mint — copy it. (`.env.example` uses `ck_…` as a placeholder; use whatever the dashboard shows.) | ⬜ mint |
| **Variant catalog + plan mirror registered** | Both register when a push to `main` touches `.continuous/config.yml` **or** `.continuous/rollouts.yml` (0004 §15.2): the server reads both files at that SHA and upserts the variant catalog (`main_variant=v1`, variants `v1,v2`) and the plan mirror (`ramp`, `ramp-fast`). The app was installed *after* the repo's initial commits, so this hasn't fired — landing [Step 0](#step-0--what-to-build-first) is the push that registers it. Verify in the dashboard the `support-agent` shows v1/v2 with **main = v1**. | ⬜ |

### B. Local toolchain (per operator)

- **Docker** + **Tilt** — to run this repo's worker/simulator stack.
- **The `continuous` CLI** — build from the monorepo (**Go 1.26+**) and put on `PATH`:
  ```bash
  go build -o continuous ./cli/cmd/continuous   # in a checkout of continuous-labs-ai/continuous
  ```
- **`ANTHROPIC_API_KEY`** — the Claude Agent SDK spawns Claude Code (a subprocess)
  that calls Anthropic; the key needs access to **Haiku 4.5 and Sonnet 4.6**.
- **`git`** + **`gh`**, with `gh` authenticated for `continuous-labs-ai` (`gh auth status`).
- **Node ≥ 18** (only if running the worker on the host instead of in Tilt). The SDK
  is a **`file:../continuous/sdk/typescript`** dependency, so a host run needs the
  monorepo cloned as a sibling `../continuous`. (For the container, see Step 0.2.)

### C. Two credentials — don't conflate them

| Who | Credential | Used by |
| --- | ---------- | ------- |
| **Operator** (you) | sealed session from `continuous login` (browser handshake → `~/.config/continuous/credentials.toml`) | `continuous eval`, `continuous rollout`, `continuous runs/logs/workers` |
| **Worker** (the Tilt deployment) | the worker key (`CONTINUOUS_API_KEY=…`) | the worker + simulator containers |

### D. Queue identity

A worker only receives Tasks whose **`queue` string matches its own** (0003 §6.3),
auto-derived (never declared):

| Regime | Queue string | When |
| ------ | ------------ | ---- |
| **Deployed** | `sha:<git_commit_sha>` | `CONTINUOUS_GIT_SHA` set (the Tilt worker sets this) |
| **Local** | `user:<username>@<hostname>` | no `CONTINUOUS_GIT_SHA` (host-run worker) |

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

## Step 0 — What to build first (implementation plan)

A fresh session lands these. Two parts: the **config changes** (on `main`) and the
**Tilt stack** (new files in this repo).

### 0.1 Config: on-demand dispatch + a second eval

1. **Switch evals to on-demand dispatch.** In `.continuous/config.yml`, change
   `billing-support` from `dispatch: auto` to **`dispatch: on-demand`** (or drop the
   line — on-demand is the spec default, 0002 §5). This makes the PR comment render
   the **checkbox selector** instead of auto-running everything.

2. **Add a second, advisory eval so "select which eval" is real** — proposed
   **`tone`** — giving the PR comment a **2-eval × 3-variant** grid:

   - `evals/tone.jsonl` — rows scoring empathy / clarity / professionalism, **not**
     policy specifics (so it's not skill-sensitive and stays flat v1→v3, unlike
     `billing-support` which jumps on v3):
     ```json
     {"name": "apology-outage", "input": "Your app was down for an hour during our launch. Not happy.", "expected_output": "Acknowledge the impact, apologize sincerely without being defensive, and offer a concrete next step. Empathy first, specifics second."}
     {"name": "jargon-free", "input": "I don't understand what 'proration' means on my invoice.", "expected_output": "Explain proration in plain language with a short concrete example, no jargon, then offer to apply it to their invoice."}
     {"name": "firm-but-kind", "input": "Just give me a refund or I'm leaving.", "expected_output": "Stay calm and respectful, restate willingness to help, and explain options clearly without capitulating to a policy that doesn't apply."}
     {"name": "greeting-clarity", "input": "hi, I have a question about my account", "expected_output": "A warm, professional opening that invites the specific question, without guessing the issue."}
     ```
   - `evals/tone-judge.md` — a short rubric scoring tone only on `[0.0, 1.0]`.
   - In `.continuous/config.yml` (advisory → does **not** block merge):
     ```yaml
     - name: tone
       agent: support-agent
       dataset: evals/tone.jsonl
       judge: evals/tone-judge.md
       on: change
       dispatch: on-demand
       block_pr: false
     ```
   Keep `billing-support` as `block_pr: true`.

3. **Push `main`** → registers the variant catalog **and** the plan mirror. Verify in
   the dashboard.

4. **Rebase `add-v3-billing-skill`** onto the new main and force-push, so the PR diff
   stays **v3 variant + skill only**.

### 0.2 The Tilt stack (new files in this repo)

This packages **Setup 2** — the agent as a production-like container pinned to a
commit (the preview/production regime). **Setup 1** (local dev) needs no new files —
it's just `npm run worker` on the host. Add:

- **`Dockerfile`** — installs deps and runs the worker. Two wrinkles to solve in the
  build:
  - ⚠️ **SDK resolution.** `@continuous/sdk` is a `file:../continuous/...` dependency,
    which is **outside this repo's build context**. Either expand the Docker build
    context to the parent dir (monorepo + sample), `npm pack` the SDK and vendor the
    tarball, or switch to the published `@continuous/sdk` once it's on npm.
  - ⚠️ **Claude Code runtime.** The Agent SDK spawns the Claude Code engine — make
    sure its CLI is present in the image (Node is the base, but verify the engine
    resolves).
  ```dockerfile
  FROM node:22-slim
  WORKDIR /app
  COPY . .
  RUN npm install --omit=dev      # see SDK-resolution note above
  CMD ["npm", "run", "worker"]
  ```
- **`docker-compose.yml`** — a `worker` service (and a `simulate` service, profile
  `cd`), passing `CONTINUOUS_API_URL`, `CONTINUOUS_API_KEY`, `ANTHROPIC_API_KEY`, and
  `CONTINUOUS_GIT_SHA` through from the environment.
- **`Tiltfile`** — parameterize the deploy SHA:
  ```python
  config.define_string('git_sha')
  cfg = config.parse()
  git_sha = cfg.get('git_sha', str(local('git rev-parse HEAD')).strip())
  docker_compose('./docker-compose.yml')
  # inject CONTINUOUS_GIT_SHA=git_sha into the worker/simulate services
  dc_resource('worker', labels=['agent'])
  dc_resource('simulate', labels=['agent'])   # CD only; start on demand
  ```

**Implementation checklist**

- [ ] `billing-support` → `dispatch: on-demand`; author `evals/tone.*`; add `tone` eval
- [ ] `Dockerfile` (worker; **SDK resolution + Claude Code runtime** solved), `docker-compose.yml`, `Tiltfile`
- [ ] Mirror all of the above into `continuous-sample-python`
- [ ] Push `main` (both repos); confirm catalog **and** plan mirror registered
- [ ] Rebase `add-v3-billing-skill` onto new main (both) and force-push
- [ ] Mint a worker key; `tilt up` and confirm the worker subscribes ([v1,v2] on main; [v1,v2,v3] on the v3 branch)

---

## Step 1 — Two ways to run the agent

The agent runs **its own local files** — the server sends only a `variant` name +
input — so the checkout you run determines what each variant does (v3 reads the skill
only when v3's files are present). The two setups differ only in **queue regime**:

| Setup | How | Queue | Simulates | Drives |
| ----- | --- | ----- | --------- | ------ |
| **1. Local dev** | `npm run worker` on the host, `CONTINUOUS_GIT_SHA` **unset** | `user:<you>@<host>` | a developer iterating locally | **Demo A** (`continuous eval`) |
| **2. Preview** | `tilt up` on the PR checkout (`git_sha` = head SHA) | `sha:<head_sha>` | a per-PR preview deployment | **Demo B** (GitHub PR) |

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

`evals/tone.*` from Step 0 is a second worked example of authoring one.

---

## Demo B — CI: open the v3 PR, dispatch on demand, pick the eval

1. **Bring up the preview env** (Step 1, Setup 2 — `tilt up` on the v3 branch) →
   worker on `sha:<head_sha>`, variants `[v1,v2,v3]`.
2. **Open the PR:**
   ```bash
   gh pr create --base main --head add-v3-billing-skill --title "Add v3: billing-policy skill" --fill
   ```
3. Continuous posts a **check-run** + a **PR comment**: one table per agent —
   **rows = evals (`billing-support`, `tone`), columns = variants (v1,v2,v3)** — each
   cell a checkbox `<!-- continuous:dispatch:<eval>:<variant> -->` (0002 §7). Nothing
   runs until you tick.
4. **Select which eval to run:** tick e.g. `billing-support × v3` (+ a baseline
   column for the delta), or a shortcut row/column/corner to batch. Continuous
   dispatches that `(eval, variant)` Task to the worker, judges server-side, and
   rewrites the cell to `✓ pass [↗](trajectory)` / `✗ fail` with the score.
   - `billing-support` (`block_pr: true`) gates the merge; `tone` (`block_pr: false`)
     is advisory.

**Expected:** v3 wins `billing-support` over v1/v2 (the skill earns its place); `tone`
stays flat. Merge unblocks once the blocking cells pass. If a cell hangs "awaiting,"
the worker's `CONTINUOUS_GIT_SHA` ≠ the PR head SHA (queue mismatch).

---

## Demo C — CD: roll out v1 → v2, pause after two stages

Plan `ramp` is `10 → 25 → 50 → 100`, 30-minute bake; operator actions override the
bake (0004 §11). The plan name resolves against the **plan mirror** from Step 0.

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
`advance`/`retreat`/`pause` on its own.

---

## Where to watch

- **Runs / PR evals:** `https://dashboard-dev.continuouslabs.ai/w/<wsId>` → Runs, and
  the GitHub PR comment/check-run.
- **Rollouts:** the dashboard rollout view, or `continuous rollout show <rol_id>`.
- **Worker subscriptions + queue:** `continuous workers list`.

## Quick reference

| Thing | Value |
| ----- | ----- |
| Platform | dev — `api-dev` / `dashboard-dev` .continuouslabs.ai (real GitHub App) |
| Run the app | `tilt up` (this repo); `git_sha` defaults to `HEAD` |
| Worker key | dashboard → Admin → Worker API keys (shown once on mint) |
| Operator auth | `continuous login` |
| Worker queue | `sha:<git_sha>` (Tilt deployment) — match the PR head SHA for CI |
| Rollout plan | `ramp` = 10/25/50/100 (bake 30m); `ramp-fast` = 2m bakes |
| v3 PR branch | `add-v3-billing-skill` (pre-staged; open it for Demo B) |
