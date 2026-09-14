import { once } from "node:events";
import { WebSocketServer, type WebSocket } from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { sidecarEventSchema, type SidecarEvent } from "../../packages/contracts/src/index";
import { CaptionPcmEncoder, WindowsLiveCaptions } from "../src/windowsLiveCaptions";

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});
const account = {
  backendOrigin: "https://example.com",
  userId: "u1",
  authToken: "test-account-token",
};
const options = { includeSystemAudio: true, includeMicrophone: true, liveCaptions: true };

async function setup(
  overrides: {
    translationLanguage?: string;
    response?: () => Promise<Response>;
    delays?: number[];
    holdClaim?: Promise<void>;
  } = {},
) {
  const server = new WebSocketServer({ port: 0, host: "127.0.0.1" });
  await once(server, "listening");
  cleanups.push(async () => {
    for (const client of server.clients) client.terminate();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("No server address");
  const received: Record<string, any>[] = [];
  const connections: WebSocket[] = [];
  const headers: unknown[] = [];
  server.on("connection", (socket, request) => {
    connections.push(socket);
    headers.push(request.headers);
    socket.on("message", (data) => received.push(JSON.parse(data.toString())));
    socket.send(JSON.stringify({ type: "session.created" }));
  });
  const events: SidecarEvent[] = [];
  const fetchImpl = vi.fn(
    overrides.response ??
      (async () => {
        await overrides.holdClaim;
        return Response.json({
          sessionId: "claim-1",
          websocketUrl: `ws://127.0.0.1:${address.port}`,
          token: "short-lived-token",
          tokenType: "Bearer",
        });
      }),
  );
  const stream = new WindowsLiveCaptions({
    account,
    options: { ...options, translationLanguage: overrides.translationLanguage },
    sessionId: "local-1",
    emit: (event) => {
      sidecarEventSchema.parse(event);
      events.push(event);
    },
    fetchImpl,
    reconnectDelaysMs: overrides.delays ?? [1, 2],
    drainTimeoutMs: 100,
  });
  cleanups.push(() => stream.stop());
  return { stream, events, received, connections, headers, fetchImpl, server };
}

describe("Windows live captions", () => {
  it("bounds audio buffered during a slow session claim to the last five seconds", async () => {
    let release!: () => void;
    const test = await setup({
      holdClaim: new Promise((resolve) => {
        release = resolve;
      }),
    });
    for (let i = 0; i < 100; i++) test.stream.append(new Float32Array(4800).fill(0.1));
    expect(test.received).toHaveLength(0);
    release();
    await vi.waitFor(() =>
      expect(
        test.received.filter((event) => event.type === "input_audio_buffer.append"),
      ).toHaveLength(50),
    );
    const total = test.received
      .filter((event) => event.audio)
      .reduce((sum, event) => sum + Buffer.from(event.audio, "base64").length, 0);
    expect(total).toBe(24000 * 2 * 5);
  });

  it("bounds retries even when the socket opens but every session immediately fails", async () => {
    const test = await setup();
    test.server.on("connection", (socket) =>
      socket.send(JSON.stringify({ type: "error", error: { code: "session_expired" } })),
    );
    await vi.waitFor(() =>
      expect(test.events).toContainEqual(expect.objectContaining({ status: "stopped" })),
    );
    expect(test.connections).toHaveLength(3);
    expect(test.fetchImpl).toHaveBeenCalledTimes(3);
  });
  it("resamples continuous PCM across chunk boundaries and sanitizes non-finite samples", () => {
    const encoder = new CaptionPcmEncoder();
    expect(encoder.encode(new Float32Array([1]))).toHaveLength(0);
    const bytes = encoder.encode(new Float32Array([1, -1, -1, NaN, Infinity, 0.5]));
    expect([0, 1, 2].map((i) => bytes.readInt16LE(i * 2))).toEqual([32767, -32768, 0]);
    expect(encoder.encode(new Float32Array([0.5])).readInt16LE(0)).toBe(16384);
  });

  it("claims the existing service, authenticates the socket, sends PCM and accumulates/finalizes captions", async () => {
    const test = await setup();
    await vi.waitFor(() =>
      expect(test.events).toContainEqual(
        expect.objectContaining({ type: "live_caption.status", status: "live" }),
      ),
    );
    expect(test.fetchImpl).toHaveBeenCalledWith(
      "https://example.com/api/openai/realtime/sessions",
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: "Bearer test-account-token",
          Origin: account.backendOrigin,
        }),
        body: JSON.stringify({
          mode: "transcription",
          language: "en",
          delay: "low",
          expiresAfterSeconds: 60,
          turnDetection: { type: "none" },
        }),
      }),
    );
    expect(test.headers[0]).toMatchObject({
      authorization: "Bearer short-lived-token",
      origin: account.backendOrigin,
    });
    test.stream.append(new Float32Array(67200).fill(0.25));
    await vi.waitFor(() => expect(test.received).toHaveLength(2));
    expect(test.received[0].type).toBe("input_audio_buffer.append");
    const audio = Buffer.from(test.received[0].audio, "base64");
    expect(audio.length).toBe(67200);
    expect(audio.readInt16LE(0)).toBe(8192);
    expect(test.received[1]).toEqual({ type: "input_audio_buffer.commit" });
    const socket = test.connections[0];
    socket.send(JSON.stringify({ type: "input_audio_buffer.committed", item_id: "turn1" }));
    socket.send(
      JSON.stringify({
        type: "conversation.item.input_audio_transcription.delta",
        item_id: "turn1",
        delta: "Hello",
      }),
    );
    socket.send(
      JSON.stringify({
        type: "conversation.item.input_audio_transcription.delta",
        item_id: "turn1",
        delta: " world",
      }),
    );
    socket.send(
      JSON.stringify({
        type: "conversation.item.input_audio_transcription.completed",
        item_id: "turn1",
        transcript: "Hello world!",
      }),
    );
    await vi.waitFor(() =>
      expect(test.events).toContainEqual(
        expect.objectContaining({
          type: "live_caption.delta",
          text: "Hello world!",
          isFinal: true,
        }),
      ),
    );
    expect(test.events).toContainEqual(
      expect.objectContaining({ text: "Hello world", isFinal: false }),
    );
    await test.stream.stop();
    expect(JSON.stringify(test.events)).not.toContain("token");
  });

  it("commits and drains the final short chunk before closing", async () => {
    const test = await setup();
    await vi.waitFor(() => expect(test.connections).toHaveLength(1));
    await vi.waitFor(() =>
      expect(test.events).toContainEqual(expect.objectContaining({ status: "live" })),
    );
    test.connections[0].on("message", (raw) => {
      if (JSON.parse(raw.toString()).type === "input_audio_buffer.commit") {
        test.connections[0].send(
          JSON.stringify({ type: "input_audio_buffer.committed", item_id: "last" }),
        );
        test.connections[0].send(
          JSON.stringify({
            type: "conversation.item.input_audio_transcription.completed",
            item_id: "last",
            transcript: "Last words",
          }),
        );
      }
    });
    test.stream.append(new Float32Array(480).fill(0.1));
    await test.stream.stop();
    const totalAudio = test.received
      .filter((event) => event.type === "input_audio_buffer.append")
      .reduce((sum, event) => sum + Buffer.from(event.audio, "base64").length, 0);
    expect(totalAudio).toBe(4800);
    expect(test.events).toContainEqual(
      expect.objectContaining({ text: "Last words", isFinal: true }),
    );
  });

  it("supports source/translation events and closes the translation session", async () => {
    const test = await setup({ translationLanguage: "zh-CN" });
    await vi.waitFor(() =>
      expect(test.events).toContainEqual(expect.objectContaining({ status: "live" })),
    );
    const init = test.fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(JSON.parse(String(init[1].body))).toMatchObject({
      mode: "translation",
      targetLanguage: "zh",
      includeSourceTranscript: true,
    });
    test.stream.append(new Float32Array(4800));
    test.connections[0].send(
      JSON.stringify({ type: "session.input_transcript.delta", delta: "Hello" }),
    );
    test.connections[0].send(
      JSON.stringify({ type: "session.output_transcript.delta", delta: "你好" }),
    );
    await vi.waitFor(() =>
      expect(test.events).toContainEqual(
        expect.objectContaining({ stream: "translation", text: "你好" }),
      ),
    );
    await test.stream.stop();
    expect(test.received.map((event) => event.type)).toEqual([
      "session.input_audio_buffer.append",
      "session.close",
    ]);
    expect(test.events).toContainEqual(
      expect.objectContaining({ stream: "source", text: "Hello", isFinal: true }),
    );
    expect(test.events).toContainEqual(
      expect.objectContaining({ stream: "translation", text: "你好", isFinal: true }),
    );
  });

  it("reclaims a session after socket loss and ignores the previous connection", async () => {
    const test = await setup();
    await vi.waitFor(() =>
      expect(test.events).toContainEqual(expect.objectContaining({ status: "live" })),
    );
    test.connections[0].terminate();
    await vi.waitFor(() => expect(test.connections).toHaveLength(2));
    expect(test.fetchImpl).toHaveBeenCalledTimes(2);
    expect(test.events).toContainEqual(expect.objectContaining({ status: "reconnecting" }));
    await test.stream.stop();
  });

  it("stops retrying terminal claim failures without throwing into recording", async () => {
    const test = await setup({
      response: async () => new Response("not authorized", { status: 401 }),
    });
    test.stream.append(new Float32Array(4800));
    await vi.waitFor(() =>
      expect(test.events).toContainEqual(expect.objectContaining({ status: "stopped" })),
    );
    expect(test.fetchImpl).toHaveBeenCalledTimes(1);
    expect(test.events).toContainEqual(
      expect.objectContaining({ type: "error", retryable: false }),
    );
    expect(test.connections).toHaveLength(0);
  });

  it("bounds claim retries and stops reconnecting on unsupported region", async () => {
    const failed = await setup({
      response: async () => new Response("unavailable", { status: 503 }),
    });
    await vi.waitFor(() =>
      expect(failed.events).toContainEqual(expect.objectContaining({ status: "stopped" })),
    );
    expect(failed.fetchImpl).toHaveBeenCalledTimes(3);
    const region = await setup();
    await vi.waitFor(() =>
      expect(region.events).toContainEqual(expect.objectContaining({ status: "live" })),
    );
    region.connections[0].send(
      JSON.stringify({ type: "error", error: { code: "unsupported_country_region_territory" } }),
    );
    await vi.waitFor(() =>
      expect(region.events).toContainEqual(
        expect.objectContaining({ code: "live_caption.unsupported_region", retryable: false }),
      ),
    );
    expect(region.fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("never opens a socket after a claim resolves following stop", async () => {
    let resolveClaim!: (response: Response) => void;
    const test = await setup({
      response: () =>
        new Promise((resolve) => {
          resolveClaim = resolve;
        }),
    });
    await test.stream.stop();
    resolveClaim(
      Response.json({ websocketUrl: "ws://127.0.0.1:1", token: "late", tokenType: "Bearer" }),
    );
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(test.connections).toHaveLength(0);
    expect(test.events.filter((event) => event.type === "error")).toHaveLength(0);
  });
});
