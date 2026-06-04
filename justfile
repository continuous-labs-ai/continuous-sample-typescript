# Acme billing-support agent — demo runbook, packaged (TypeScript twin).
#
# One `just` recipe per flow, each covering a Continuous feature: eval (A), CI (B),
# rollout (C), experiment (D), shadow (E). The C/D/E recipes start the flow AND
# drive the production traffic it needs, then print the report — no second command.
#
# Prereqs (see VALIDATION.md): the `continuous` CLI + `gh` on PATH, `continuous login`
# done, `npm install`, and a .env with CONTINUOUS_API_KEY / CONTINUOUS_API_URL /
# ANTHROPIC_API_KEY (auto-loaded). Keep `just worker` running in one terminal for
# eval (A) and shadow (E).

set dotenv-load := true

agent := "support-agent-ts"
judge := "evals/support-judge.md"

# List the recipes.
default:
    @just --list --unsorted

# --- the running agent -------------------------------------------------------

# Host worker — serves every declared variant on queue user:<you>@<host>.
# Required for eval (A) and shadow (E). Keep it running in its own terminal.
worker:
    npm run worker

# CI worker — serves the PR-head queue (sha:<HEAD>). Run from a checkout of the
# PR branch so a PR Run's dispatched eval cells have a worker to claim them.
ci-worker:
    CONTINUOUS_GIT_SHA="$(git rev-parse HEAD)" npm run worker

# Standalone production traffic (the C/D/E recipes drive this for you).
#   just simulate 60          # fixed count
#   just traffic 5m           # wall-clock duration
simulate count="30":
    npm run simulate -- {{count}}

traffic duration="5m" concurrency="4":
    npm run simulate -- --duration {{duration}} --concurrency {{concurrency}}

# --- the five flows ----------------------------------------------------------

# A — eval-as-code: score every variant locally (no PR). Needs `just worker`.
eval name="billing-support":
    continuous eval {{name}}

# B — CI: open the pre-staged v3 PR. Run `just ci-worker` from the PR branch first;
# Continuous posts the eval×variant comment (escalation auto-runs; tick billing-support).
pr:
    gh pr create --base main --head add-v3-billing-skill \
      --title "Add v3: billing-policy skill" -F .github/PR_BODY_v3.md

# C — CD rollout v1 → v2, driving live canary traffic, then the rollout status.
rollout candidate="v2" plan="ramp-fast" traffic="40":
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(continuous rollout start {{agent}} {{candidate}} --plan {{plan}}); echo "$out"
    id=$(echo "$out" | sed -n 's/^Started \([^ .]*\).*/\1/p')
    npm run simulate -- {{traffic}}
    continuous rollout show "$id"

# D — experiment: split a traffic slice across variants, drive traffic, show the report.
experiment slice="40" variants="v1=50,v2=50" deadline="1h" traffic="40":
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(continuous experiment start {{agent}} --slice {{slice}} --variants {{variants}} --judge {{judge}} --deadline {{deadline}}); echo "$out"
    id=$(echo "$out" | sed -n 's/^Started \([^ .]*\).*/\1/p')
    npm run simulate -- {{traffic}}
    continuous experiment show "$id"

# E — shadow: sample v1 traffic, replay through the candidate out of band, show the
# paired report. Needs `just worker` running (it executes the replays).
shadow candidates="v2" sample="100" deadline="1h" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(continuous shadow start {{agent}} --candidates {{candidates}} --sample {{sample}} --judge {{judge}} --deadline {{deadline}} --confirm); echo "$out"
    id=$(echo "$out" | sed -n 's/^Started \([^ .]*\).*/\1/p')
    npm run simulate -- {{traffic}}
    echo "↻ replays land over a few minutes — re-run for the full report:"
    echo "    continuous shadow show $id"
    continuous shadow show "$id"

# --- operator helpers --------------------------------------------------------

# One-time operator auth (browser handshake).
login:
    continuous login

# Worker subscriptions + their queue identity (diagnose "awaiting" cells).
workers:
    continuous workers list

# Reset the demo org — cancel + delete all runs/rollouts/experiments/shadows and
# close the v3 PR (keeps the org + install). Needs `continuous login` + gh + python3.
clean:
    ./clean.sh
