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
  // The leading input turn matters twice: the server judge flattens it into the
  // scored prompt, and shadow replay recovers it as the replay input.
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

// Shadow replay tasks carry the originating trajectory prefix (a JSON list of
// turns), so recover the user text from it; eval tasks are a plain question.
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
  // A single all-variants subscription avoids the (workspace,agent,queue,client)
  // collision that clobbers `variants`, stranding shadow replays on a queue no worker serves.
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
