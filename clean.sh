#!/usr/bin/env bash
# Reset this workspace's Continuous demo data so the flows run against clean state.
#
# Deletes every Dataset in the workspace with `continuous dataset delete --yes`.
# That delete CASCADES (0004 §8.4): removing a Dataset also removes the Jobs,
# Monitors, and Triggers that reference it — so one pass clears the eval/replay/
# shadow/monitor/CI artifacts the demo created. Then it closes the pre-staged v3 PR.
# The workspace and the GitHub App install are left intact — just clean data.
#
# This drives the `continuous` CLI (reusing the session `continuous auth login`
# stored); it is deliberately NOT a `continuous` subcommand, just a demo helper.
# Needs: `continuous auth login` done, `gh` and `jq` on PATH.
set -euo pipefail

command -v continuous >/dev/null || { echo "continuous CLI not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 1; }

pr_branch="${V3_BRANCH:-add-v3-billing-skill}"

echo "→ deleting datasets (cascades their jobs / monitors / triggers)…"
# The dataset list is keyset-paged; page until it's empty. Each delete cascades,
# so a monitor/trigger/job tied to a deleted dataset goes with it.
while :; do
  ids="$(continuous dataset list --json | jq -r '.datasets[].id')"
  [ -n "$ids" ] || break
  progressed=0
  for id in $ids; do
    if continuous dataset delete "$id" --yes >/dev/null 2>&1; then
      echo "  - dataset/$id (+ cascade)"
      progressed=1
    fi
  done
  [ "$progressed" = 1 ] || break
done

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

echo "✓ demo workspace reset — workspace + install kept. Run 'just pr' to reopen the v3 PR."
