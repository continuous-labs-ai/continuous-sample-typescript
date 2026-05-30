// The Continuous worker: serve each variant by driving the Claude Agent SDK.
//
// This is the whole integration. `ManagedAgentWorker` takes a factory
// `(task) -> trajectory`; `startWorkersForVariants` runs one poll loop per
// variant. The factory reads `task.variant` — the only channel the SDK uses to
// tell the worker which composition to run — loads that variant's
// `model x prompt x skill`, runs the Anthropic Claude Agent SDK, and returns the
// trajectory. Continuous judges it server-side against `evals/judge.md`.
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
  startWorkersForVariants,
  type Response,
  type Task,
} from "@continuous/sdk";
import {
  REPO_ROOT,
  loadAgentName,
  loadVariants,
  type VariantSpec,
} from "./variants.js";

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
): Promise<Response[]> {
  // Each assistant turn becomes one Response with text/tool_use content blocks.
  // The server judge flattens text blocks into the prompt it scores, so the
  // final answer must be a text block.
  const trajectory: Response[] = [];
  for await (const message of query({
    prompt: agentInput,
    options: buildOptions(spec),
  })) {
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
  return trajectory;
}

function buildFactory() {
  const specs = loadVariants();
  return async (task: Task): Promise<Response[]> => {
    const spec = specs.get(task.variant);
    if (!spec) throw new Error(`unknown variant: ${task.variant}`);
    return runVariant(spec, task.payload.input);
  };
}

export async function main(): Promise<void> {
  const agent = loadAgentName();
  const worker = new ManagedAgentWorker({
    agent,
    agentFactory: buildFactory(),
  });
  // One independent poll loop per declared variant. On `main` that's [v1, v2];
  // on the v3 PR branch config adds v3 and this list grows with no code change.
  const variants = [...loadVariants().keys()];
  const handles = startWorkersForVariants(worker, variants);
  console.log(
    `support-agent worker up: agent=${agent} variants=${variants.join(",")}`,
  );
  process.on("SIGINT", () => {
    void Promise.all(handles.map((h) => h.stop()));
  });
  await Promise.all(handles.map((h) => h.done()));
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) void main();
