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
  // settingSources:[] isolates the baseline from on-disk policy; bypassPermissions
  // avoids a headless permission prompt no one can answer.
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
  // The leading input turn matters twice: the SDK rubric judge flattens it into
  // the scored prompt, and replay/shadow recover it as the replay input.
  const steps: Response[] = [
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
      steps.push({
        id: `step-${steps.length}`,
        role: "assistant",
        created_at: new Date().toISOString(),
        content,
      });
    }
  }
  return { steps, usage };
}

// Replay-window and shadow tasks carry the recorded leading turns (a JSON
// list), so recover the user text from them; dataset tasks are a plain question.
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

function buildFactory(specs: Map<string, VariantSpec>) {
  return async (task: Task): Promise<AgentResult> => {
    const spec = specs.get(task.variant);
    if (!spec) throw new Error(`unknown variant: ${task.variant}`);
    return runVariant(spec, promptFromPayload(task.payload.input));
  };
}

export async function main(): Promise<void> {
  const agent = loadAgentName();
  const specs = loadVariants();
  const worker = new ManagedAgentWorker({
    agent,
    agentFactory: buildFactory(specs),
  });
  // One unfiltered subscription serves every declared variant on this queue;
  // the SDK wires SIGTERM/SIGINT for graceful shutdown.
  const handle = startWorker(worker);
  console.log(
    `support-agent worker up: agent=${agent} variants=${[...specs.keys()].join(",")}`,
  );
  await handle.done();
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) void main();
