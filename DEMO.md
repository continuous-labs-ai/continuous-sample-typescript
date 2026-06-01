# Demo runbook — Continuous end-to-end (TypeScript sample)

This is the operator runbook **and** the implementation plan for taking the Acme
billing-support agent through Continuous end-to-end against the **dev** stack. A
Python twin lives in `continuous-sample-python/DEMO.md` — same flow, mirror-image
commands.

We demo three things:

1. **Eval-as-code** — author evals (dataset + judge + config) that score each variant.
2. **CI, on-demand dispatch** — open a PR that adds a candidate variant (v3 + the
   `billing-policy` skill); Continuous posts a PR comment with an **eval × variant
   checkbox table**; you tick *which eval(s)* to run; scores come back inline and
   gate the merge.
3. **CD, staged rollout** — promote v2 over the v1 baseline through a
   `10 → 25 → 50 → 100` ramp and **pause after 2 of 4 stages**.

> Status: the repo is pre-staged for this but **not yet wired for on-demand
> dispatch or the second eval** — see [Step 0](#step-0--repo-changes-to-land-first).
> Land those, then run the demo.

---

## The cast (variants)

| Variant | Model | Prompt | Skill | Role in the demo |
| ------- | ----- | ------ | ----- | ---------------- |
| **v1** | Haiku 4.5 | terse, generic | — | weak baseline / `main_variant` |
| **v2** | Sonnet 4.6 | policy-aware | — | **CD candidate** (rollout v1 → v2) |
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
| A Continuous **workspace** for the org | Sign in at <https://dashboard-dev.continuouslabs.ai> with a GitHub account that belongs to `continuous-labs-ai`; sign-in provisions the workspace. Dev workspace so far: `ws_01KSY1HJ4XSPD1JQESEBXECTY7` (confirm in the dashboard). | ✅ |
| A **Worker API key** (`ck_…`) | Dashboard → workspace → **Admin → Worker API keys** (`/w/<wsId>/admin/tokens`) → **Mint**. Shown once — copy it. | ⬜ mint |
| **Variant catalog registered** (`main_variant=v1`, variants `v1,v2`, evals) | Registers automatically when a push to `main` touches `.continuous/config.yml` (0004 §15.2). The app was installed *after* the repo's initial commits, so this hasn't fired yet — landing [Step 0](#step-0--repo-changes-to-land-first) is the push that registers it. Verify in the dashboard the `support-agent` shows v1/v2 with **main = v1**. | ⬜ |

### B. Local (per operator)

- **The `continuous` CLI** — build from the monorepo and put on `PATH`:
  ```bash
  # in a checkout of continuous-labs-ai/continuous
  go build -o continuous ./cli/cmd/continuous
  ```
- **`ANTHROPIC_API_KEY`** — the Claude Agent SDK spawns Claude Code, which calls
  Anthropic. The worker can't run a variant without it.
- **`git`** + **`gh`** — to open the PR.
- **Node ≥ 18** + **`npm`**. The Continuous SDK is a **`file:../continuous/sdk/typescript`**
  dependency, so **clone the monorepo as a sibling `../continuous`** before
  `npm install`:
  ```text
  ~/src/continuous/                      # the monorepo (continuous-labs-ai/continuous)
  ~/src/continuous-sample-typescript/    # this repo, sibling of it
  ```

### C. Two credentials — don't conflate them

| Who | Credential | Used by |
| --- | ---------- | ------- |
| **Operator** (you) | sealed session from `continuous login` (browser handshake → `~/.config/continuous/credentials.toml`) | `continuous eval`, `continuous rollout`, `continuous runs/logs/workers` |
| **Worker** (the agent process) | `CONTINUOUS_API_KEY=ck_…` (the worker key minted above) | `npm run worker` / `npm run simulate` |

### D. Environment (every shell)

```bash
export CONTINUOUS_API_URL=https://api-dev.continuouslabs.ai
export CONTINUOUS_DASHBOARD_URL=https://dashboard-dev.continuouslabs.ai
export CONTINUOUS_API_KEY=ck_...        # worker key (worker/simulator only)
export ANTHROPIC_API_KEY=sk-ant-...
# then, once, for operator commands:
continuous login                        # opens the dev dashboard handshake
```

---

## Step 0 — Repo changes to land first (implementation plan)

A fresh session implements these on `main` **before** the demo. They're the only
gap between today's repo and the demo above. **Mirror them in the Python twin too.**

1. **Switch evals to on-demand dispatch.** In `.continuous/config.yml`, change the
   `billing-support` eval from `dispatch: auto` to **`dispatch: on-demand`** (or
   delete the line — on-demand is the spec default, 0002 §5). This is what makes the
   PR comment render the **checkbox selector** instead of auto-running everything.

2. **Add a second eval so "select which eval" is real.** Today there's one eval, so
   the PR comment can only offer variant columns. Add a small, *advisory* second
   eval — proposed **`tone`** — so the comment shows a **2-eval × 3-variant** grid:

   - `evals/tone.jsonl` — a handful of rows scoring empathy / clarity /
     professionalism, **not** policy specifics (so it's not skill-sensitive and
     stays roughly flat v1→v3, contrasting with `billing-support` which jumps on v3):
     ```json
     {"name": "apology-outage", "input": "Your app was down for an hour during our launch. Not happy.", "expected_output": "Acknowledge the impact, apologize sincerely without being defensive, and offer a concrete next step (status follow-up or escalation). Empathy first, specifics second."}
     {"name": "jargon-free", "input": "I don't understand what 'proration' means on my invoice.", "expected_output": "Explain proration in plain language with a short concrete example, no jargon, then offer to apply it to their invoice."}
     {"name": "firm-but-kind", "input": "Just give me a refund or I'm leaving.", "expected_output": "Stay calm and respectful, restate willingness to help, and explain options clearly without capitulating to a policy that doesn't apply — firmness with empathy."}
     {"name": "greeting-clarity", "input": "hi, I have a question about my account", "expected_output": "A warm, professional opening that invites the specific question and signals readiness to help, without guessing the issue."}
     ```
   - `evals/tone-judge.md` — a short rubric scoring tone only (empathy, clarity,
     professionalism) on `[0.0, 1.0]`, independent of policy correctness.
   - In `.continuous/config.yml`, add the eval (advisory → does **not** block merge):
     ```yaml
     - name: tone
       agent: support-agent
       dataset: evals/tone.jsonl
       judge: evals/tone-judge.md
       on: change
       dispatch: on-demand
       block_pr: false
     ```
   Keep `billing-support` as `block_pr: true` so the merge gate is the policy eval.

3. **Push `main`** → registers the catalog (`main_variant=v1`; variants v1,v2;
   evals billing-support, tone). Confirm in the dashboard.

4. **Rebase the v3 branch.** `add-v3-billing-skill` was branched from the *old*
   main, so its `config.yml` only adds the v3 variant. Rebase it onto the new main
   (which now carries on-demand + the `tone` eval) and force-push, so the eventual
   PR diff is **just the v3 variant + skill** — not a config regression.

**Implementation checklist**

- [ ] `billing-support` → `dispatch: on-demand` in `.continuous/config.yml`
- [ ] `evals/tone.jsonl` + `evals/tone-judge.md` authored
- [ ] `tone` eval added to `.continuous/config.yml` (`on-demand`, `block_pr: false`)
- [ ] Mirror all of the above into `continuous-sample-python`
- [ ] Push `main` (both repos); confirm catalog registered in dashboard
- [ ] Rebase `add-v3-billing-skill` onto new main (both repos) and force-push
- [ ] Mint a worker key; bring a worker up (Step 1) and confirm it subscribes

---

## Step 1 — Bring up a worker (required for CI scores + CD traffic)

The worker runs **its own local files** — the server only sends a `variant` name and
the input. So **v3 only behaves correctly (reads the skill) when the worker is
running from the v3 checkout.** Run the worker on the `add-v3-billing-skill` branch:

```bash
git fetch origin
git checkout add-v3-billing-skill      # config now declares v1, v2, v3
npm install                            # resolves @continuous/sdk from ../continuous
npm run worker
# -> support-agent worker up: agent=support-agent variants=[ 'v1', 'v2', 'v3' ]
```

Leave it running. Open PRs / run operator commands from a *separate* clone or the
monorepo so this checkout stays on the v3 branch.

---

## Demo A — Create an eval

The "eval" surface is three files, all versioned with the agent:

- `evals/support.jsonl` — dataset rows `{ name, input, expected_output }`.
- `evals/judge.md` — the rubric (Continuous scores the trajectory against it, `[0,1]`).
- `.continuous/config.yml` `evals:` entry — binds dataset + judge + agent and sets
  `on` (when it runs), `dispatch` (auto vs on-demand), `block_pr` (merge gate).

Run one without any PR — a **Local Run** that uses your running worker:

```bash
continuous eval billing-support        # pushes a temp ref, dispatches, tails SSE to terminal
continuous eval                        # no name → every declared eval
```

This is the "author an eval and see it score the agent" story; `evals/tone.*` added
in Step 0 is a second worked example of authoring one.

---

## Demo B — CI: open the v3 PR, dispatch on demand, pick the eval

With a worker up (Step 1):

```bash
gh pr create --base main --head add-v3-billing-skill \
  --title "Add v3: billing-policy skill" --fill
```

Continuous posts a **check-run** + a **PR comment**. The comment renders one table
per agent — **rows = evals (`billing-support`, `tone`), columns = variants
(v1, v2, v3)** — each cell a checkbox backed by a marker
`<!-- continuous:dispatch:<eval>:<variant> -->` (0002 §7). Nothing runs until you
tick something.

**Select which eval to run:** tick e.g. `billing-support × v3` (and the baseline
column if you want the delta), or use the shortcut row/column/corner cell to
batch-dispatch. GitHub re-renders the comment; Continuous detects the flipped
checkbox, dispatches that `(eval, variant)` Task to your worker, judges the result
server-side, and rewrites the cell to `✓ pass [↗](trajectory)` / `✗ fail` with the
score.

- `billing-support` is `block_pr: true` → the check-run gates the merge on the
  dispatched billing-support cells.
- `tone` is `block_pr: false` → advisory, never blocks.

**Expected story:** v3 wins `billing-support` over v1/v2 (the skill earns its place —
v1/v2 invent a plausible-but-wrong refund window, v3 reads Acme's real policy),
while `tone` stays flat across variants. Merge unblocks once the blocking cells pass.

**No GitHub App? (fallback)** Dispatch the same eval from your laptop against the
running worker, no PR required: `continuous eval billing-support`.

---

## Demo C — CD: roll out v1 → v2, pause after two stages

Plan `ramp` (in `.continuous/rollouts.yml`) is `10 → 25 → 50 → 100`, 30-minute bake
per stage. Operator actions override a pending bake (0004 §11), so the manual walk
doesn't wait on the timer.

```bash
# baseline = current main (v1), candidate = v2. Enters stage 0 (10%) and tails events.
continuous rollout start support-agent v2 --plan ramp
#   Started rol_01HK...  Watch: continuous rollout show rol_01HK...

# from a second terminal, with the rol_ id printed above:
continuous rollout advance rol_01HK...   # stage 0 -> 1 (25%)   [1/4]
continuous rollout advance rol_01HK...   # stage 1 -> 2 (50%)   [2/4]
continuous rollout pause   rol_01HK...   # hold at stage 2/4 (50%), status = paused

continuous rollout show rol_01HK...
#   Rollout rol_01HK... — paused (stage 2/4)  v1 -> v2
```

It now sits **paused at 50%**, non-terminal — it waits indefinitely until you
`continuous rollout resume` (continue the ramp), `rollback` (to v1), or `cancel`.
A worker is **not** required for the manual advance/pause walk (you're driving the
state machine), but with no traffic there are no candidate judgments.

**Variant — autonomous canary.** To watch the **Canary Agent** gate on real traffic
instead of driving by hand, use the fast plan and feed it production trajectories
(needs the worker up, Step 1):

```bash
continuous rollout start support-agent v2 --plan ramp-fast   # 2-minute bakes
npm run simulate -- 40                                       # live traffic -> candidate + baseline
```

At each stage gate the canary compares candidate vs baseline judgments and emits
`advance`, `retreat`, or `pause` on its own.

---

## Where to watch

- **Runs / PR evals:** `https://dashboard-dev.continuouslabs.ai/w/<wsId>` → Runs,
  and the GitHub PR comment/check-run.
- **Rollouts:** the dashboard rollout view, or `continuous rollout show <rol_id>`.
- **Worker subscriptions:** `continuous workers list`.

## Quick reference

| Thing | Value |
| ----- | ----- |
| API (dev) | `https://api-dev.continuouslabs.ai` |
| Dashboard (dev) | `https://dashboard-dev.continuouslabs.ai` |
| GitHub App | `continuous-ci-dev` on `continuous-labs-ai` |
| Worker key | dashboard → Admin → Worker API keys (`ck_…`) |
| Operator auth | `continuous login` |
| Rollout plan | `ramp` = 10/25/50/100 (bake 30m); `ramp-fast` = same stages, 2m bakes |
| v3 PR branch | `add-v3-billing-skill` (pre-staged; open it to run Demo B) |
