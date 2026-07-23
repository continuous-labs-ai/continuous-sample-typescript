## What this PR does

Introduces a third variant of the `support-agent`, **v3**, which is **v2 plus the
`billing-policy` Agent Skill**. Nothing else changes:

|                        | model             | prompt         | skill                |
| ---------------------- | ----------------- | -------------- | -------------------- |
| v2 (current candidate) | claude-sonnet-4-6 | policy-aware   | —                    |
| **v3 (this PR)**       | claude-sonnet-4-6 | **same as v2** | **`billing-policy`** |

Files added:

- `agent/variants/v3/{prompt.md,variant.yaml}` — the v3 composition (`skills: [billing-policy]`)
- `.claude/skills/billing-policy/SKILL.md` — Acme's authoritative refund / proration / trial / coupon / seat / pause / cancellation rules
- `.continuous/config.yml` — adds `v3` to the worker's variant list

## Why

Acme's billing rules are proprietary — the model can't guess the exact 14-day
refund window, the annual-plan 30-day proration, or who gets credited vs.
refunded. v1 and v2 confidently invent plausible-but-wrong specifics. v3 reads
the policy from the skill and applies the real terms. This isolates the **skill**
axis: it's the only thing that changes v2 → v3.

## What Continuous does on this PR

A Continuous **Trigger** armed for `v3` — scoped by its `--path` glob to
`agent/variants/v3/**` — matches this diff, so on the PR head Continuous runs the
`billing-support` eval for **v3** and posts a **check-run** whose conclusion mirrors
the Job's status (never score-driven). Compare the per-variant scores in the app's
Runs view. Expected: v3 wins on the policy questions — the skill earning its place.

<!-- After the eval runs, paste/confirm the score delta here:
| variant | score |
| --- | --- |
| baseline (v1) | 0.__ |
| v3            | 0.__ |
-->
