import { createInterface } from "node:readline";
import { PassThrough } from "node:stream";
import { describe, expect, it } from "vitest";
import {
  SIDECAR_PROTOCOL_VERSION,
  sidecarRequestSchema,
  type SidecarRequest,
} from "../../packages/contracts/src/index";
import { defaultSidecarHandshakeParams, MiniSidecarClient } from "../src/sidecar";

describe("Mini sidecar JSON-RPC client", () => {
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
    const fake = createFakeSidecar(async (request, write) => {
      methods.push(request.method);
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
        account: { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
        options: {
          includeSystemAudio: true,
          includeMicrophone: true,
          liveCaptions: true,
          translationLanguage: "zh",
          title: "CLI smoke",
        },
      });
      const stopped = await fake.client.stopRecording({ sessionId: started.sessionId });

      expect(methods).toEqual(["recappi.recording.start", "recappi.recording.stop"]);
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
            { name: "screen_recording", status: "unknown", hint: "Open System Settings." },
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
          { name: "screen_recording", status: "unknown", hint: "Open System Settings." },
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
      if (event.type === "local_artifact.upserted") {
        expect(event.artifact.kind).toBe("live_caption_draft");
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
          type: "local_artifact.upserted",
          sessionId: "sidecar_session_1",
          artifact: {
            kind: "live_caption_draft",
            localPath: "/tmp/live-captions.json",
          },
        },
      });

      await tick();
      expect(events).toEqual(["live_caption.delta", "local_artifact.upserted"]);
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
