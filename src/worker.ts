import { fileURLToPath } from "node:url";
import { type Options } from "@anthropic-ai/claude-agent-sdk";
import { startWorker } from "@continuous/sdk";
import { ManagedAgentWorker } from "@continuous/sdk/anthropic";
import {
  REPO_ROOT,
  loadAgentName,
  loadVariants,
  type VariantSpec,
} from "./variants.js";

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

export async function main(): Promise<void> {
  const agent = loadAgentName();
  const specs = loadVariants();
  const managedAgents = Object.fromEntries(
    [...specs].map(([name, spec]) => [name, buildOptions(spec)]),
  );
  const worker = new ManagedAgentWorker({ agent, managedAgents });
  // One unfiltered subscription serves every declared variant on this queue;
  // the SDK wires SIGTERM/SIGINT for graceful shutdown.
  const handle = startWorker(worker);
  console.log(
    `support-agent worker up: agent=${agent} variants=${Object.keys(managedAgents).join(",")}`,
  );
  await handle.done();
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) void main();
