import { access, mkdtemp, rm, stat } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join, isAbsolute } from "node:path";
import { spawnSync } from "node:child_process";

const helperPathArg = process.argv[2];
const executableInBundle = process.argv[3];
if (!helperPathArg) {
  throw new Error("Usage: node check-helper-pack.mjs <helper-path> [executable-in-bundle]");
}

if (helperPathArg.endsWith(".app")) {
  if (!executableInBundle) {
    throw new Error("App bundle helper checks require <executable-in-bundle>");
  }
  await access(join(helperPathArg, executableInBundle), constants.X_OK);
} else {
  await access(helperPathArg, constants.X_OK);
}

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

  const helperPath = join(outDir, "package", helperPathArg);
  const helperStat = await stat(helperPath);
  if (helperPathArg.endsWith(".app")) {
    if (!helperStat.isDirectory()) {
      throw new Error(`Packed helper is not an app bundle directory: ${helperPath}`);
    }
    const appExecutable = join(helperPath, executableInBundle);
    const executableStat = await stat(appExecutable);
    if (!executableStat.isFile()) {
      throw new Error(`Packed helper app executable is not a file: ${appExecutable}`);
    }
    if ((executableStat.mode & 0o111) === 0) {
      throw new Error(`Packed helper app executable is not executable: ${appExecutable}`);
    }
    await access(join(helperPath, "Contents", "Info.plist"));
  } else {
    if (!helperStat.isFile()) {
      throw new Error(`Packed helper is not a file: ${helperPath}`);
    }
    if ((helperStat.mode & 0o111) === 0) {
      throw new Error(`Packed helper is not executable: ${helperPath}`);
    }
  }
} finally {
  await rm(outDir, { recursive: true, force: true });
}
