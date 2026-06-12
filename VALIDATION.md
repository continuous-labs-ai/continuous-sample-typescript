# Acme billing-support demo — validation log

The validation record for the five demo flows. The runbook — prerequisites, the
cast (v1/v2/v3), and the recipe per flow — lives in **[DEMO.md](DEMO.md)**.

| Flow | Recipe | Status |
| ---- | ------ | ------ |
| A — Eval (local CLI) | `just eval` | **PENDING re-validation (v2)** |
| B — CI (GitHub PR) | `just pr` | **PENDING re-validation (v2)** |
| C — Replay (window + frozen set) | `just replay` / `just replay-set` | **PENDING re-validation (v2)** |
| D — Shadow | `just shadow` | **PENDING re-validation (v2)** |
| E — Monitor | `just monitor` | **PENDING re-validation (v2)** |

A Python twin lives in `continuous-sample-python/VALIDATION.md` — same
flows, `uv` instead of `npm`.

## Log

- **2026-06-12** — v2 restructure merged: eval/replay/shadow/monitor surfaces,
  worker-side judging, replay + replay-set + monitor recipes moved onto the
  `continuous` CLI. All five flows pending live re-validation against dev.
