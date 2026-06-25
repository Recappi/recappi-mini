import { appendFile, readFile, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";

const packageUrl = new URL("../package.json", import.meta.url);
const pkg = JSON.parse(await readFile(packageUrl, "utf8"));

const requestedVersion = process.env.RECAPPI_CLI_VERSION?.trim();
const tagVersion = process.env.GITHUB_REF_NAME?.startsWith("recappi-v")
  ? process.env.GITHUB_REF_NAME.slice("recappi-v".length)
  : "";

const resolvedVersion =
  requestedVersion || tagVersion || resolveNextStableVersion(pkg.name, pkg.version);

pkg.version = resolvedVersion;
await writeFile(packageUrl, `${JSON.stringify(pkg, null, 2)}\n`);

console.log(`Publishing ${pkg.name}@${resolvedVersion}`);
if (process.env.GITHUB_OUTPUT) {
  await appendFile(process.env.GITHUB_OUTPUT, `version=${resolvedVersion}\n`);
}

function resolveNextStableVersion(packageName, packageVersion) {
  const publishedVersions = getPublishedVersions(packageName);
  const baseVersion = stripPrerelease(packageVersion);
  if (!publishedVersions.includes(baseVersion)) {
    return baseVersion;
  }

  const latestStable = publishedVersions
    .filter((version) => !version.includes("-"))
    .sort(compareSemver)
    .at(-1);

  return bumpPatch(latestStable ?? baseVersion);
}

function getPublishedVersions(packageName) {
  const result = spawnSync("npm", ["view", packageName, "versions", "--json"], {
    encoding: "utf8",
    stdio: "pipe",
  });
  if (result.status !== 0) {
    if (result.stderr.includes("E404") || result.stdout.includes("E404")) return [];
    process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  }

  const parsed = JSON.parse(result.stdout);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function stripPrerelease(version) {
  return version.split("-")[0];
}

function bumpPatch(version) {
  const parsed = parseSemver(version);
  return `${parsed.major}.${parsed.minor}.${parsed.patch + 1}`;
}

function compareSemver(a, b) {
  const left = parseSemver(a);
  const right = parseSemver(b);
  return left.major - right.major || left.minor - right.minor || left.patch - right.patch;
}

function parseSemver(version) {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-.+)?$/.exec(version);
  if (!match) throw new Error(`Invalid semver version: ${version}`);
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  };
}
