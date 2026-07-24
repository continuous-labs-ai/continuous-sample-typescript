# Acme billing-support demo — validation log

The validation record for the five demo flows. The runbook — prerequisites, the
cast (v1/v2/v3), and the recipe per flow — lives in **[DEMO.md](DEMO.md)**.

| Flow                             | Recipe                     | Status                    |
| -------------------------------- | -------------------------- | ------------------------- |
| A — Eval (local CLI)             | `just eval`                | **PENDING re-validation** |
| B — CI (GitHub PR)               | `just trigger` + `just pr` | **PENDING re-validation** |
| C — Replay (window + frozen set) | `just replay`              | **PENDING re-validation** |
| D — Shadow                       | `just shadow`              | **PENDING re-validation** |
| E — Monitor                      | `just monitor`             | **PENDING re-validation** |

A Python twin lives in `continuous-sample-python/VALIDATION.md` — same
flows, `uv` instead of `npm`.

## Log

- **Platform-current reconciliation** — moved every flow onto the current CLI: the
  single `continuous run --dataset-id` launch verb (surface derived from the
  Dataset's kind), Harbor Dataset **directories** (`dataset.toml` + rewardkit
  `tests/judge.toml` + `tasks/<t>/…`) under `datasets/`, API-managed **Triggers**
  for CI (config-file triggers retired), and `continuous auth login` / `worker list`
  / `job get` / `monitor get`. All five flows are pending live re-validation.
