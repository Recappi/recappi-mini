// Opt-in hardware smoke: captures system audio + microphone for three seconds.
// Uses an isolated account and only saves locally; never uploads captured audio.
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

if (process.platform !== "win32") throw new Error("Run this hardware check on Windows.");
const root = process.env.RECAPPI_RECORDINGS_DIR ?? mkdtempSync(join(tmpdir(), "recappi-hardware-"));
mkdirSync(root, { recursive: true });
const child = spawn(
  process.execPath,
  [fileURLToPath(new URL("../dist/windows-sidecar.js", import.meta.url))],
  {
    stdio: ["pipe", "pipe", "inherit"],
    windowsHide: true,
    env: { ...process.env, RECAPPI_RECORDINGS_DIR: root },
  },
);
const pending = new Map();
let nextId = 0;
const lines = createInterface({ input: child.stdout });
lines.on("line", (line) => {
  const message = JSON.parse(line);
  const entry = pending.get(message.id);
  if (!entry) return;
  pending.delete(message.id);
  clearTimeout(entry.timer);
  if (message.error) entry.reject(new Error(message.error.message));
  else entry.resolve(message.result);
});
child.once("exit", (code) => {
  for (const entry of pending.values()) {
    clearTimeout(entry.timer);
    entry.reject(new Error(`Helper exited: ${code}`));
  }
  pending.clear();
});
const request = (method, params) =>
  new Promise((resolve, reject) => {
    const id = ++nextId;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out: ${method}`));
    }, 15000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });

try {
  const account = { backendOrigin: "https://example.invalid", userId: "windows-hardware-smoke" };
  const handshake = await request("recappi.handshake", {
    protocolVersion: 1,
    client: { name: "smoke", version: "1" },
    account,
    capabilities: ["recording.capture"],
  });
  const started = await request("recappi.recording.start", {
    account,
    options: {
      includeSystemAudio: !process.argv.includes("--microphone-only"),
      includeMicrophone: !process.argv.includes("--system-only"),
      liveCaptions: false,
    },
  });
  if (process.argv.includes("--tone")) {
    const tone = Buffer.alloc(44 + 48000 * 2 * 2);
    tone.write("RIFF");
    tone.writeUInt32LE(tone.length - 8, 4);
    tone.write("WAVEfmt ", 8);
    tone.writeUInt32LE(16, 16);
    tone.writeUInt16LE(1, 20);
    tone.writeUInt16LE(1, 22);
    tone.writeUInt32LE(48000, 24);
    tone.writeUInt32LE(96000, 28);
    tone.writeUInt16LE(2, 32);
    tone.writeUInt16LE(16, 34);
    tone.write("data", 36);
    tone.writeUInt32LE(tone.length - 44, 40);
    for (let i = 0; i < 96000; i++)
      tone.writeInt16LE(Math.round(Math.sin((i * Math.PI * 2 * 440) / 48000) * 1000), 44 + i * 2);
    const tonePath = join(root, "test-tone.wav");
    writeFileSync(tonePath, tone);
    const player = spawn(
      "powershell.exe",
      [
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "$player = New-Object System.Media.SoundPlayer; $player.SoundLocation = $env:RECAPPI_SMOKE_TONE; $player.PlaySync()",
      ],
      {
        windowsHide: true,
        stdio: "ignore",
        env: { ...process.env, RECAPPI_SMOKE_TONE: tonePath },
      },
    );
    player.once("error", (error) => console.error(error.message));
  }
  await new Promise((resolve) => setTimeout(resolve, 3000));
  const stopped = await request("recappi.recording.stop", { sessionId: started.sessionId });
  const artifact = stopped.artifacts[0];
  const wav = readFileSync(artifact.metadata.audioPath);
  if (
    wav.toString("ascii", 0, 4) !== "RIFF" ||
    wav.readUInt32LE(40) !== wav.length - 44 ||
    wav.length <= 44
  ) {
    throw new Error("Invalid or empty WAV capture.");
  }
  let peak = 0;
  for (let i = 44; i < wav.length; i += 2) peak = Math.max(peak, Math.abs(wav.readInt16LE(i)));
  if (process.argv.includes("--tone") && peak === 0)
    throw new Error("Loopback did not capture the test tone.");
  console.log(
    JSON.stringify(
      { helper: handshake.sidecar, state: stopped.state, ...artifact.metadata, peak },
      null,
      2,
    ),
  );
} finally {
  child.stdin.end();
  const timer = setTimeout(() => child.kill(), 2000);
  timer.unref();
  child.once("exit", () => clearTimeout(timer));
}
