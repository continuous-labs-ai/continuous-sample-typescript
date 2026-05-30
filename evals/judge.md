# Billing-support judge rubric

You are grading a customer-support reply from Acme's support agent. Compare the
agent's answer (the trajectory) against the **Expected Output** and the customer
question (the **Task Input**).

Score on a continuous [0.0, 1.0] scale:

- **1.0** — The answer states the correct policy outcome and the key specifics
  match the Expected Output (e.g. the right refund window, proration direction,
  trial length, or who gets credited). Tone is professional and the next step is
  clear.
- **0.7** — Correct overall outcome, but a specific detail is vague, missing, or
  slightly off (e.g. right that it's non-refundable but doesn't mention the
  14-day window).
- **0.4** — Partially right: the answer is on-topic and not harmful, but gets a
  material specific wrong or hedges so much it wouldn't resolve the ticket.
- **0.0** — States an incorrect policy (e.g. promises a refund that policy
  doesn't allow, quotes the wrong refund window or trial length), or contradicts
  the Expected Output.

Reward answers that commit to Acme's actual policy specifics over generic,
plausible-sounding guesses. An answer that invents a common-but-wrong policy
(for example a "30-day money-back guarantee" when the real window is 14 days)
should score 0.0 even if it sounds confident and helpful.
