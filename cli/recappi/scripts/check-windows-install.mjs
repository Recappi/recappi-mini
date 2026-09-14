import { spawnSync } from "node:child_process";
import { access, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runPackageManager } from "../../helpers/package-manager.mjs";

if (process.platform !== "win32") throw new Error("Run Windows installation checks on Windows.");
const root = await mkdtemp(join(tmpdir(), "recappi-windows-install-"));
const cliDirectory = fileURLToPath(new URL("..", import.meta.url));
const helperDirectory = fileURLToPath(
  new URL(`../../helpers/win32-${process.arch}`, import.meta.url),
);
function check(result, description) {
  if (result.status !== 0)
    throw new Error(`${description}: ${result.error?.message ?? result.stderr}`);
  return result;
}
try {
  const pack = (cwd) => {
    const result = check(
      runPackageManager("npm", ["pack", "--json", "--pack-destination", root], {
        cwd,
        encoding: "utf8",
      }),
      "npm pack failed",
    );
    return join(root, JSON.parse(result.stdout)[0].filename);
  };
  const cliTarball = pack(cliDirectory);
  const helperTarball = pack(helperDirectory);
  const consumer = join(root, "consumer");
  await mkdir(consumer);
  check(
    runPackageManager(
      "npm",
      ["install", cliTarball, helperTarball, "--ignore-scripts", "--no-audit", "--no-fund"],
      { cwd: consumer, encoding: "utf8" },
    ),
    "Installation failed",
  );
  const installed = join(consumer, "node_modules", "recappi", "dist");
  const native = join(
    consumer,
    "node_modules",
    `recappi-helper-win32-${process.arch}`,
    "RecappiAudioCapture.exe",
  );
  await access(native);
  const probe = check(
    spawnSync(native, ["--version"], { encoding: "utf8", windowsHide: true }),
    "Native helper could not launch",
  );
  if (probe.stdout.trim() !== "recappi-windows-capture/1")
    throw new Error("Unexpected native helper version");
  check(
    spawnSync(process.execPath, [join(installed, "index.js"), "--help"], {
      encoding: "utf8",
      windowsHide: true,
    }),
    "Installed CLI could not launch",
  );
  const requests = [
    {
      jsonrpc: "2.0",
      id: 1,
      method: "recappi.handshake",
      params: {
        protocolVersion: 1,
        client: { name: "install-check", version: "1" },
        capabilities: ["recording.capture"],
      },
    },
    { jsonrpc: "2.0", id: 2, method: "recappi.recording.sources.list", params: {} },
  ];
  const handshake = check(
    spawnSync(process.execPath, [join(installed, "windows-sidecar.js")], {
      encoding: "utf8",
      windowsHide: true,
      input: requests.map((request) => JSON.stringify(request)).join("\n") + "\n",
      timeout: 10000,
    }),
    "Installed sidecar failed",
  );
  const replies = handshake.stdout
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  if (
    !replies.find((reply) => reply.id === 1)?.result?.capabilities?.includes("recording.capture") ||
    replies.find((reply) => reply.id === 2)?.result?.sources?.[0]?.id !== "system"
  ) {
    throw new Error(`Installed helper protocol check failed: ${handshake.stdout}`);
  }
  console.log("Windows isolated package installation, native launch and sidecar handshake passed.");
} finally {
  await rm(root, { recursive: true, force: true });
}
