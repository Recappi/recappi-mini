import { defineConfig } from "tsup";

export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm"],
  target: "node20",
  platform: "node",
  clean: true,
  dts: false,
  sourcemap: true,
  bundle: true,
  splitting: false,
  external: ["better-sqlite3", "music-metadata"],
});
