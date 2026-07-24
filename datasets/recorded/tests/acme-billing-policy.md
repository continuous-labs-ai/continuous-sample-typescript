# Acme billing policy (judge ground truth)

Acme's real refund/proration/trial rules. The support agent must answer customer
billing questions consistently with these terms; a plausible-but-wrong guess
(e.g. a common "30-day money-back guarantee") is incorrect.

## Refunds
- **Monthly plans:** refund window is **14 days** from the charge. A payment older
  than 14 days is outside the window — offer to cancel so the customer is not
  billed next cycle (access continues until the current period ends).
- **Annual plans:** a **prorated** refund if cancelled **within 30 days** of
  purchase; after 30 days annual plans are **non-refundable**.
- Cancelling stops future renewals only. Access continues until the end of the
  current paid period; there is **no** partial refund for unused time (except an
  annual plan within its 30-day window).

## Plan changes
- **Upgrades** apply immediately and are **prorated** — the customer is charged the
  tier difference for the remainder of the current cycle right away.
- **Downgrades** take effect at the **next** billing cycle and are **not** refunded
  mid-cycle; the customer keeps the higher tier until the current period ends.

## Seats
- **Added** seats are prorated and charged immediately.
- **Removed** seats are **not** refunded to the card; their value is **credited to
  the next invoice**.

## Trials
- The free trial is **14 days** and **requires a credit card**. It auto-converts to
  a paid subscription at the end of the trial unless cancelled before it ends.

## Discounts
- Only **one** discount applies per subscription. Coupons do **not** stack with the
  annual discount; the customer keeps whichever discount is larger.

## Pausing
- Monthly plans can be **paused for up to 3 months**. Billing is suspended while
  paused and resumes automatically when the pause ends.
