// Opt-in local hardware test. Two test processes play different quiet tones;
// process capture must include the selected tone and reject the other one.
// No cloud requests, credentials, or user audio files are involved.
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

if (process.platform !== "win32") throw new Error("Run this check on Windows.");
const root = mkdtempSync(join(tmpdir(), "recappi-inputs-"));
const players = [];
const sidecar = spawn(
  process.execPath,
  [fileURLToPath(new URL("../dist/windows-sidecar.js", import.meta.url))],
  {
    windowsHide: true,
    stdio: ["pipe", "pipe", "inherit"],
    env: { ...process.env, RECAPPI_RECORDINGS_DIR: root },
  },
);
const exited = once(sidecar, "close");
const pending = new Map();
const events = [];
let nextId = 0;
const lines = createInterface({ input: sidecar.stdout });
lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "recappi.event") events.push(message.params);
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  clearTimeout(request.timer);
  if (message.error) request.reject(new Error(message.error.message));
  else request.resolve(message.result);
});
sidecar.on("close", () => {
  for (const request of pending.values()) {
    clearTimeout(request.timer);
    request.reject(new Error("Sidecar exited"));
  }
  pending.clear();
});
function request(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out: ${method}`));
    }, 15000);
    pending.set(id, { resolve, reject, timer });
    sidecar.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
}
function tone(path, frequency) {
  const audio = Buffer.alloc(44 + 48000 * 2);
  audio.write("RIFF");
  audio.writeUInt32LE(audio.length - 8, 4);
  audio.write("WAVEfmt ", 8);
  audio.writeUInt32LE(16, 16);
  audio.writeUInt16LE(1, 20);
  audio.writeUInt16LE(1, 22);
  audio.writeUInt32LE(48000, 24);
  audio.writeUInt32LE(96000, 28);
  audio.writeUInt16LE(2, 32);
  audio.writeUInt16LE(16, 34);
  audio.write("data", 36);
  audio.writeUInt32LE(audio.length - 44, 40);
  for (let i = 0; i < 48000; i++)
    audio.writeInt16LE(
      Math.round(Math.sin((2 * Math.PI * frequency * i) / 48000) * 1800),
      44 + i * 2,
    );
  writeFileSync(path, audio);
}
async function play(frequency) {
  const path = join(root, `tone-${frequency}.wav`);
  tone(path, frequency);
  const player = spawn(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-File",
      fileURLToPath(new URL("./windows-tone-player.ps1", import.meta.url)),
      "-AudioPath",
      path,
    ],
    {
      windowsHide: true,
      stdio: ["pipe", "pipe", "inherit"],
    },
  );
  const closed = once(player, "close");
  players.push({ player, closed });
  const output = createInterface({ input: player.stdout });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("Tone player timed out"));
    }, 8000);
    const onClose = () => {
      cleanup();
      reject(new Error("Tone player exited before playing"));
    };
    const cleanup = () => {
      clearTimeout(timer);
      player.off("close", onClose);
      output.close();
    };
    player.once("close", onClose);
    output.once("line", (line) => {
      cleanup();
      line === "ready" ? resolve() : reject(new Error(line));
    });
  });
  return player.pid;
}
function magnitude(wav, frequency) {
  const rate = wav.readUInt32LE(24);
  // Skip startup and use one whole second, eliminating leakage between integer frequencies.
  const count = rate;
  const start = 44 + rate * 2;
  assert(wav.length >= start + count * 2, "Recording must contain at least two seconds");
  let real = 0,
    imag = 0;
  for (let i = 0; i < count; i++) {
    const sample = wav.readInt16LE(start + i * 2) / 32768;
    real += sample * Math.cos((2 * Math.PI * frequency * i) / rate);
    imag += sample * Math.sin((2 * Math.PI * frequency * i) / rate);
  }
  return (2 * Math.hypot(real, imag)) / count;
}
try {
  const native = fileURLToPath(
    new URL(`../../helpers/win32-${process.arch}/RecappiAudioCapture.exe`, import.meta.url),
  );
  for (const args of [
    ["--process-id", "2147483647", "--no-microphone"],
    ["--microphone-device", "recappi-missing-device-test", "--no-system-audio"],
  ]) {
    const invalid = spawnSync(native, args, {
      input: "",
      encoding: "utf8",
      windowsHide: true,
      timeout: 8000,
    });
    assert.equal(invalid.status, 1, "Invalid selection must fail");
    assert(
      !invalid.stdout.includes('"type":"ready"'),
      "Invalid selection must never start fallback capture",
    );
    assert(invalid.stdout.includes('"type":"error"'));
  }
  const account = { backendOrigin: "https://example.invalid", userId: "input-isolation-smoke" };
  await request("recappi.handshake", {
    protocolVersion: 1,
    client: { name: "input-smoke", version: "1" },
    account,
    capabilities: [],
  });
  const { microphones } = await request("recappi.recording.microphones.list");
  assert(Array.isArray(microphones));
  const pid = await play(443);
  await play(997);
  const { sources } = await request("recappi.recording.sources.list");
  assert(
    sources.some((source) => source.processId === pid),
    "Playing process must be discoverable",
  );
  const started = await request("recappi.recording.start", {
    account,
    options: {
      includeSystemAudio: true,
      includeMicrophone: false,
      targetProcessId: pid,
      liveCaptions: false,
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 3200));
  const stopped = await request("recappi.recording.stop", { sessionId: started.sessionId });
  assert.equal(stopped.state, "completed");
  const wav = readFileSync(stopped.artifacts[0].metadata.audioPath);
  const selected = magnitude(wav, 443);
  const excluded = magnitude(wav, 997);
  assert(selected > 0.001, `Selected app tone missing: ${selected}`);
  assert(excluded < selected * 0.01, `Other app leaked: selected=${selected}, other=${excluded}`);
  assert(
    events.some(
      (event) =>
        event.type === "audio.level" &&
        event.input === "system" &&
        event.sourceId === `process:${pid}` &&
        event.rmsDb > -80,
    ),
  );
  console.log(
    JSON.stringify({
      ok: true,
      selectedTone: selected,
      excludedTone: excluded,
      isolationDb: 20 * Math.log10(selected / Math.max(excluded, 1e-12)),
      microphones: microphones.length,
      root,
    }),
  );
} finally {
  for (const { player } of players) player.stdin.end();
  sidecar.stdin.end();
  const timer = setTimeout(() => {
    sidecar.kill();
    for (const { player } of players) player.kill();
  }, 3000);
  try {
    await Promise.all([exited, ...players.map((entry) => entry.closed)]);
  } finally {
    clearTimeout(timer);
  }
}
