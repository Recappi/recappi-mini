import { createInterface } from "node:readline";
import { PassThrough } from "node:stream";
import { describe, expect, it } from "vitest";
import {
  SIDECAR_PROTOCOL_VERSION,
  sidecarRequestSchema,
  type SidecarRequest,
} from "../../packages/contracts/src/index";
import {
  defaultSidecarHandshakeParams,
  isLaunchServicesAppCommand,
  launchServicesOpenArgs,
  MiniSidecarClient,
} from "../src/sidecar";

describe("Mini sidecar JSON-RPC client", () => {
  it("detects LaunchServices app helpers and builds stable open args", () => {
    expect(isLaunchServicesAppCommand("/Applications/Recappi Recorder.app", "darwin")).toBe(true);
    expect(isLaunchServicesAppCommand("/usr/local/bin/RecappiMiniSidecar", "darwin")).toBe(false);
    expect(isLaunchServicesAppCommand("C:/RecappiMiniSidecar.app", "win32")).toBe(false);

    expect(
      launchServicesOpenArgs(
        "/Applications/Recappi Recorder.app",
        {
          stdin: "/tmp/recappi/stdin.fifo",
          stdout: "/tmp/recappi/stdout.fifo",
          stderr: "/tmp/recappi/stderr.log",
        },
        ["--log-level", "debug"],
      ),
    ).toEqual([
      "-W",
      "-n",
      "-g",
      "--stdin",
      "/tmp/recappi/stdin.fifo",
      "--stdout",
      "/tmp/recappi/stdout.fifo",
      "--stderr",
      "/tmp/recappi/stderr.log",
      "/Applications/Recappi Recorder.app",
      "--args",
      "--log-level",
      "debug",
    ]);
  });

  it("handshakes with protocol version, capabilities, and account partition", async () => {
    const fake = createFakeSidecar(async (request, write) => {
      expect(request).toMatchObject({
        jsonrpc: "2.0",
        method: "recappi.handshake",
        params: {
          protocolVersion: SIDECAR_PROTOCOL_VERSION,
          account: {
            backendOrigin: "https://recordmeet.ing",
            userId: "user_123",
          },
          capabilities: ["recording.capture", "live_captions.stream"],
        },
      });
      write({
        jsonrpc: "2.0",
        id: request.id,
        result: {
          protocolVersion: SIDECAR_PROTOCOL_VERSION,
          sidecar: { name: "recappi-mini-sidecar", version: "1.0.0" },
          capabilities: ["recording.capture", "live_captions.stream"],
        },
      });
    });

    try {
      const result = await fake.client.handshake(
        defaultSidecarHandshakeParams({
          client: { name: "recappi-cli", version: "0.1.0" },
          account: {
            backendOrigin: "https://recordmeet.ing",
            userId: "user_123",
            email: "agent@example.com",
          },
          capabilities: ["recording.capture", "live_captions.stream"],
        }),
      );

      expect(result.sidecar.name).toBe("recappi-mini-sidecar");
      expect(result.capabilities).toEqual(["recording.capture", "live_captions.stream"]);
    } finally {
      fake.close();
    }
  });

  it("starts and stops recording sessions over line-delimited JSON-RPC", async () => {
    const methods: string[] = [];
    const requests: SidecarRequest[] = [];
    const fake = createFakeSidecar(async (request, write) => {
      methods.push(request.method);
      requests.push(request);
      if (request.method === "recappi.recording.start") {
        write({
          jsonrpc: "2.0",
          id: request.id,
          result: {
            sessionId: "sidecar_session_1",
            state: "recording",
            localSessionRef: "2026-06-25_150000",
          },
        });
      }
      if (request.method === "recappi.recording.stop") {
        write({
          jsonrpc: "2.0",
          id: request.id,
          result: {
            sessionId: "sidecar_session_1",
            state: "completed",
            recordingId: "rec_123",
            localSessionRef: "2026-06-25_150000",
            artifacts: [
              {
                kind: "recording_session",
                localPath: "/Users/pengx17/Documents/Recappi Mini/2026-06-25_150000",
                remoteId: "rec_123",
              },
            ],
          },
        });
      }
    });

    try {
      const started = await fake.client.startRecording({
        account: {
          backendOrigin: "https://recordmeet.ing",
          userId: "user_123",
          authToken: "token",
        },
        options: {
          includeSystemAudio: true,
          includeMicrophone: true,
          targetBundleId: "com.apple.Safari",
          microphoneDeviceId: "mic_default",
          liveCaptions: true,
          translationLanguage: "zh",
          title: "CLI smoke",
        },
      });
      const stopped = await fake.client.stopRecording({ sessionId: started.sessionId });

      expect(methods).toEqual(["recappi.recording.start", "recappi.recording.stop"]);
      expect(requests[0]).toMatchObject({
        params: {
          account: {
            backendOrigin: "https://recordmeet.ing",
            userId: "user_123",
            authToken: "token",
          },
        },
      });
      expect(started).toMatchObject({ sessionId: "sidecar_session_1", state: "recording" });
      expect(stopped).toMatchObject({
        sessionId: "sidecar_session_1",
        state: "completed",
        recordingId: "rec_123",
      });
      expect(stopped.artifacts?.[0]?.kind).toBe("recording_session");
    } finally {
      fake.close();
    }
  });

  it("starts/stops setup level previews and parses preview level events", async () => {
    const methods: string[] = [];
    const events: string[] = [];
    const fake = createFakeSidecar(async (request, write) => {
      methods.push(request.method);
      if (request.method === "recappi.recording.level_preview.start") {
        expect(request.params).toMatchObject({
          options: {
            includeSystemAudio: true,
            includeMicrophone: true,
            targetBundleId: "com.apple.Safari",
            microphoneDeviceId: "mic_default",
          },
        });
        write({
          jsonrpc: "2.0",
          id: request.id,
          result: {
            previewId: "preview_1",
          },
        });
        write({
          jsonrpc: "2.0",
          method: "recappi.event",
          params: {
            type: "audio.level",
            previewId: "preview_1",
            input: "system",
            sourceId: "app:com.apple.Safari",
            rmsDb: -18,
            atMs: 240,
          },
        });
      }
      if (request.method === "recappi.recording.level_preview.stop") {
        expect(request.params).toMatchObject({ previewId: "preview_1" });
        write({
          jsonrpc: "2.0",
          id: request.id,
          result: {
            previewId: "preview_1",
            state: "stopped",
          },
        });
      }
    });
    const unsubscribe = fake.client.onEvent((event) => {
      events.push(event.type);
      if (event.type === "audio.level") {
        expect(event.previewId).toBe("preview_1");
        expect(event.sessionId).toBeUndefined();
        expect(event.sourceId).toBe("app:com.apple.Safari");
        expect(event.rmsDb).toBe(-18);
      }
    });

    try {
      const started = await fake.client.startLevelPreview({
        options: {
          includeSystemAudio: true,
          includeMicrophone: true,
          targetBundleId: "com.apple.Safari",
          microphoneDeviceId: "mic_default",
          liveCaptions: false,
        },
      });
      await tick();
      const stopped = await fake.client.stopLevelPreview({ previewId: started.previewId });

      expect(started.previewId).toBe("preview_1");
      expect(stopped).toEqual({ previewId: "preview_1", state: "stopped" });
      expect(methods).toEqual([
        "recappi.recording.level_preview.start",
        "recappi.recording.level_preview.stop",
      ]);
      expect(events).toEqual(["audio.level"]);
    } finally {
      unsubscribe();
      fake.close();
    }
  });

  it("lists helper-backed recording sources and microphone devices", async () => {
    const methods: string[] = [];
    const fake = createFakeSidecar(async (request, write) => {
      methods.push(request.method);
      if (request.method === "recappi.recording.sources.list") {
        write({
          jsonrpc: "2.0",
          id: request.id,
          result: {
            sources: [
              { id: "system", kind: "system", label: "System audio · all apps" },
              {
                id: "app:com.apple.Safari",
                kind: "app",
                label: "Safari",
                appName: "Safari",
                bundleId: "com.apple.Safari",
              },
            ],
          },
        });
      }
      if (request.method === "recappi.recording.microphones.list") {
        write({
          jsonrpc: "2.0",
          id: request.id,
          result: {
            microphones: [{ id: "mic_default", label: "MacBook Pro Microphone", isDefault: true }],
          },
        });
      }
    });

    try {
      await expect(fake.client.listRecordingSources()).resolves.toMatchObject({
        sources: [
          { id: "system", kind: "system" },
          { kind: "app", label: "Safari", bundleId: "com.apple.Safari" },
        ],
      });
      await expect(fake.client.listMicrophones()).resolves.toMatchObject({
        microphones: [{ id: "mic_default", isDefault: true }],
      });
      expect(methods).toEqual([
        "recappi.recording.sources.list",
        "recappi.recording.microphones.list",
      ]);
    } finally {
      fake.close();
    }
  });

  it("checks permissions before recording", async () => {
    const fake = createFakeSidecar(async (request, write) => {
      expect(request).toMatchObject({
        method: "recappi.permissions.status",
        params: {
          options: {
            includeSystemAudio: true,
            includeMicrophone: true,
            liveCaptions: false,
          },
        },
      });
      write({
        jsonrpc: "2.0",
        id: request.id,
        result: {
          permissions: [
            {
              name: "screen_recording",
              status: "unknown",
              hint: "Open System Settings.",
              requiresProcessRestart: true,
            },
            { name: "microphone", status: "granted" },
          ],
        },
      });
    });

    try {
      await expect(
        fake.client.getPermissionStatus({
          options: { includeSystemAudio: true, includeMicrophone: true, liveCaptions: false },
        }),
      ).resolves.toMatchObject({
        permissions: [
          {
            name: "screen_recording",
            status: "unknown",
            hint: "Open System Settings.",
            requiresProcessRestart: true,
          },
          { name: "microphone", status: "granted" },
        ],
      });
    } finally {
      fake.close();
    }
  });

  it("parses live caption and local artifact notifications", async () => {
    const fake = createFakeSidecar(async () => {});
    const events: string[] = [];
    const unsubscribe = fake.client.onEvent((event) => {
      events.push(event.type);
      if (event.type === "live_caption.delta") {
        expect(event.text).toBe("hello");
        expect(event.stream).toBe("source");
      }
      if (event.type === "live_caption.status") {
        expect(event.status).toBe("reconnecting");
        expect(event.message).toBe("Live captions connection dropped. Reconnecting in 1s.");
      }
      if (event.type === "local_artifact.upserted") {
        expect(event.artifact.kind).toBe("live_caption_draft");
      }
      if (event.type === "audio.level") {
        expect(event.input).toBe("system");
        expect(event.rmsDb).toBeCloseTo(-6.02);
        expect(event.atMs).toBe(180);
      }
    });

    try {
      fake.write({
        jsonrpc: "2.0",
        method: "recappi.event",
        params: {
          type: "live_caption.delta",
          sessionId: "sidecar_session_1",
          stream: "source",
          text: "hello",
          isFinal: false,
          segmentId: "draft-1",
          language: "en",
          atMs: 123,
        },
      });
      fake.write({
        jsonrpc: "2.0",
        method: "recappi.event",
        params: {
          type: "live_caption.status",
          sessionId: "sidecar_session_1",
          status: "reconnecting",
          message: "Live captions connection dropped. Reconnecting in 1s.",
        },
      });
      fake.write({
        jsonrpc: "2.0",
        method: "recappi.event",
        params: {
          type: "audio.level",
          sessionId: "sidecar_session_1",
          input: "system",
          rmsDb: -6.02,
          atMs: 180,
        },
      });
      fake.write({
        jsonrpc: "2.0",
        method: "recappi.event",
        params: {
          type: "local_artifact.upserted",
          sessionId: "sidecar_session_1",
          artifact: {
            kind: "live_caption_draft",
            localPath: "/tmp/live-captions.json",
          },
        },
      });

      await tick();
      expect(events).toEqual([
        "live_caption.delta",
        "live_caption.status",
        "audio.level",
        "local_artifact.upserted",
      ]);
    } finally {
      unsubscribe();
      fake.close();
    }
  });

  it("rejects JSON-RPC errors without hanging later requests", async () => {
    let calls = 0;
    const fake = createFakeSidecar(async (request, write) => {
      calls += 1;
      if (calls === 1) {
        write({
          jsonrpc: "2.0",
          id: request.id,
          error: { code: -32001, message: "microphone permission denied" },
        });
        return;
      }
      write({
        jsonrpc: "2.0",
        id: request.id,
        result: {
          sessionId: "sidecar_session_1",
          state: "idle",
        },
      });
    });

    try {
      await expect(
        fake.client.startRecording({
          account: { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
          options: { includeSystemAudio: true, includeMicrophone: true, liveCaptions: false },
        }),
      ).rejects.toThrow("microphone permission denied");
      await expect(
        fake.client.getRecordingStatus({ sessionId: "sidecar_session_1" }),
      ).resolves.toMatchObject({ sessionId: "sidecar_session_1", state: "idle" });
    } finally {
      fake.close();
    }
  });

  it("maps sidecar CLI error metadata onto stable CLI error codes", async () => {
    const fake = createFakeSidecar(async (request, write) => {
      write({
        jsonrpc: "2.0",
        id: request.id,
        error: {
          code: -32020,
          message: "Microphone access is required before the CLI can record microphone audio.",
          data: {
            cliCode: "record.permission_required",
            permission: "microphone",
            recovery: "Open System Settings > Privacy & Security > Microphone, then retry.",
          },
        },
      });
    });

    try {
      await expect(
        fake.client.startRecording({
          account: { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
          options: { includeSystemAudio: false, includeMicrophone: true, liveCaptions: false },
        }),
      ).rejects.toMatchObject({
        descriptor: {
          code: "record.permission_required",
          hint: "Open System Settings > Privacy & Security > Microphone, then retry.",
          exitCode: 2,
        },
      });
    } finally {
      fake.close();
    }
  });
});

function createFakeSidecar(
  onRequest: (request: SidecarRequest, write: (message: unknown) => void) => void | Promise<void>,
): {
  client: MiniSidecarClient;
  write: (message: unknown) => void;
  close: () => void;
} {
  const clientToSidecar = new PassThrough();
  const sidecarToClient = new PassThrough();
  const reader = createInterface({ input: clientToSidecar });
  const write = (message: unknown) => {
    sidecarToClient.write(`${JSON.stringify(message)}\n`);
  };
  reader.on("line", (line) => {
    const request = sidecarRequestSchema.parse(JSON.parse(line));
    void onRequest(request, write);
  });
  const client = new MiniSidecarClient({
    input: clientToSidecar,
    output: sidecarToClient,
    requestTimeoutMs: 500,
  });
  return {
    client,
    write,
    close: () => {
      client.close();
      reader.close();
      clientToSidecar.destroy();
      sidecarToClient.destroy();
    },
  };
}

function tick(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}
