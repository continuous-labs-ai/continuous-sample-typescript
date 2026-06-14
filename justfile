# Acme billing-support agent — demo runbook, packaged (TypeScript twin).
#
# One `just` recipe per flow, each covering a Continuous feature: eval (A), CI (B),
# replay (C), shadow (D), monitor (E). The C/D/E recipes drive the production
# traffic the flow needs, then print the report or a watch hint — no second command.
#
# Prereqs (see DEMO.md): the `continuous` CLI + `gh` on PATH, `continuous login`
# done, `npm install`, and a .env with CONTINUOUS_API_KEY / CONTINUOUS_API_URL /
# ANTHROPIC_API_KEY (auto-loaded; ANTHROPIC_API_KEY also feeds the SDK's rubric
# judge unless CONTINUOUS_JUDGE_API_KEY / _BASE_URL / _MODEL override it). Keep
# `just worker` running in one terminal — it serves dispatched eval tasks,
# replayed rows, shadow mirrors, and monitor probes.

set dotenv-load := true

agent := "support-agent-ts"
judge := "evals/support-judge.md"

# List the recipes.
default:
    @just --list --unsorted

# --- the running agent -------------------------------------------------------

# Host worker — serves every declared variant on queue user:<you>@<host>.
# Required for eval (A), replay (C), shadow (D), and monitor (E) — it executes
# the dispatched tasks, mirrors, and probes. Keep it running in its own terminal.
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

# C — replay: launch a replay Run that re-runs recorded production INPUT over a
# trailing window, judging each fresh run against the rubric.
# Drives traffic first so the window has rows; needs `just worker`.
replay window="24h" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    npm run simulate -- {{traffic}}
    continuous replay {{agent}} --window {{window}} --judge {{judge}}

# C2 — replay set: freeze a draw of recorded traffic as a named, PII-scrubbed
# set (a re-runnable benchmark), then replay against it. Needs `just worker`.
replay-set name="" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{name}}"; [ -n "$name" ] || name="frozen-$(date -u +%Y%m%d-%H%M%S)"
    npm run simulate -- {{traffic}}
    from=$(date -u -v-7d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ')
    to=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    continuous replay-set create "$name" --agent {{agent}} --from "$from" --to "$to" --scrub-pii
    continuous replay {{agent}} --set "$name" --judge {{judge}}

# D — shadow: sample v1 traffic, mirror it through the candidate out of band, show
# the paired report. Needs `just worker` running (it executes the mirrors).
shadow name="shadow-v2" candidates="v2" sample="100" deadline="1h" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(continuous shadow start {{agent}} --name {{name}} --candidates {{candidates}} --sample {{sample}} --judge {{judge}} --deadline {{deadline}} --confirm); echo "$out"
    id=$(echo "$out" | sed -n 's/^Started \([^ .]*\).*/\1/p')
    npm run simulate -- {{traffic}}
    echo "↻ mirrors land over a few minutes — re-run for the full report:"
    echo "    continuous shadow show $id"
    continuous shadow show "$id"

# E — monitor: hold one composition and re-score it per period over recorded
# traffic. Drives traffic, creates the monitor, backfills the last day so points
# cover that traffic, prints the series. Needs `just worker` (it executes the
# probes).
monitor variant="v1" period="1h" limit="10" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    npm run simulate -- {{traffic}}
    out=$(continuous monitor create {{agent}} --variant {{variant}} --judge {{judge}} --period {{period}} --limit {{limit}}); echo "$out"
    id=$(echo "$out" | sed -n 's/^Created \([^ ]*\).*/\1/p')
    from=$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '1 day ago' '+%Y-%m-%dT%H:%M:%SZ')
    continuous monitor backfill "$id" --from "$from"
    echo "↻ points build over a few minutes — re-run for the series:"
    echo "    continuous monitor show $id"
    continuous monitor show "$id"

# --- operator helpers --------------------------------------------------------

# One-time operator auth (browser handshake).
login:
    continuous login

# Worker subscriptions + their queue identity (diagnose "awaiting" cells).
workers:
    continuous workers list

# Reset the demo org — cancel + delete all CLI runs/shadows/monitors/replay sets
# and close the v3 PR (PR runs survive; keeps the org + install). Needs
# `continuous login` + gh + python3.
clean:
    ./clean.sh
