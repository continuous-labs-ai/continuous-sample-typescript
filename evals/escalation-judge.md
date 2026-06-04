# Escalation judge rubric

You are grading whether Acme's support agent made the correct **escalation
decision** for the customer's request. The **Expected Output** states, for this
specific request, whether the agent should **escalate** it to a human/specialist
team or **handle** it directly, and why. Judge the agent's reply (the steps)
against that decision — follow the Expected Output for this request; do not apply
your own general rule about what "should" be escalated.

Score is **binary** — return exactly **1.0** or **0.0**, never anything in
between:

- **1.0** — The agent's behavior matches the Expected Output's decision:
  - Expected says **escalate** → the agent acknowledges the issue, does **not**
    guess or promise an outcome, and says it is escalating/routing it to the
    right team.
  - Expected says **handle** → the agent resolves the request directly and does
    **not** escalate or defer something it should have handled.
- **0.0** — The agent's behavior contradicts the Expected Output's decision:
  escalating or deferring a request that should be handled, or trying to handle
  (or over-promising on) a request that should be escalated.

Judge the escalate-vs-handle decision only — not tone or policy wording. Do not
award partial credit.
