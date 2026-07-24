# Acme billing-support agent — demo runbook, packaged (TypeScript twin).
#
# One `just` recipe per flow, each covering a Continuous surface: eval (A), CI (B),
# replay (C), shadow (D), monitor (E). The C/D/E recipes drive the production
# traffic the flow needs, then print the report or a watch hint.
#
# The current CLI has ONE launch verb: `continuous run --dataset-id <ds>` submits a
# Job over a Dataset, and the kind (eval / replay / shadow) is DERIVED from the
# Dataset's kind (static → eval, historical → replay, live → shadow, 0002 §3.3).
# So each flow is two steps: `continuous dataset create <dir>` (0004 §8.3) to mint a
# ds_ id, then `continuous run --dataset-id <that>`. Judge + agent come from the
# Dataset, never the command.
#
# Prereqs (see DEMO.md): `continuous`, `gh`, and `jq` on PATH, `continuous auth login`
# done, the README's sibling-SDK setup, and a .env with CONTINUOUS_API_KEY / CONTINUOUS_API_URL /
# ANTHROPIC_API_KEY (auto-loaded; ANTHROPIC_API_KEY also feeds the SDK's rubric judge
# unless CONTINUOUS_JUDGE_API_KEY / _BASE_URL override it — the judge MODEL comes from
# each rubric's [judge].model, 0003 §14.1). Keep `just worker` running in one terminal
# — it serves dispatched eval tasks, replayed rows, shadow mirrors, and monitor probes.

set dotenv-load := true

agent := "support-agent-ts"

# List the recipes.
default:
    @just --list --unsorted

# --- the running agent -------------------------------------------------------

# Host worker — serves every declared variant on queue user:<you>@<host>.
# Required for eval (A), replay (C), shadow (D), and monitor (E) — it executes the
# dispatched tasks, mirrors, and probes. Keep it running in its own terminal.
worker:
    npm run worker

# CI worker — serves the PR-head queue (sha:<HEAD>). Run from a checkout of the PR
# branch so a Trigger's PR Job has a worker to claim its trials.
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

# A — eval-as-code: push the static Dataset, then run every variant over it (no PR).
# Needs `just worker`. Datasets are directories (dataset.toml + tests/judge.toml +
# tasks/<t>/{instruction.md, task.toml, expected.md}); the judge model is the
# rubric's [judge].model. Names are labels — each push mints a fresh ds_ id.
eval name="billing-support" variants="v1 v2":
    #!/usr/bin/env bash
    set -euo pipefail
    ds=$(continuous dataset create ./datasets/{{name}} --agent {{agent}} --name {{name}} --json | jq -r .id)
    echo "dataset $ds ({{name}})"
    for v in {{variants}}; do
      echo "== run $v over $ds =="
      continuous run --dataset-id "$ds" --agent {{agent}} --variant "$v" --wait
    done
    echo "inspect: continuous job list  ·  continuous job get <job_id>"

# B — CI: create a Trigger that auto-runs the candidate over a static Dataset on
# every PR (path-gated, 0003 §15.7), then open the pre-staged v3 PR. Run
# `just ci-worker` from the PR branch first so the PR Job's trials have a worker.
# Each Trigger posts its own check-run (mirrors the Job's status, never score-driven).
trigger variant="v3" paths="agent/variants/v3/**":
    #!/usr/bin/env bash
    set -euo pipefail
    ds=$(continuous dataset create ./datasets/billing-support --agent {{agent}} --name billing-support --json | jq -r .id)
    continuous trigger create --agent {{agent}} --variant {{variant}} --dataset-id "$ds" --path '{{paths}}'
    echo "trigger armed for {{variant}} — open the PR to fire it:  just pr"

pr:
    gh pr create --base main --head add-v3-billing-skill \
      --title "Add v3: billing-policy skill" -F .github/PR_BODY_v3.md

# C — replay: drive traffic, freeze a historical Dataset over a trailing window
# (rows materialize from the agent's recorded production INPUT), then run each
# variant over it. Needs `just worker`. The historical Dataset is immutable and
# re-runnable — the frozen benchmark; `continuous dataset list` shows its provenance.
replay window="24h" variants="v1 v2" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    npm run simulate -- {{traffic}}
    ds=$(continuous dataset create ./datasets/recorded --agent {{agent}} --name "replay-{{window}}" --kind historical --window {{window}} --json | jq -r .id)
    echo "historical dataset $ds (window {{window}})"
    for v in {{variants}}; do
      echo "== replay $v over $ds =="
      continuous run --dataset-id "$ds" --agent {{agent}} --variant "$v" --sample 100 --wait
    done

# D — shadow: run a candidate over a LIVE Dataset with a --deadline — a streaming
# Job that mirrors sampled production traffic through the candidate out of band.
# Needs `just worker` (it executes the mirrors). `continuous job get <id>` is the
# report (the old `shadow show`).
shadow candidates="v2" sample="100" deadline="1h" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    ds=$(continuous dataset create ./datasets/recorded --agent {{agent}} --name "shadow-live" --kind live --json | jq -r .id)
    out=$(continuous run --dataset-id "$ds" --agent {{agent}} --variant {{candidates}} --sample {{sample}} --deadline {{deadline}} --json); echo "$out"
    id=$(echo "$out" | jq -r .id)
    npm run simulate -- {{traffic}}
    echo "↻ mirrors land over a few minutes — re-run for the full report:"
    echo "    continuous job get $id"
    continuous job get "$id"

# E — monitor: hold one composition and re-score it each tick over a historical
# Dataset's window. Drives traffic, freezes the historical Dataset, creates the
# monitor. Needs `just worker` (it executes the probes). Points build forward from
# each scheduled tick (there is no backfill — pick a short --schedule to see one sooner).
monitor variant="v1" schedule="1h" limit="10" window="24h" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    npm run simulate -- {{traffic}}
    ds=$(continuous dataset create ./datasets/recorded --agent {{agent}} --name "monitor-{{window}}" --kind historical --window {{window}} --json | jq -r .id)
    out=$(continuous monitor create --dataset-id "$ds" --variant {{variant}} --schedule {{schedule}} --limit {{limit}} --json); echo "$out"
    id=$(echo "$out" | jq -r .id)
    echo "↻ the first point builds when the first {{schedule}} period closes — re-run for the series:"
    echo "    continuous monitor get $id"
    continuous monitor get "$id"

# --- operator helpers --------------------------------------------------------

# One-time operator auth (browser handshake).
login:
    continuous auth login

# Connected workers + their queue identity (diagnose "awaiting" cells).
workers:
    continuous worker list

# Reset the demo org — delete every CLI-created Dataset (the delete cascades its
# Jobs, Monitors, and Triggers, 0004 §8.4) and close the v3 PR. Needs
# `continuous auth login` + gh + jq.
clean:
    ./clean.sh
