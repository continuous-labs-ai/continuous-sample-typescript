// Production-traffic simulator for the CD rollout demo.
//
// While a rollout is live, Continuous routes a fraction of production traffic to
// the candidate. This script plays the role of the customer's production app:
// for each simulated request it asks Continuous which variant to use
// (`Client.getVariant`), runs that variant, and reports the resulting trajectory
// (`Client.reportTrajectory`). The Canary Agent judges those live trajectories
// at each stage gate and decides whether to advance.
//
//   CONTINUOUS_API_KEY=ck_...  CONTINUOUS_API_URL=http://localhost:8080 \
//   ANTHROPIC_API_KEY=sk-ant-... \
//     npm run simulate -- 30

import { fileURLToPath } from "node:url";
import { Client } from "@continuous/sdk";
import { loadAgentName, loadVariants } from "./variants.js";
import { runVariant } from "./worker.js";

// A small pool of live-traffic questions, mirroring the eval set so the canary
// judges the candidate on representative traffic.
const QUESTIONS = [
  "Can I get a refund? I paid 18 days ago and barely used it.",
  "I upgraded to Pro this morning — am I being charged twice?",
  "How do I pause my plan for a couple of months?",
  "We dropped 3 seats last week. Do we get money back?",
  "Is there a free trial, and does it need a card?",
  "Can I stack my coupon with the annual discount?",
  "If I cancel now do I lose access immediately?",
  "I bought annual two weeks ago and want out. Refund?",
];

export async function main(argv: string[]): Promise<void> {
  const n = argv[0] ? Number.parseInt(argv[0], 10) : 20;
  const agent = loadAgentName();
  const specs = loadVariants();
  const client = new Client();
  try {
    for (let i = 0; i < n; i++) {
      const question = QUESTIONS[i % QUESTIONS.length];
      const routing = await client.getVariant(agent, `sim-user-${i}`);
      const spec = specs.get(routing.variant);
      if (!spec) throw new Error(`unknown variant: ${routing.variant}`);
      const started = Date.now();
      const trajectory = await runVariant(spec, question);
      const durationMs = Date.now() - started;
      // judged_by: "server" — the Canary/Production Judge scores the trajectory
      // server-side against the rollout's judge file.
      client.reportTrajectory(routing, trajectory, {
        judged_by: "server",
        duration_ms: durationMs,
      });
      const tag = routing.is_main ? "main" : "candidate";
      console.log(`[${i}] -> ${routing.variant} (${tag}, ${durationMs}ms)`);
    }
  } finally {
    await client.close();
  }
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) void main(process.argv.slice(2));
