# Acme billing-support agent — demo runbook, packaged (TypeScript twin).
#
# `just` recipes for the five demo flows, covering the four post-merge Continuous
# features: eval (A/B), rollout (C), experiment (D), shadow (E). Defaults target a
# live run; override any argument.
#
# Prereqs (see DEMO.md): the `continuous` CLI + `gh` on PATH, `continuous login`
# done, `npm install`, and a .env with CONTINUOUS_API_KEY / CONTINUOUS_API_URL /
# ANTHROPIC_API_KEY (auto-loaded). Keep `just worker` running in one terminal and
# `just simulate` in another while driving Demos C/D/E.

set dotenv-load := true

agent := "support-agent"
judge := "evals/judge.md"

# List the recipes.
default:
    @just --list --unsorted

# --- the running agent + its traffic ----------------------------------------

# Setup 1: host worker — serves the declared variants on queue user:<you>@<host>.
# Also handles shadow replay tasks, so keep it up during Demo E.
worker:
    npm run worker

# Production traffic — real agent calls via getVariant + reportTrajectory.
# Feeds the canary (C), the experiment lanes (D), and shadow sampling (E).
#   just simulate 60
#   just simulate-for 5m
simulate count="30":
    npm run simulate -- {{count}}

# Drive traffic for a wall-clock duration instead of a fixed count.
simulate-for duration="5m" concurrency="4":
    npm run simulate -- --duration {{duration}} --concurrency {{concurrency}}

# --- the four features -------------------------------------------------------

# Demo A — eval-as-code: score every variant locally (no PR). Omit name for all.
eval name="billing-support":
    continuous eval {{name}}

# Demo B — CI: open the pre-staged v3 PR; tick the eval×variant cells in the PR comment.
pr:
    gh pr create --base main --head add-v3-billing-skill \
      --title "Add v3: billing-policy skill" -F .github/PR_BODY_v3.md

# Demo C — CD rollout v1 → v2. Pair with `just simulate-for` so the canary gates on
# real traffic. `ramp-fast` (2m bakes) lets it advance/retreat on its own.
rollout candidate="v2" plan="ramp-fast":
    continuous rollout start {{agent}} {{candidate}} --plan {{plan}}

# Demo D — A/B experiment: carve a traffic slice and split it across variants.
# Watch the split land in the experiment lane via `just simulate`, then
# `continuous experiment show <id>` for the per-variant report.
experiment slice="40" variants="v1=50,v2=50" deadline="1h":
    continuous experiment start {{agent}} --slice {{slice}} --variants {{variants}} \
      --judge {{judge}} --deadline {{deadline}}

# Demo E — shadow: sample main-chunk (v1) traffic and replay it through the
# candidate out of band. Needs `just worker` running to execute the replays.
# `continuous shadow show <id>` prints the baseline-vs-candidate paired report.
shadow candidates="v2" sample="50" deadline="1h":
    continuous shadow start {{agent}} --candidates {{candidates}} --sample {{sample}} \
      --judge {{judge}} --deadline {{deadline}} --confirm

# --- operator helpers --------------------------------------------------------

# One-time operator auth (browser handshake).
login:
    continuous login

# Worker subscriptions + their queue identity (diagnose "awaiting" cells).
workers:
    continuous workers list
