import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { createInterface } from "node:readline";
import { afterEach, describe, expect, it } from "vitest";
import { sidecarResponseSchema, type SidecarEvent } from "../../packages/contracts/src/index";
import { PcmWavWriter, WindowsRecorder, type WindowsCaptureBackend } from "../src/windowsRecorder";
import { parseWavHeader } from "../src/wav";
import { MiniSidecarClient } from "../src/sidecar";
import { runCli } from "../src/cli";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});
const account = {
  backendOrigin: "https://example.com",
  userId: "user-1",
  authToken: "must-not-be-persisted",
};
const options = { includeSystemAudio: true, includeMicrophone: true, liveCaptions: false };

function setup(
  config: { sampleRate?: number; captions?: boolean; captionFailure?: "append" | "stop" } = {},
) {
  const root = mkdtempSync(join(tmpdir(), "recappi-windows-"));
  roots.push(root);
  let callback: (error: Error | null, samples: Float32Array) => void = () => {};
  let starts = 0;
  let stops = 0;
  const events: SidecarEvent[] = [];
  const selections: unknown[] = [];
  const captionSamples: Float32Array[] = [];
  let captionStops = 0;
  let level: Parameters<WindowsCaptureBackend["start"]>[2];
  const recorder = new WindowsRecorder({
    root,
    emit: (event) => events.push(event),
    loadBackend: async () => ({
      listSources: async () => [
        { id: "process:1234", kind: "app", label: "Test app", processId: 1234 },
      ],
      listMicrophones: async () => [{ id: "test-mic", label: "USB microphone", isDefault: true }],
      start: (next, options, onLevel) => {
        starts++;
        selections.push(options);
        level = onLevel;
        callback = next;
        return {
          sampleRate: config.sampleRate ?? 16000,
          channels: 1,
          stop: () => {
            stops++;
          },
        };
      },
    }),
    ...(config.captions
      ? {
          createCaptions: () => ({
            append: (samples: Float32Array) => {
              if (config.captionFailure === "append") throw new Error("caption append failed");
              captionSamples.push(samples);
            },
            stop: async () => {
              captionStops++;
              if (config.captionFailure === "stop") throw new Error("caption close failed");
            },
          }),
        }
      : {}),
  });
  let id = 0;
  async function request(method: string, params: unknown = {}) {
    const result = await recorder.handle({ jsonrpc: "2.0", id: ++id, method, params });
    sidecarResponseSchema.parse(result);
    return result as {
      result?: any;
      error?: { code: number; message: string; data: { cliCode: string } };
    };
  }
  const handshake = () =>
    request("recappi.handshake", {
      protocolVersion: 1,
      client: { name: "test", version: "1" },
      account,
      capabilities: [],
    });
  const start = (overrides = {}) =>
    request("recappi.recording.start", { account, options: { ...options, ...overrides } });
  return {
    root,
    recorder,
    events,
    selections,
    captionSamples,
    get captionStops() {
      return captionStops;
    },
    level: (input: "system" | "microphone", rmsDb: number) => level?.(input, rmsDb),
    request,
    handshake,
    start,
    samples: (values: Float32Array) => callback(null, values),
    fail: () => callback(new Error("device disconnected"), new Float32Array()),
    get starts() {
      return starts;
    },
    get stops() {
      return stops;
    },
  };
}

describe("Windows recording helper", () => {
  it("streams a valid WAV, returns an uploadable artifact and never persists credentials", async () => {
    const test = setup();
    const hello = await test.handshake();
    expect(hello.result.capabilities).toEqual([
      "recording.capture",
      "local_artifacts.index",
      "live_captions.stream",
    ]);
    const start = await test.start();
    const sessionId = start.result.sessionId;
    test.samples(Float32Array.from({ length: 1600 }, (_, i) => Math.sin(i / 10) * 0.25));
    const stop = await test.request("recappi.recording.stop", { sessionId });
    expect(stop.result.state).toBe("completed");
    const artifact = stop.result.artifacts[0];
    const wav = readFileSync(artifact.metadata.audioPath);
    expect(parseWavHeader(wav)).toMatchObject({
      durationMs: 100,
      sampleRate: 16000,
      channels: 1,
      bitsPerSample: 16,
      dataLength: 3200,
    });
    expect(artifact.metadata.sizeBytes).toBe(wav.length);
    expect(readFileSync(join(artifact.localPath, "session.json"), "utf8")).not.toContain(
      account.authToken,
    );
    expect(await test.request("recappi.recording.stop", { sessionId })).toMatchObject({
      result: stop.result,
    });
    expect(test.stops).toBe(1);
    // Queued native callbacks after stop cannot touch the closed file.
    test.samples(new Float32Array([1]));
    expect(readFileSync(artifact.metadata.audioPath)).toEqual(wav);
  });

  it("rejects incompatible options before opening any audio device", async () => {
    const test = setup();
    await test.handshake();
    for (const override of [
      { includeMicrophone: false, includeSystemAudio: false },
      { targetBundleId: "app" },
      { targetProcessId: 1234, includeSystemAudio: false },
      { microphoneDeviceId: "other", includeMicrophone: false },
    ]) {
      expect(await test.start(override)).toMatchObject({
        error: { data: { cliCode: "record.capture_unavailable" } },
      });
    }
    expect(test.starts).toBe(0);
    expect(readdirSync(test.root)).toEqual([]);
  });

  it("lists native inputs and carries process/device selections into capture and physical meters", async () => {
    const test = setup();
    await test.handshake();
    expect(await test.request("recappi.recording.sources.list")).toMatchObject({
      result: { sources: [{ processId: 1234 }] },
    });
    expect(await test.request("recappi.recording.microphones.list")).toMatchObject({
      result: { microphones: [{ id: "test-mic" }] },
    });
    const started = await test.start({ targetProcessId: 1234, microphoneDeviceId: "test-mic" });
    expect(test.selections).toEqual([
      expect.objectContaining({ targetProcessId: 1234, microphoneDeviceId: "test-mic" }),
    ]);
    test.samples(new Float32Array(160));
    test.level("system", -24);
    test.level("microphone", -48);
    expect(test.events).toContainEqual(
      expect.objectContaining({
        type: "audio.level",
        input: "system",
        sourceId: "process:1234",
        rmsDb: -24,
      }),
    );
    expect(test.events).toContainEqual(
      expect.objectContaining({
        type: "audio.level",
        input: "microphone",
        microphoneDeviceId: "test-mic",
        rmsDb: -48,
      }),
    );
    await test.request("recappi.recording.stop", { sessionId: started.result.sessionId });
  });

  it("feeds live PCM to captions while retaining the full WAV and closes captions on stop/disconnect", async () => {
    for (const disconnect of [false, true]) {
      const test = setup({ sampleRate: 48000, captions: true });
      await test.handshake();
      const started = await test.start({ liveCaptions: true });
      const samples = new Float32Array(4800).fill(0.2);
      test.samples(samples);
      expect(test.captionSamples).toEqual([samples]);
      if (disconnect) await test.recorder.shutdown();
      else await test.request("recappi.recording.stop", { sessionId: started.result.sessionId });
      expect(test.captionStops).toBe(1);
      expect(
        parseWavHeader(readFileSync(join(started.result.localSessionRef, "audio.wav"))).durationMs,
      ).toBe(100);
    }
  });

  it("rejects cross-account capture and unknown sessions", async () => {
    const test = setup();
    await test.handshake();
    expect(
      await test.request("recappi.recording.start", {
        account: { ...account, userId: "other" },
        options,
      }),
    ).toHaveProperty("error");
    expect(await test.request("recappi.recording.stop", { sessionId: "other" })).toHaveProperty(
      "error",
    );
    expect(test.starts).toBe(0);
  });

  it.each(["append", "stop"] as const)(
    "preserves a successful local recording when captions %s fails",
    async (captionFailure) => {
      const test = setup({ sampleRate: 48000, captions: true, captionFailure });
      await test.handshake();
      const started = await test.start({ liveCaptions: true });
      test.samples(new Float32Array(4800).fill(0.25));
      const stopped = await test.request("recappi.recording.stop", {
        sessionId: started.result.sessionId,
      });
      expect(stopped.result.state).toBe("completed");
      expect(
        parseWavHeader(readFileSync(stopped.result.artifacts[0].metadata.audioPath)).durationMs,
      ).toBe(100);
      expect(test.events).toContainEqual(expect.objectContaining({ code: "live_caption.failed" }));
      expect(test.events).not.toContainEqual(
        expect.objectContaining({ type: "recording.state", state: "failed" }),
      );
    },
  );

  it("preserves a readable partial recording after device failure or parent disconnect", async () => {
    for (const fail of [true, false]) {
      const test = setup();
      await test.handshake();
      const started = await test.start();
      test.samples(new Float32Array(160));
      if (fail) {
        test.fail();
        await new Promise((resolve) => setTimeout(resolve, 0));
      } else await test.recorder.shutdown();
      const directory = started.result.localSessionRef;
      expect(parseWavHeader(readFileSync(join(directory, "audio.wav"))).durationMs).toBe(10);
      expect(JSON.parse(readFileSync(join(directory, "session.json"), "utf8")).state).toBe(
        "failed",
      );
      expect(test.stops).toBe(1);
      const stopped = await test.request("recappi.recording.stop", {
        sessionId: started.result.sessionId,
      });
      expect(stopped.error?.data.cliCode).toBe("record.capture_failed");
      await test.request("recappi.recording.cancel", { sessionId: started.result.sessionId });
      expect(readFileSync(join(directory, "audio.wav")).length).toBe(364);
    }
  });

  it("does not report an empty recording as success", async () => {
    const test = setup();
    await test.handshake();
    const started = await test.start();
    expect(
      await test.request("recappi.recording.stop", { sessionId: started.result.sessionId }),
    ).toHaveProperty("error");
    expect(test.stops).toBe(1);
  });

  it("can cancel without leaving audio or native capture running", async () => {
    const test = setup();
    await test.handshake();
    const started = await test.start();
    test.samples(new Float32Array(160));
    const params = { sessionId: started.result.sessionId };
    expect(await test.request("recappi.recording.cancel", params)).toMatchObject({
      result: { state: "cancelled", artifacts: [] },
    });
    expect(readdirSync(started.result.localSessionRef)).toEqual(["session.json"]);
    expect(test.stops).toBe(1);
    expect(await test.request("recappi.recording.cancel", params)).toMatchObject({
      result: { state: "cancelled" },
    });
  });

  it("records and uploads the exact WAV bytes through the CLI and JSON-RPC adapter", async () => {
    const test = setup();
    const input = new PassThrough();
    const output = new PassThrough();
    let callback: (error: Error | null, samples: Float32Array) => void = () => {};
    const server = new WindowsRecorder({
      root: test.root,
      emit: (params) =>
        output.write(`${JSON.stringify({ jsonrpc: "2.0", method: "recappi.event", params })}\n`),
      loadBackend: async () => ({
        start: (next) => {
          callback = next;
          return { sampleRate: 16000, channels: 1, stop: () => {} };
        },
      }),
    });
    const lines = createInterface({ input });
    let chain = Promise.resolve();
    lines.on("line", (line) => {
      chain = chain.then(async () => {
        output.write(`${JSON.stringify(await server.handle(JSON.parse(line)))}\n`);
      });
    });
    const client = new MiniSidecarClient({ input, output });
    const uploaded: Buffer[] = [];
    let stdout = "";
    let stderr = "";
    const code = await runCli({
      argv: ["record", "--json", "--sidecar-command", "test-windows-recorder"],
      homeDir: test.root,
      env: { RECAPPI_AUTH_TOKEN: "fake-test-token", RECAPPI_ORIGIN: "https://example.com" },
      stdout: (text) => {
        stdout += text;
      },
      stderr: (text) => {
        stderr += text;
      },
      fetchImpl: async (input, init) => {
        const pathname = new URL(input instanceof Request ? input.url : String(input)).pathname;
        if (pathname === "/api/auth/get-session") return Response.json({ user: { id: "user-1" } });
        if (pathname === "/api/recordings") return Response.json({ id: "rec-1", partSize: 4096 });
        if (pathname.startsWith("/api/recordings/rec-1/parts/")) {
          const bytes = Buffer.from(await new Response(init?.body).arrayBuffer());
          uploaded.push(bytes);
          return Response.json({
            partNumber: uploaded.length,
            etag: `part-${uploaded.length}`,
            sizeBytes: bytes.length,
          });
        }
        if (pathname === "/api/recordings/rec-1/complete")
          return Response.json({ id: "rec-1", status: "ready" });
        if (pathname === "/api/recordings/rec-1/transcribe")
          return Response.json({ jobId: "job-1", status: "queued" });
        throw new Error(`Unexpected request: ${pathname}`);
      },
      recordRuntime: {
        spawnSidecar: () => ({
          client,
          kill: () => {
            client.close();
            input.end();
            output.end();
          },
        }),
        waitForStop: async () => {
          callback(
            null,
            Float32Array.from({ length: 1600 }, (_, i) => Math.sin(i / 10)),
          );
        },
      },
    });
    expect(stderr).not.toContain("error");
    expect(code).toBe(0);
    const envelope = JSON.parse(stdout);
    expect(envelope).toMatchObject({
      ok: true,
      data: { state: "completed", recordingId: "rec-1", jobId: "job-1", live: false },
    });
    const local = readFileSync(envelope.data.artifacts[0].metadata.audioPath);
    expect(Buffer.concat(uploaded)).toEqual(local);
    expect(parseWavHeader(local).durationMs).toBe(100);
  });

  it("maps missing native dependencies to a useful helper error", async () => {
    const recorder = new WindowsRecorder({
      emit: () => {},
      loadBackend: async () => {
        throw new Error("missing native module");
      },
    });
    expect(
      await recorder.handle({
        jsonrpc: "2.0",
        id: 1,
        method: "recappi.handshake",
        params: { protocolVersion: 1, client: { name: "test", version: "1" }, capabilities: [] },
      }),
    ).toMatchObject({ error: { data: { cliCode: "record.helper_unavailable" } } });
  });

  it("clamps non-finite and out-of-range audio and keeps its header valid before close", () => {
    const test = setup();
    const path = join(test.root, "samples.wav");
    const writer = new PcmWavWriter(path, 16000, 1);
    try {
      writer.append(new Float32Array([NaN, Infinity, -2, 2]));
      const wav = readFileSync(path);
      expect(parseWavHeader(wav).dataLength).toBe(8);
      expect([0, 1, 2, 3].map((i) => wav.readInt16LE(44 + i * 2))).toEqual([0, 0, -32768, 32767]);
    } finally {
      writer.close();
    }
  });
});
