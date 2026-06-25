import { readFileSync } from "node:fs";

export function readCliVersion(): string {
  try {
    const parsed = JSON.parse(
      readFileSync(new URL("../package.json", import.meta.url), "utf8"),
    ) as Record<string, unknown>;
    if (typeof parsed.version === "string" && parsed.version.trim()) {
      return parsed.version;
    }
  } catch {
    // Build-time and source-test layouts both have package.json one level up;
    // if an unusual embedder removes it, fall back to a clear placeholder.
  }
  return "0.0.0";
}

export const CLI_VERSION = readCliVersion();
