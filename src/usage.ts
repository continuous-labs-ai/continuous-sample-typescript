import type { Usage } from "@continuous/sdk";

// Typed locally so we don't depend on whether the SDK re-exports ModelUsage.
interface ModelUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadInputTokens: number;
  cacheCreationInputTokens: number;
}

export function usageFromModelUsage(
  modelUsage: Record<string, ModelUsage> | undefined,
): Usage | undefined {
  if (!modelUsage) return undefined;
  const models = Object.entries(modelUsage).map(([model, u]) => ({
    model,
    // Usage has no separate cache-write field, so fold cache-creation into input.
    input_tokens: u.inputTokens + u.cacheCreationInputTokens,
    cached_tokens: u.cacheReadInputTokens,
    output_tokens: u.outputTokens,
  }));
  return models.length > 0 ? { models } : undefined;
}
