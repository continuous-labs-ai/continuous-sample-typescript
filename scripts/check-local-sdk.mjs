import { realpath } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const expected = await realpath(resolve(root, "../continuous/sdk/typescript"));
const require = createRequire(import.meta.url);

for (const specifier of ["@continuous/sdk", "@continuous/sdk/anthropic"]) {
  const entry = await realpath(require.resolve(specifier));
  const pathFromSDK = relative(expected, entry);
  if (pathFromSDK === ".." || pathFromSDK.startsWith(`..${sep}`)) {
    throw new Error(`${specifier} resolved outside ${expected}: ${entry}`);
  }
  await import(specifier);
}

console.log(`@continuous/sdk resolves from ${expected}`);
