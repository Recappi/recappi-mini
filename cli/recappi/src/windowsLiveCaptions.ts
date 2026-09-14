import WebSocket from "ws";
import type {
  SidecarAccount,
  SidecarEvent,
  SidecarRecordingOptions,
} from "../../packages/contracts/src/index";
import { validateOrigin } from "./auth";

export interface WindowsCaptionStream {
  append(samples: Float32Array): void;
  stop(): Promise<void>;
}

// The native helper supplies mono 48 kHz float PCM. The existing realtime
// service accepts mono 24 kHz PCM16, as used by the macOS sidecar.
export class CaptionPcmEncoder {
  private previous?: number;
  encode(samples: Float32Array): Buffer {
    const output = Buffer.alloc(
      Math.floor((samples.length + (this.previous === undefined ? 0 : 1)) / 2) * 2,
    );
    let offset = 0;
    for (const sample of samples) {
      const finite = Number.isFinite(sample) ? Math.max(-1, Math.min(1, sample)) : 0;
      if (this.previous === undefined) this.previous = finite;
      else {
        const value = (this.previous + finite) / 2;
        output.writeInt16LE(Math.round(value * (value < 0 ? 32768 : 32767)), offset);
        offset += 2;
        this.previous = undefined;
      }
    }
    return output;
  }
}

type CaptionOptions = {
  account: SidecarAccount;
  options: SidecarRecordingOptions;
  sessionId: string;
  emit: (event: SidecarEvent) => void;
  fetchImpl?: typeof fetch;
  createSocket?: (url: string, headers: Record<string, string>) => WebSocket;
  reconnectDelaysMs?: number[];
  drainTimeoutMs?: number;
};

class CaptionFailure extends Error {
  constructor(
    message: string,
    readonly retryable: boolean,
    readonly code = "live_caption.connect_failed",
  ) {
    super(message);
  }
}

/** Captions are best effort; failures must never interrupt the local WAV. */
export class WindowsLiveCaptions implements WindowsCaptionStream {
  private readonly encoder = new CaptionPcmEncoder();
  private readonly origin: string;
  private readonly translation: boolean;
  private socket?: WebSocket;
  private abort?: AbortController;
  private reconnect?: ReturnType<typeof setTimeout>;
  private attempt = 0;
  private generation = 0;
  private closing = false;
  private stopped = false;
  private stopPromise?: Promise<void>;
  private pending: Buffer[] = [];
  private pendingBytes = 0;
  private uncommittedBytes = 0;
  private readonly segments = new Map<string, string>();
  private readonly awaitingFinal = new Set<string>();
  private pendingCommits = 0;
  private drain?: () => void;
  private translationSource = "";
  private translationText = "";
  private translationSegment = 0;

  constructor(private readonly deps: CaptionOptions) {
    this.origin = validateOrigin(deps.account.backendOrigin);
    this.translation = Boolean(deps.options.translationLanguage?.trim());
    this.status("connecting");
    void this.connect();
  }

  append(samples: Float32Array): void {
    if (this.closing || this.stopped) return;
    const pcm = this.encoder.encode(samples);
    if (!pcm.length) return;
    if (this.socket?.readyState === WebSocket.OPEN) this.sendAudio(pcm);
    else {
      this.pending.push(pcm);
      this.pendingBytes += pcm.length;
      // At most five seconds of audio while connecting. Never grow with meeting length.
      while (this.pendingBytes > 24000 * 2 * 5) this.pendingBytes -= this.pending.shift()!.length;
    }
  }

  private async connect(): Promise<void> {
    if (this.closing || this.stopped) return;
    const generation = ++this.generation;
    const abort = new AbortController();
    this.abort = abort;
    const timeout = setTimeout(() => abort.abort(), 10000);
    try {
      if (!this.deps.account.authToken)
        throw new CaptionFailure(
          "Sign in to enable live captions. Local recording continues.",
          false,
          "live_caption.auth_missing",
        );
      const language = normalizeLanguage(this.deps.options.transcriptionLanguage, "en");
      const response = await (this.deps.fetchImpl ?? fetch)(
        `${this.origin}/api/openai/realtime/sessions`,
        {
          method: "POST",
          signal: abort.signal,
          headers: {
            Authorization: `Bearer ${this.deps.account.authToken}`,
            Origin: this.origin,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(
            this.translation
              ? {
                  mode: "translation",
                  language,
                  targetLanguage: normalizeLanguage(this.deps.options.translationLanguage, "en"),
                  delay: "low",
                  expiresAfterSeconds: 60,
                  includeSourceTranscript: true,
                }
              : {
                  mode: "transcription",
                  language,
                  delay: "low",
                  expiresAfterSeconds: 60,
                  turnDetection: { type: "none" },
                },
          ),
        },
      );
      if (!response.ok)
        throw new CaptionFailure(
          `Live captions connection failed (HTTP ${response.status}). Local recording continues.`,
          response.status === 429 || response.status >= 500,
        );
      const claim = (await response.json()) as Record<string, unknown>;
      if (
        typeof claim.websocketUrl !== "string" ||
        typeof claim.token !== "string" ||
        !claim.token ||
        typeof claim.tokenType !== "string" ||
        !/^[A-Za-z]+$/.test(claim.tokenType)
      )
        throw new CaptionFailure("Live captions returned an invalid session.", false);
      const url = new URL(claim.websocketUrl);
      if (
        url.username ||
        url.password ||
        (url.protocol !== "wss:" &&
          !(url.protocol === "ws:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))
      )
        throw new CaptionFailure("Live captions returned an invalid connection URL.", false);
      if (this.closing || this.stopped || generation !== this.generation) return;
      const headers = { Authorization: `${claim.tokenType} ${claim.token}`, Origin: this.origin };
      const socket =
        this.deps.createSocket?.(url.href, headers) ??
        new WebSocket(url.href, { headers, handshakeTimeout: 10000, maxPayload: 1024 * 1024 });
      this.socket = socket;
      socket.on("error", () =>
        this.failed(
          new CaptionFailure("Live captions connection dropped. Local recording continues.", true),
          socket,
        ),
      );
      socket.on("close", () => {
        if (this.closing) this.drain?.();
        else
          this.failed(
            new CaptionFailure("Live captions connection closed. Local recording continues.", true),
            socket,
          );
      });
      socket.on("message", (data) => {
        if (this.socket !== socket || this.stopped) return;
        try {
          this.receive(JSON.parse(data.toString()));
        } catch {
          /* Ignore malformed service events. */
        }
      });
      socket.once("open", () => {
        if (this.socket !== socket || this.closing || this.stopped) {
          socket.terminate();
          return;
        }
        this.status("live");
        const pending = this.pending;
        this.pending = [];
        this.pendingBytes = 0;
        for (const audio of pending) {
          if (this.socket !== socket) break;
          this.sendAudio(audio);
        }
      });
    } catch (error) {
      if (!this.closing && !this.stopped && generation === this.generation)
        this.failed(
          error instanceof CaptionFailure
            ? error
            : new CaptionFailure(
                "Live captions could not connect. Local recording continues.",
                true,
              ),
        );
    } finally {
      clearTimeout(timeout);
      if (this.abort === abort) this.abort = undefined;
    }
  }

  private send(message: unknown): boolean {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) return false;
    if (socket.bufferedAmount > 512 * 1024) {
      this.failed(
        new CaptionFailure(
          "Live captions connection is too slow. Reconnecting; local recording continues.",
          true,
        ),
        socket,
      );
      return false;
    }
    try {
      socket.send(JSON.stringify(message), (error) => {
        if (error)
          this.failed(
            new CaptionFailure(
              "Live captions could not send audio. Local recording continues.",
              true,
            ),
            socket,
          );
      });
      return true;
    } catch {
      this.failed(
        new CaptionFailure("Live captions could not send audio. Local recording continues.", true),
        socket,
      );
      return false;
    }
  }

  private sendAudio(pcm: Buffer): void {
    if (
      !this.send({
        type: this.translation ? "session.input_audio_buffer.append" : "input_audio_buffer.append",
        audio: pcm.toString("base64"),
      })
    )
      return;
    if (!this.translation) {
      this.uncommittedBytes += pcm.length;
      if (this.uncommittedBytes >= 67200) this.commit();
    }
  }

  private commit(): void {
    if (this.pendingCommits + this.awaitingFinal.size >= 128) {
      this.failed(
        new CaptionFailure(
          "Live captions stopped responding. Reconnecting; local recording continues.",
          true,
        ),
        this.socket,
      );
      return;
    }
    if (this.send({ type: "input_audio_buffer.commit" })) {
      this.uncommittedBytes = 0;
      this.pendingCommits++;
    }
  }

  private receive(event: Record<string, any>): void {
    const key = `${this.generation}:${event.item_id ?? "current"}${event.content_index ? `#${event.content_index}` : ""}`;
    if (event.type === "input_audio_buffer.committed") {
      this.pendingCommits = Math.max(0, this.pendingCommits - 1);
      this.awaitingFinal.add(key);
      if (this.awaitingFinal.size > 128) {
        this.failed(
          new CaptionFailure("Live captions stopped responding. Local recording continues.", true),
          this.socket,
        );
      }
    } else if (
      event.type === "conversation.item.input_audio_transcription.delta" &&
      typeof event.delta === "string"
    ) {
      this.attempt = 0;
      const text = ((this.segments.get(key) ?? "") + event.delta).slice(-16000);
      this.segments.set(key, text);
      this.delta("source", text, false, key);
      if (this.segments.size > 128) this.segments.delete(this.segments.keys().next().value!);
    } else if (event.type === "conversation.item.input_audio_transcription.completed") {
      this.attempt = 0;
      const text =
        typeof event.transcript === "string" ? event.transcript : (this.segments.get(key) ?? "");
      this.delta("source", text, true, key);
      this.segments.delete(key);
      this.awaitingFinal.delete(key);
      this.checkDrained();
    } else if (event.type === "session.input_transcript.delta" && typeof event.delta === "string") {
      this.attempt = 0;
      this.translationSource += event.delta;
      this.delta("source", this.translationSource, false, this.translationKey);
      if (this.translationSource.length > 2000) this.finishTranslation();
    } else if (
      event.type === "session.output_transcript.delta" &&
      typeof event.delta === "string"
    ) {
      this.attempt = 0;
      this.translationText += event.delta;
      this.delta("translation", this.translationText, false, this.translationKey);
      if (this.translationText.length > 2000) this.finishTranslation();
    } else if (event.type === "error") {
      const region = event.error?.code === "unsupported_country_region_territory";
      this.failed(
        new CaptionFailure(
          region
            ? "Live captions are unavailable in this region. Local recording continues; transcribe after stopping."
            : "Live captions service reported an error. Local recording continues.",
          !region,
          region ? "live_caption.unsupported_region" : "live_caption.server_error",
        ),
        this.socket,
      );
    }
  }

  private get translationKey(): string {
    return `${this.generation}:translation-${this.translationSegment}`;
  }
  private finishTranslation(): void {
    this.delta("source", this.translationSource, true, this.translationKey);
    this.delta("translation", this.translationText, true, this.translationKey);
    this.translationSource = this.translationText = "";
    this.translationSegment++;
  }

  private failed(error: CaptionFailure, socket?: WebSocket): void {
    if (this.closing || this.stopped || (socket && socket !== this.socket)) return;
    const previous = this.socket;
    this.socket = undefined;
    previous?.terminate();
    this.finishTranslation();
    this.segments.clear();
    this.awaitingFinal.clear();
    this.pendingCommits = this.uncommittedBytes = 0;
    const delays = this.deps.reconnectDelaysMs ?? [1000, 2000, 5000, 10000, 30000];
    const retryable = error.retryable && this.attempt < delays.length;
    if (!retryable) {
      this.stopped = true;
      this.pending = [];
      this.pendingBytes = 0;
      this.status("stopped", error.message);
    } else {
      this.status("reconnecting", error.message);
      clearTimeout(this.reconnect);
      this.reconnect = setTimeout(
        () => {
          this.reconnect = undefined;
          void this.connect();
        },
        delays[this.attempt++]!,
      );
    }
    // Emit the specific reason last so generic stopped status cannot overwrite
    // the TUI's unsupported-region state or hide a terminal error.
    if (!retryable)
      this.deps.emit({
        type: "error",
        sessionId: this.deps.sessionId,
        code: error.code,
        message: error.message,
        retryable,
      });
  }

  stop(): Promise<void> {
    this.stopPromise ??= this.finish();
    return this.stopPromise;
  }

  private async finish(): Promise<void> {
    this.closing = true;
    this.abort?.abort();
    clearTimeout(this.reconnect);
    this.pending = [];
    this.pendingBytes = 0;
    const socket = this.socket;
    if (!this.stopped && socket?.readyState === WebSocket.OPEN) {
      if (this.translation) this.send({ type: "session.close" });
      else if (this.uncommittedBytes > 0) {
        // Realtime requires at least 100ms per commit, including the last partial chunk.
        if (this.uncommittedBytes < 4800)
          this.sendAudio(Buffer.alloc(4800 - this.uncommittedBytes));
        this.commit();
      }
      if (this.translation || this.pendingCommits || this.awaitingFinal.size) {
        await new Promise<void>((resolve) => {
          const timer = setTimeout(done, this.deps.drainTimeoutMs ?? 1500);
          const self = this;
          function done() {
            clearTimeout(timer);
            self.drain = undefined;
            resolve();
          }
          this.drain = done;
          if (!this.translation) this.checkDrained();
        });
      }
    }
    this.finishTranslation();
    this.stopped = true;
    this.socket = undefined;
    socket?.terminate();
    this.status("stopped");
  }

  private checkDrained(): void {
    if (!this.pendingCommits && !this.awaitingFinal.size) this.drain?.();
  }
  private delta(
    stream: "source" | "translation",
    text: string,
    isFinal: boolean,
    segmentId: string,
  ): void {
    if (text)
      this.deps.emit({
        type: "live_caption.delta",
        sessionId: this.deps.sessionId,
        stream,
        text,
        isFinal,
        segmentId,
      });
  }
  private status(
    status: "connecting" | "live" | "reconnecting" | "stopped",
    message?: string,
  ): void {
    this.deps.emit({
      type: "live_caption.status",
      sessionId: this.deps.sessionId,
      status,
      ...(message ? { message } : {}),
    });
  }
}

function normalizeLanguage(language: string | undefined, fallback: string): string {
  const value = language?.trim().toLowerCase().split(/[-_]/)[0];
  return !value || value === "auto" ? fallback : value;
}
