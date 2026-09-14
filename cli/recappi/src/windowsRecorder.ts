import { createHash, randomUUID } from "node:crypto";
import { closeSync, mkdirSync, openSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  SIDECAR_PROTOCOL_VERSION,
  sidecarRequestSchema,
  type SidecarAccount,
  type SidecarEvent,
  type SidecarLocalArtifact,
  type SidecarRecordingOptions,
  type SidecarRecordingState,
} from "../../packages/contracts/src/index";
import { CLI_VERSION } from "./version";

export interface WindowsCapture {
  sampleRate: number;
  channels: number;
  stop(): void | Promise<void>;
}

export interface WindowsCaptureBackend {
  start(
    callback: (error: Error | null, samples: Float32Array) => void,
    options: SidecarRecordingOptions,
  ): WindowsCapture | Promise<WindowsCapture>;
}

class RecorderError extends Error {
  constructor(
    message: string,
    readonly cliCode = "record.capture_failed",
    readonly code = -32000,
  ) {
    super(message);
  }
}

/** Stream PCM to disk; never keep a meeting's entire audio in memory. */
export class PcmWavWriter {
  private fd: number | undefined;
  private bytes = 0;

  constructor(
    readonly path: string,
    readonly sampleRate: number,
    readonly channels: number,
  ) {
    if (
      !Number.isInteger(sampleRate) ||
      sampleRate <= 0 ||
      sampleRate > 384000 ||
      !Number.isInteger(channels) ||
      channels < 1 ||
      channels > 8
    ) {
      throw new Error("Capture returned an invalid audio format.");
    }
    this.fd = openSync(path, "wx", 0o600);
    try {
      this.writeHeader();
    } catch (error) {
      this.close();
      throw error;
    }
  }

  append(samples: Float32Array): void {
    if (this.fd === undefined) throw new Error("Recording file is closed.");
    if (samples.length % this.channels !== 0) throw new Error("Incomplete audio frame.");
    if (this.bytes + samples.length * 2 > 0xffffffff - 36) {
      throw new Error("Recording reached the WAV size limit. Stop and start a new recording.");
    }
    const pcm = Buffer.allocUnsafe(samples.length * 2);
    for (let i = 0; i < samples.length; i++) {
      const value = Number.isFinite(samples[i]) ? Math.max(-1, Math.min(1, samples[i]!)) : 0;
      pcm.writeInt16LE(Math.round(value * (value < 0 ? 32768 : 32767)), i * 2);
    }
    let offset = 0;
    while (offset < pcm.length) {
      const written = writeSync(this.fd, pcm, offset, pcm.length - offset, 44 + this.bytes);
      if (written === 0) throw new Error("Could not write recording audio.");
      offset += written;
      this.bytes += written;
    }
    // Keep a recoverable header even if the parent or native capture crashes.
    this.writeHeader();
  }

  get durationMs(): number {
    return Math.floor((this.bytes * 1000) / (this.sampleRate * this.channels * 2));
  }
  get sizeBytes(): number {
    return 44 + this.bytes;
  }

  close(): void {
    if (this.fd === undefined) return;
    const fd = this.fd;
    try {
      this.writeHeader();
    } finally {
      this.fd = undefined;
      closeSync(fd);
    }
  }

  private writeHeader(): void {
    if (this.fd === undefined) return;
    const header = Buffer.alloc(44);
    header.write("RIFF", 0);
    header.writeUInt32LE(36 + this.bytes, 4);
    header.write("WAVEfmt ", 8);
    header.writeUInt32LE(16, 16);
    header.writeUInt16LE(1, 20);
    header.writeUInt16LE(this.channels, 22);
    header.writeUInt32LE(this.sampleRate, 24);
    header.writeUInt32LE(this.sampleRate * this.channels * 2, 28);
    header.writeUInt16LE(this.channels * 2, 32);
    header.writeUInt16LE(16, 34);
    header.write("data", 36);
    header.writeUInt32LE(this.bytes, 40);
    let offset = 0;
    while (offset < header.length) {
      const written = writeSync(this.fd, header, offset, header.length - offset, offset);
      if (written === 0) throw new Error("Could not write recording header.");
      offset += written;
    }
  }
}

interface Session {
  id: string;
  directory: string;
  account: { backendOrigin: string; userId: string };
  title?: string;
  state: SidecarRecordingState;
  capture?: WindowsCapture;
  writer?: PcmWavWriter;
  artifact?: SidecarLocalArtifact;
  error?: string;
  release?: Promise<void>;
}

export class WindowsRecorder {
  private backend?: WindowsCaptureBackend;
  private account?: { backendOrigin: string; userId: string };
  private handshaken = false;
  private session?: Session;

  constructor(
    private readonly deps: {
      loadBackend: () => Promise<WindowsCaptureBackend>;
      emit: (event: SidecarEvent) => void;
      root?: string;
    },
  ) {}

  async handle(value: unknown): Promise<unknown> {
    const parsed = sidecarRequestSchema.safeParse(value);
    const candidate = value as { id?: unknown } | null;
    const id =
      typeof candidate?.id === "string" || typeof candidate?.id === "number" ? candidate.id : null;
    if (!parsed.success)
      return { jsonrpc: "2.0", id, error: { code: -32600, message: "Invalid recording request." } };
    const request = parsed.data;
    try {
      let result: unknown;
      if (request.method === "recappi.handshake") {
        if (this.handshaken)
          throw new RecorderError("Already connected. Start a new helper to change accounts.");
        try {
          this.backend = await this.deps.loadBackend();
        } catch {
          throw new RecorderError(
            "Windows recording helper could not load. Reinstall recappi with optional dependencies enabled, or build the Windows helper when developing from source.",
            "record.helper_unavailable",
          );
        }
        const account = request.params.account;
        this.account = account
          ? { backendOrigin: account.backendOrigin, userId: account.userId }
          : undefined;
        this.handshaken = true;
        result = {
          protocolVersion: SIDECAR_PROTOCOL_VERSION,
          sidecar: { name: "recappi-windows-recorder", version: CLI_VERSION },
          capabilities: ["recording.capture", "local_artifacts.index"],
        };
      } else {
        if (!this.handshaken) throw new RecorderError("Handshake required before recording.");
        switch (request.method) {
          case "recappi.recording.sources.list":
            result = {
              sources: [{ id: "system", kind: "system", label: "System audio · all apps" }],
            };
            break;
          case "recappi.recording.microphones.list":
            result = {
              microphones: [
                { id: "default", label: "Windows default microphone", isDefault: true },
              ],
            };
            break;
          case "recappi.permissions.status":
            this.validateOptions(request.params.options);
            result = {
              permissions: request.params.options.includeMicrophone
                ? [
                    {
                      name: "microphone",
                      status: "unknown",
                      hint: "Enable microphone access for desktop apps in Windows Settings. Capture startup checks device access.",
                    },
                  ]
                : [],
            };
            break;
          case "recappi.recording.start":
            result = await this.start(request.params.account, request.params.options);
            break;
          case "recappi.recording.status":
            result = this.status(this.requireSession(request.params.sessionId));
            break;
          case "recappi.recording.stop":
            result = await this.stop(this.requireSession(request.params.sessionId));
            break;
          case "recappi.recording.cancel":
            result = await this.cancel(this.requireSession(request.params.sessionId));
            break;
          default:
            // The helper only exposes mixed samples. Never label them as separate input meters.
            throw new RecorderError(
              "Windows input level preview is unavailable.",
              "record.capture_unavailable",
              -32601,
            );
        }
      }
      return { jsonrpc: "2.0", id: request.id, result };
    } catch (error) {
      const failure =
        error instanceof RecorderError
          ? error
          : new RecorderError(error instanceof Error ? error.message : "Windows recording failed.");
      return {
        jsonrpc: "2.0",
        id: request.id,
        error: {
          code: failure.code,
          message: failure.message,
          data: { cliCode: failure.cliCode, retryable: false },
        },
      };
    }
  }

  async shutdown(): Promise<void> {
    const session = this.session;
    if (!session || !session.capture) return;
    session.state = "stopping";
    await this.release(session);
    session.state = "failed";
    session.error = "CLI disconnected. Partial recording saved locally.";
    this.saveMetadata(session);
  }

  private validateOptions(options: SidecarRecordingOptions): void {
    if (
      (!options.includeSystemAudio && !options.includeMicrophone) ||
      options.targetBundleId ||
      (options.microphoneDeviceId && options.microphoneDeviceId !== "default") ||
      options.liveCaptions
    ) {
      throw new RecorderError(
        "Windows supports system audio and/or the default microphone. Select at least one input. App isolation, device selection and live captions are not supported yet.",
        "record.capture_unavailable",
      );
    }
  }

  private async start(account: SidecarAccount, options: SidecarRecordingOptions): Promise<unknown> {
    this.validateOptions(options);
    if (
      !this.account ||
      this.account.backendOrigin !== account.backendOrigin ||
      this.account.userId !== account.userId
    ) {
      throw new RecorderError("Recording account does not match the handshake.");
    }
    if (this.session)
      throw new RecorderError(
        "This helper already has a recording session. Start a new helper for another recording.",
      );
    const partition = createHash("sha256").update(JSON.stringify(this.account)).digest("hex");
    const id = randomUUID();
    const root = this.deps.root ?? join(homedir(), ".config", "recappi", "recordings");
    const directory = join(root, partition, id);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const session: Session = {
      id,
      directory,
      account: this.account,
      title: options.title,
      state: "starting",
    };
    this.session = session;
    try {
      session.capture = await this.backend!.start((error, samples) => {
        if (session.state !== "recording" && session.state !== "stopping") return;
        try {
          if (error) throw error;
          session.writer!.append(samples);
        } catch (failure) {
          session.state = "failed";
          session.error = failure instanceof Error ? failure.message : "Audio capture failed.";
          void this.release(session)
            .then(() => this.saveMetadata(session))
            .catch(() => {});
          this.deps.emit({
            type: "recording.state",
            sessionId: id,
            state: "failed",
            message: session.error,
          });
          this.deps.emit({
            type: "error",
            sessionId: id,
            code: "record.capture_failed",
            message: session.error,
            retryable: false,
          });
        }
      }, options);
      session.writer = new PcmWavWriter(
        join(directory, "audio.wav"),
        session.capture.sampleRate,
        session.capture.channels,
      );
      session.state = "recording";
      this.saveMetadata(session);
      this.deps.emit({ type: "recording.state", ...this.status(session) });
      return this.status(session);
    } catch (error) {
      session.state = "failed";
      session.error = error instanceof Error ? error.message : "Device unavailable.";
      await this.release(session);
      this.saveMetadata(session);
      throw new RecorderError(
        `Windows capture could not start: ${error instanceof Error ? error.message : "device unavailable"}. Check the default input/output devices and microphone access for desktop apps.`,
      );
    }
  }

  private requireSession(id: string): Session {
    if (!this.session || this.session.id !== id)
      throw new RecorderError("Unknown recording session.");
    return this.session;
  }

  private status(session: Session) {
    return { sessionId: session.id, state: session.state, localSessionRef: session.directory };
  }

  private async release(session: Session): Promise<void> {
    session.release ??= (async () => {
      const capture = session.capture;
      session.capture = undefined;
      try {
        await capture?.stop();
      } finally {
        session.writer?.close();
      }
    })();
    return session.release;
  }

  private async stop(session: Session): Promise<unknown> {
    if (session.state === "cancelled") return { ...this.status(session), artifacts: [] };
    if (session.state === "failed")
      throw new RecorderError(
        `${session.error ?? "Recording failed"} Partial audio, if available, is in ${session.directory}.`,
      );
    if (session.state === "completed")
      return { ...this.status(session), artifacts: [session.artifact!] };
    session.state = "stopping";
    try {
      await this.release(session);
    } catch (error) {
      session.state = "failed";
      session.error = error instanceof Error ? error.message : "Could not finalize recording.";
      this.saveMetadata(session);
      throw error;
    }
    if (session.error)
      throw new RecorderError(
        `Recording failed: ${session.error}. Partial audio is in ${session.directory}.`,
      );
    const writer = session.writer!;
    if (writer.sizeBytes === 44) {
      session.state = "failed";
      session.error = "No audio samples received. Check Windows default audio devices.";
      this.saveMetadata(session);
      throw new RecorderError(session.error);
    }
    session.state = "completed";
    session.artifact = {
      kind: "recording_session",
      localPath: session.directory,
      metadata: {
        audioPath: writer.path,
        durationMs: writer.durationMs,
        sizeBytes: writer.sizeBytes,
      },
    };
    this.saveMetadata(session);
    this.deps.emit({
      type: "local_artifact.upserted",
      sessionId: session.id,
      artifact: session.artifact,
    });
    this.deps.emit({ type: "recording.state", ...this.status(session) });
    return { ...this.status(session), artifacts: [session.artifact] };
  }

  private async cancel(session: Session): Promise<unknown> {
    if (session.state === "cancelled") return { ...this.status(session), artifacts: [] };
    if (session.state === "completed" || session.state === "failed") {
      // A failed cloud handoff or capture must not erase recoverable audio.
      return { ...this.status(session), artifacts: session.artifact ? [session.artifact] : [] };
    }
    session.state = "cancelled";
    await this.release(session);
    if (session.writer) unlinkSync(session.writer.path);
    this.saveMetadata(session);
    return { ...this.status(session), artifacts: [] };
  }

  private saveMetadata(session: Session): void {
    writeFileSync(
      join(session.directory, "session.json"),
      JSON.stringify(
        {
          sessionId: session.id,
          account: session.account,
          title: session.title,
          state: session.state,
          error: session.error,
          artifact: session.artifact,
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );
  }
}
