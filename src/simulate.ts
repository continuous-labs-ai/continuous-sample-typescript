import { fileURLToPath } from "node:url";
import { Client, builtinAnonymize } from "@continuous/sdk";
import { loadAgentName } from "./variants.js";

const QUESTIONS = [
  "Can I get a refund? I paid 18 days ago and barely used it.",
  "I upgraded to Pro this morning — am I being charged twice? Reach me at dana@example.com.",
  "How do I pause my plan for a couple of months?",
  "We dropped 3 seats last week. Do we get money back?",
  "Is there a free trial, and does it need a card?",
  "Can I stack my coupon with the annual discount? Call me at +1 415 555 0142.",
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

export async function main(argv: string[]): Promise<void> {
  const { total, deadline, concurrency } = parseArgs(argv);
  const agent = loadAgentName();
  // Capture is input-only and variant-agnostic; the SDK scrubs PII before enqueue.
  const client = new Client(undefined, { anonymize: builtinAnonymize });

  let nextI = 0;
  let done = 0;

  const take = (): number | null => {
    if (deadline !== null && Date.now() >= deadline) return null;
    if (total !== null && nextI >= total) return null;
    return nextI++;
  };

  async function pump(): Promise<void> {
    for (let i = take(); i !== null; i = take()) {
      client.record(agent, QUESTIONS[i % QUESTIONS.length]);
      done++;
      console.log(`[${String(done).padStart(4)}] recorded`);
    }
  }

  try {
    await Promise.all(
      Array.from({ length: Math.max(1, concurrency) }, () => pump()),
    );
  } finally {
    await client.close();
  }

  console.log(`\nrecorded ${done} inputs — agent ${agent}`);
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) void main(process.argv.slice(2));
