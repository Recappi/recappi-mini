import { mkdtemp, rm, readFile, access, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { spawnSync } from "node:child_process";

const outDir = await mkdtemp(join(tmpdir(), "recappi-cli-pack-"));
try {
  const pack = spawnSync("pnpm", ["pack", "--pack-destination", outDir], {
    cwd: new URL("..", import.meta.url),
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
  const pkgPath = join(outDir, "package", "package.json");
  const pkg = JSON.parse(await readFile(pkgPath, "utf8"));
  const deps = {
    ...pkg.dependencies,
    ...pkg.devDependencies,
    ...pkg.optionalDependencies,
  };
  for (const [name, version] of Object.entries(deps)) {
    if (String(version).startsWith("workspace:")) {
      throw new Error(`Packed package contains workspace dependency ${name}: ${version}`);
    }
  }
  const bin = pkg.bin?.recappi;
  if (typeof bin !== "string") throw new Error("package.json missing bin.recappi");
  const binPath = join(outDir, "package", bin);
  await access(binPath);
  const consumerDir = join(outDir, "consumer");
  await mkdir(consumerDir);
  const install = spawnSync(
    "npm",
    ["install", tarPath, "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"],
    {
      cwd: consumerDir,
      encoding: "utf8",
      stdio: "pipe",
    },
  );
  if (install.status !== 0) {
    process.stderr.write(install.stderr);
    process.exit(install.status ?? 1);
  }
  const installedBinPath = join(consumerDir, "node_modules", ...pkg.name.split("/"), bin);
  await access(installedBinPath);
  const smoke = spawnSync(process.execPath, [installedBinPath, "--json"], { encoding: "utf8" });
  if (smoke.status !== 2) {
    throw new Error(`Packed recappi --json smoke exited ${smoke.status}; stderr=${smoke.stderr}`);
  }
  const parsed = JSON.parse(smoke.stdout);
  if (parsed?.error?.code !== "usage.missing_command") {
    throw new Error("Packed recappi --json smoke did not return usage.missing_command");
  }
} finally {
  await rm(outDir, { recursive: true, force: true });
}
