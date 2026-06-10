import { fileURLToPath } from "node:url";
import { Client } from "@continuous/sdk";
import { loadAgentName, loadVariants } from "./variants.js";
import { runVariant } from "./worker.js";

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

function parseDurationMs(spec: string): number {
  const units: Record<string, number> = { s: 1_000, m: 60_000, h: 3_600_000 };
  const unit = spec.slice(-1);
  const mult = units[unit];
  return mult
    ? Number.parseFloat(spec.slice(0, -1)) * mult
    : Number.parseFloat(spec) * 1_000;
}

interface Options {
  total: number | null;
  deadline: number | null;
  concurrency: number;
}

function parseArgs(argv: string[]): Options {
  let count: number | null = null;
  let durationMs: number | null = null;
  let concurrency = 4;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--duration") durationMs = parseDurationMs(argv[++i]);
    else if (a === "--concurrency")
      concurrency = Number.parseInt(argv[++i], 10);
    else if (!a.startsWith("--")) count = Number.parseInt(a, 10);
  }
  if (durationMs !== null) {
    return { total: null, deadline: Date.now() + durationMs, concurrency };
  }
  return { total: count ?? 30, deadline: null, concurrency };
}

// Every 4th simulated user rates the answer — that thumbs rating rides the row
// as its self_report (reason requires score).
function selfReport(i: number): { score?: number; reason?: string } {
  if (i % 4 !== 0) return {};
  return i % 12 === 0
    ? { score: 0, reason: "user marked the answer unhelpful" }
    : { score: 1, reason: "user marked the answer helpful" };
}

export async function main(argv: string[]): Promise<void> {
  const { total, deadline, concurrency } = parseArgs(argv);
  const agent = loadAgentName();
  // Production serves the baseline — the first declared variant (v1 on main).
  const [variant, spec] = [...loadVariants().entries()][0];
  const client = new Client();

  let nextI = 0;
  let done = 0;
  let rated = 0;

  const take = (): number | null => {
    if (deadline !== null && Date.now() >= deadline) return null;
    if (total !== null && nextI >= total) return null;
    return nextI++;
  };

  async function pump(): Promise<void> {
    for (let i = take(); i !== null; i = take()) {
      const question = QUESTIONS[i % QUESTIONS.length];
      const started = Date.now();
      const { steps, usage } = await runVariant(spec, question);
      const durationMs = Date.now() - started;
      const report = selfReport(i);
      client.reportTask(agent, steps, {
        duration_ms: durationMs,
        usage,
        ...report,
      });
      done++;
      if (report.score !== undefined) rated++;
      const ratedNote =
        report.score !== undefined ? ` self_report=${report.score}` : "";
      console.log(
        `[${String(done).padStart(4)}] ${variant.padEnd(4)} ${String(durationMs).padStart(6)}ms${ratedNote}`,
      );
    }
  }

  try {
    await Promise.all(
      Array.from({ length: Math.max(1, concurrency) }, () => pump()),
    );
  } finally {
    await client.close();
  }

  console.log(
    `\nsent ${done} tasks — variant ${variant} — ${rated} self-reported`,
  );
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) void main(process.argv.slice(2));
