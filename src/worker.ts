// The Continuous worker: serve each variant by driving the Claude Agent SDK.
//
// This is the whole integration. `ManagedAgentWorker` takes a factory
// `(task) -> trajectory`; `startWorker` runs one poll loop advertising every
// variant. The factory reads `task.variant` — the only channel the SDK uses to
// tell the worker which composition to run — loads that variant's
// `model x prompt x skill`, runs the Anthropic Claude Agent SDK, and returns the
// trajectory. Continuous judges it server-side against `evals/support-judge.md`.
//
// Run it (from the repo root) with both keys in the environment:
//
//   CONTINUOUS_API_KEY=ck_...  CONTINUOUS_API_URL=http://localhost:8080 \
//   ANTHROPIC_API_KEY=sk-ant-... \
//     npm run worker

import { fileURLToPath } from "node:url";
import { query, type Options } from "@anthropic-ai/claude-agent-sdk";
import {
  ManagedAgentWorker,
  startWorker,
  type AgentResult,
  type Response,
  type Task,
  type Usage,
} from "@continuous/sdk";
import {
  REPO_ROOT,
  loadAgentName,
  loadVariants,
  type VariantSpec,
} from "./variants.js";
import { usageFromModelUsage } from "./usage.js";

function buildOptions(spec: VariantSpec): Options {
  // Model and system prompt come straight from the variant. Skills are the
  // third axis: a variant that declares skills loads exactly those (the `skills`
  // option auto-enables the Skill tool and the project setting source); a
  // variant with no skills runs isolated (`settingSources: []`) so the baseline
  // can't see the policy on disk. `bypassPermissions` keeps the headless worker
  // from blocking on a permission prompt no one can answer.
  const base: Options = {
    model: spec.model,
    systemPrompt: spec.systemPrompt,
    cwd: REPO_ROOT,
    permissionMode: "bypassPermissions",
    maxTurns: 6,
  };
  return spec.skills.length > 0
    ? { ...base, skills: spec.skills }
    : { ...base, settingSources: [] };
}

export async function runVariant(
  spec: VariantSpec,
  agentInput: string,
): Promise<AgentResult> {
  // Lead with the originating input as a `user` turn, then one `assistant`
  // Response per turn. The leading input turn matters twice: the server judge
  // flattens it into the prompt it scores, and shadow recovers it as the replay
  // input — an assistant-only trajectory yields an empty prefix and is never
  // replayed.
  const trajectory: Response[] = [
    {
      id: "input",
      role: "user",
      created_at: new Date().toISOString(),
      content: [{ type: "text", text: agentInput }],
    },
  ];
  let usage: Usage | undefined;
  for await (const message of query({
    prompt: agentInput,
    options: buildOptions(spec),
  })) {
    if (message.type === "result") {
      usage = usageFromModelUsage(message.modelUsage);
      continue;
    }
    if (message.type !== "assistant") continue;
    const content: unknown[] = [];
    for (const block of message.message.content) {
      if (block.type === "text") {
        content.push({ type: "text", text: block.text });
      } else if (block.type === "tool_use") {
        content.push({
          type: "tool_use",
          id: block.id,
          name: block.name,
          input: block.input,
        });
      }
    }
    if (content.length > 0) {
      trajectory.push({
        id: `step-${trajectory.length}`,
        role: "assistant",
        created_at: new Date().toISOString(),
        content,
      });
    }
  }
  return { trajectory, usage };
}

// Normalize a Task input to a prompt. Eval tasks carry a plain question; shadow
// replay tasks carry the originating trajectory prefix (a JSON list of turns),
// so recover the user text from it.
function promptFromPayload(raw: string): string {
  const text = raw.trim();
  if (text.startsWith("[")) {
    try {
      const items = JSON.parse(text) as Array<{
        role?: string;
        content?: Array<{ type?: string; text?: string }>;
      }>;
      const parts = items
        .filter((t) => t.role === "user")
        .flatMap((t) =>
          (t.content ?? [])
            .filter((b) => b.type === "text")
            .map((b) => b.text ?? ""),
        );
      if (parts.length > 0) return parts.join("\n");
    } catch {
      return raw;
    }
  }
  return raw;
}

function buildFactory() {
  const specs = loadVariants();
  return async (task: Task): Promise<AgentResult> => {
    const spec = specs.get(task.variant);
    if (!spec) throw new Error(`unknown variant: ${task.variant}`);
    return runVariant(spec, promptFromPayload(task.payload.input));
  };
}

export async function main(): Promise<void> {
  const agent = loadAgentName();
  const worker = new ManagedAgentWorker({
    agent,
    agentFactory: buildFactory(),
  });
  // One subscription advertising ALL declared variants. Per-variant poll loops
  // collide on the (workspace, agent, queue, client) subscription key and clobber
  // `variants` to a single value, so the platform only sees the worker as serving
  // one variant and shadow replays for the others route to a queue no worker
  // serves. A single all-variants poll keeps the subscription complete.
  const variants = [...loadVariants().keys()];
  const handle = startWorker(worker, { variants });
  console.log(
    `support-agent worker up: agent=${agent} variants=${variants.join(",")}`,
  );
  process.on("SIGINT", () => {
    void handle.stop();
  });
  await handle.done();
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) void main();
