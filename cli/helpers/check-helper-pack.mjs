import { access, mkdtemp, rm, stat } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join, isAbsolute } from "node:path";
import { spawnSync } from "node:child_process";

const executable = process.argv[2];
if (!executable) {
  throw new Error("Usage: node check-helper-pack.mjs <executable>");
}

await access(executable, constants.X_OK);

const outDir = await mkdtemp(join(tmpdir(), "recappi-helper-pack-"));
try {
  const pack = spawnSync("pnpm", ["pack", "--pack-destination", outDir], {
    cwd: process.cwd(),
    encoding: "utf8",
    stdio: "pipe",
  });
  if (pack.status !== 0) {
    process.stderr.write(pack.stderr);
    process.exit(pack.status ?? 1);
  }
  const tarball = pack.stdout.trim().split("\n").at(-1);
  if (!tarball) throw new Error("pnpm pack did not print a tarball name");
  const tarPath = isAbsolute(tarball) ? tarball : join(outDir, tarball);
  const inspect = spawnSync("tar", ["-xzf", tarPath, "-C", outDir], { encoding: "utf8" });
  if (inspect.status !== 0) {
    process.stderr.write(inspect.stderr);
    process.exit(inspect.status ?? 1);
  }

  const helperPath = join(outDir, "package", executable);
  const helperStat = await stat(helperPath);
  if (!helperStat.isFile()) {
    throw new Error(`Packed helper is not a file: ${helperPath}`);
  }
  if ((helperStat.mode & 0o111) === 0) {
    throw new Error(`Packed helper is not executable: ${helperPath}`);
  }
} finally {
  await rm(outDir, { recursive: true, force: true });
}
