// Load the agent + variant compositions from the repo's declarative config.
//
// The unit Continuous ships is the full `model x prompt x skill` composition.
// Each variant is a directory under `agent/variants/<name>/` holding a
// `variant.yaml` (model + which skills to load) and a `prompt.md` (the system
// prompt). The declared variant list comes from `.continuous/config.yml` — the
// same file the Continuous server uses as the variant catalog — so the worker
// subscribes to exactly the variants the platform knows about.

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";

const moduleDir = dirname(fileURLToPath(import.meta.url));
// src/variants.ts (tsx) and dist/variants.js (built) both sit one level under
// the repo root. The Agent SDK resolves .claude/skills relative to this.
export const REPO_ROOT =
  process.env.SAMPLE_REPO_ROOT ?? resolve(moduleDir, "..");
const CONFIG_PATH = join(REPO_ROOT, ".continuous", "config.yml");
const VARIANTS_DIR = join(REPO_ROOT, "agent", "variants");

export interface VariantSpec {
  name: string;
  model: string;
  systemPrompt: string;
  skills: string[];
}

interface ConfigFile {
  agents: { name: string; variants: { name: string }[] }[];
}

interface VariantFile {
  model: string;
  prompt?: string;
  skills?: string[];
}

function loadConfig(): ConfigFile {
  return parse(readFileSync(CONFIG_PATH, "utf8")) as ConfigFile;
}

export function loadAgentName(): string {
  return loadConfig().agents[0].name;
}

export function loadDeclaredVariants(): string[] {
  return loadConfig().agents[0].variants.map((v) => v.name);
}

export function loadVariants(): Map<string, VariantSpec> {
  const specs = new Map<string, VariantSpec>();
  for (const name of loadDeclaredVariants()) {
    const vdir = join(VARIANTS_DIR, name);
    const meta = parse(
      readFileSync(join(vdir, "variant.yaml"), "utf8"),
    ) as VariantFile;
    const promptFile = meta.prompt ?? "prompt.md";
    const systemPrompt = readFileSync(join(vdir, promptFile), "utf8").trim();
    specs.set(name, {
      name,
      model: meta.model,
      systemPrompt,
      skills: meta.skills ?? [],
    });
  }
  return specs;
}
