#!/usr/bin/env bash
# Reset this org's Continuous data so the demo runs against clean state.
#
# Cancels any in-flight shadows, stops monitors, deletes every CLI run, shadow,
# monitor and replay set, and closes the pre-staged v3 PR. PR runs survive — the
# run list a CLI session reads is scoped to source=cli. The org and the GitHub
# App install are left intact — just clean data to look at.
#
# This reuses the session `continuous login` already stored; it is deliberately
# NOT a `continuous` CLI command, just a demo helper. Needs: `continuous login`
# done, `gh` on PATH, `python3`.
set -euo pipefail

creds="${XDG_CONFIG_HOME:-$HOME/.config}/continuous/credentials.toml"
[ -f "$creds" ] || { echo "no session — run 'continuous login' (just login) first" >&2; exit 1; }
field() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*['\"]\(.*\)['\"].*/\1/p" "$creds"; }
sealed="$(field sealed_session)"
ws="$(field workspace_id)"
api="${CONTINUOUS_API_URL:-$(field api_url)}"
pr_branch="${V3_BRANCH:-add-v3-billing-skill}"
[ -n "$sealed" ] && [ -n "$ws" ] && [ -n "$api" ] || { echo "missing session/workspace/api_url in $creds — run 'continuous login'" >&2; exit 1; }

req() { curl -fsS -H "Authorization: Bearer $sealed" -H "X-Workspace-Id: $ws" "$@"; }
# ids <listPath> <jsonKey>: print each row's id from a {"<key>":[{"id":...}]} body.
ids() { req "$api/v1/$1" 2>/dev/null | python3 -c "import sys,json;print('\n'.join(r['id'] for r in json.load(sys.stdin).get('$2',[])))" 2>/dev/null || true; }

echo "→ cancelling in-flight shadows / stopping monitors…"
for id in $(ids shadows shadows);   do req -o /dev/null -X POST "$api/v1/shadows/$id/cancel" || true; done
for id in $(ids monitors monitors); do req -o /dev/null -X POST "$api/v1/monitors/$id/stop"  || true; done

sleep 4   # let the cancels settle to terminal before deleting

echo "→ deleting runs / shadows / monitors / replay sets…"
# Status code from a DELETE without curl -f (409 = still in-flight, expected).
del() { curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $sealed" -H "X-Workspace-Id: $ws" -X DELETE "$api/v1/$1"; }
# Runs: /v1/runs is the CLI-scoped list (source=cli) and is capped per page, so
# page until a pass makes no progress. A run whose worker died mid-flight stays
# non-terminal and returns 409 — skip it (it can't be deleted until it finalizes).
while :; do
  rids="$(ids runs runs)"; [ -n "$rids" ] || break
  progressed=0
  for id in $rids; do
    case "$(del "runs/$id")" in 200|204) echo "  - run/$id"; progressed=1;; 409) echo "  - run/$id in-flight (skipped)";; esac
  done
  [ "$progressed" = 1 ] || break
done
for id in $(ids shadows shadows);   do req -o /dev/null -X DELETE "$api/v1/shadows/$id"  2>/dev/null && echo "  - shadow/$id"  || true; done
for id in $(ids monitors monitors); do req -o /dev/null -X DELETE "$api/v1/monitors/$id" 2>/dev/null && echo "  - monitor/$id" || true; done
for id in $(ids replay-sets replay_sets); do req -o /dev/null -X DELETE "$api/v1/replay-sets/$id" 2>/dev/null && echo "  - replay-set/$id" || true; done

echo "→ closing the v3 demo PR (if open)…"
if gh pr close "$pr_branch" --comment "demo cleanup" 2>/dev/null; then
  echo "  - closed PR for $pr_branch (re-run 'just pr' to reopen)"
else
  echo "  - no open PR for $pr_branch"
fi

# The staging branch must outlive its PR — flow B depends on it. Re-push it if
# anything (branch auto-delete, manual cleanup) removed it from origin.
if ! git ls-remote --exit-code --heads origin "$pr_branch" >/dev/null 2>&1; then
  if git rev-parse --verify --quiet "refs/heads/$pr_branch" >/dev/null; then
    git push origin "$pr_branch:refs/heads/$pr_branch"
    echo "  - re-pushed $pr_branch (it was missing from origin)"
  else
    echo "  ! $pr_branch is missing from origin and has no local branch — restore it before 'just pr'" >&2
    exit 1
  fi
fi

echo "✓ demo org reset — org + install kept. Run 'just pr' to reopen the v3 PR."
