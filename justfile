# Acme billing-support agent — demo runbook, packaged (TypeScript twin).
#
# One `just` recipe per flow, each covering a Continuous feature: eval (A), CI (B),
# replay (C), shadow (D), monitor (E). The C/D/E recipes drive the production
# traffic the flow needs, then print the report — no second command.
#
# Prereqs (see VALIDATION.md): the `continuous` CLI + `gh` on PATH, `continuous login`
# done, `npm install`, and a .env with CONTINUOUS_API_KEY / CONTINUOUS_API_URL /
# ANTHROPIC_API_KEY (auto-loaded; ANTHROPIC_API_KEY also feeds the SDK's rubric
# judge unless CONTINUOUS_JUDGE_API_KEY / _BASE_URL / _MODEL override it). Keep
# `just worker` running in one terminal for eval (A), replay (C), shadow (D), and
# monitor (E).

set dotenv-load := true

agent := "support-agent-ts"
judge := "evals/support-judge.md"

# List the recipes.
default:
    @just --list --unsorted

# --- the running agent -------------------------------------------------------

# Host worker — serves every declared variant on queue user:<you>@<host>.
# Required for eval (A), replay (C), shadow (D), and monitor (E). Keep it
# running in its own terminal.
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

# C — replay: drive production traffic, then re-score the last day of it through
# every variant via the replay-window eval. Needs `just worker`.
replay name="replay-recent" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    npm run simulate -- {{traffic}}
    continuous eval {{name}}

# D — shadow: sample v1 traffic, replay through the candidate out of band, show the
# paired report. Needs `just worker` running (it executes the replays).
shadow name="shadow-v2" candidates="v2" sample="100" deadline="1h" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(continuous shadow start {{agent}} --name {{name}} --candidates {{candidates}} --sample {{sample}} --judge {{judge}} --deadline {{deadline}} --confirm); echo "$out"
    id=$(echo "$out" | sed -n 's/^Started \([^ .]*\).*/\1/p')
    npm run simulate -- {{traffic}}
    echo "↻ replays land over a few minutes — re-run for the full report:"
    echo "    continuous shadow show $id"
    continuous shadow show "$id"

# E — monitor: drive traffic, hold a variant under a scheduled judge, backfill the
# last day so points cover the traffic just driven, print the series. Needs
# `just worker` (it executes the probe replays). Monitor creation is a
# person-action, so this reuses the `continuous login` session.
monitor variant="v1" period="1h" traffic="24":
    #!/usr/bin/env bash
    set -euo pipefail
    creds="${XDG_CONFIG_HOME:-$HOME/.config}/continuous/credentials.toml"
    [ -f "$creds" ] || { echo "no session — run 'continuous login' (just login) first" >&2; exit 1; }
    field() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*['\"]\(.*\)['\"].*/\1/p" "$creds"; }
    sealed="$(field sealed_session)"; ws="$(field workspace_id)"
    api="${CONTINUOUS_API_URL:-$(field api_url)}"
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
    req() { curl -fsS -H "Authorization: Bearer $sealed" -H "X-Workspace-Id: $ws" "$@"; }
    npm run simulate -- {{traffic}}
    id=$(req -X POST "$api/v1/monitors" -H 'Content-Type: application/json' \
      -d "{\"agent\":\"{{agent}}\",\"variant\":\"{{variant}}\",\"judge\":\"{{judge}}\",\"repo\":\"$repo\",\"period\":\"{{period}}\"}" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["monitor"]["id"])')
    echo "Started $id (active, period {{period}})"
    from=$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '1 day ago' '+%Y-%m-%dT%H:%M:%SZ')
    req -X POST "$api/v1/monitors/$id/backfill" -H 'Content-Type: application/json' -d "{\"from\":\"$from\"}" \
      | python3 -c 'import sys,json;print("backfill queued_periods:", json.load(sys.stdin)["queued_periods"])'
    echo "↻ points build over a few minutes — re-check with: just monitor-show $id"
    just monitor-show "$id"

# The monitor series (id from `just monitor` / the dashboard).
monitor-show id:
    #!/usr/bin/env bash
    set -euo pipefail
    creds="${XDG_CONFIG_HOME:-$HOME/.config}/continuous/credentials.toml"
    field() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*['\"]\(.*\)['\"].*/\1/p" "$creds"; }
    api="${CONTINUOUS_API_URL:-$(field api_url)}"
    curl -fsS -H "Authorization: Bearer $(field sealed_session)" -H "X-Workspace-Id: $(field workspace_id)" \
      "$api/v1/monitors/{{id}}" | python3 -c '
    import sys, json
    d = json.load(sys.stdin)
    m = d["monitor"]
    print("Monitor %s — %s (%s/%s)" % (m["id"], m["status"], m["agent"], m["variant"]))
    for p in d["points"] or []:
        rate = (p.get("metrics") or {}).get("success_rate")
        rate = "%.2f" % rate if rate is not None else "—"
        print("  %s  %-9s %-9s success_rate=%s" % (p["period_start"], p["kind"], p["status"], rate))
    for a in d["alerts"] or []:
        print("  alert: %s" % json.dumps(a))
    '

# --- operator helpers --------------------------------------------------------

# One-time operator auth (browser handshake).
login:
    continuous login

# Worker subscriptions + their queue identity (diagnose "awaiting" cells).
workers:
    continuous workers list

# Reset the demo org — cancel + delete all runs/shadows/monitors and close the
# v3 PR (keeps the org + install). Needs `continuous login` + gh + python3.
clean:
    ./clean.sh
