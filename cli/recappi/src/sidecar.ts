import { spawn, spawnSync } from "node:child_process";
import { createReadStream, createWriteStream, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import {
  SIDECAR_PROTOCOL_VERSION,
  cliErrorCodeSchema,
  sidecarEventSchema,
  sidecarHandshakeParamsSchema,
  sidecarHandshakeResultSchema,
  sidecarJsonRpcIdSchema,
  sidecarLevelPreviewStartParamsSchema,
  sidecarLevelPreviewStartResultSchema,
  sidecarLevelPreviewStopParamsSchema,
  sidecarLevelPreviewStopResultSchema,
  sidecarMicrophonesListResultSchema,
  sidecarNotificationSchema,
  sidecarPermissionStatusParamsSchema,
  sidecarPermissionStatusResultSchema,
  sidecarRecordingSourcesListResultSchema,
  sidecarRecordingStartParamsSchema,
  sidecarRecordingStartResultSchema,
  sidecarRecordingStatusResultSchema,
  sidecarRecordingStopResultSchema,
  sidecarResponseSchema,
  sidecarSessionParamsSchema,
  type ContractSchema,
  type SidecarEvent,
  type SidecarError,
  type SidecarHandshakeParams,
  type SidecarHandshakeResult,
  type SidecarLevelPreviewStartParams,
  type SidecarLevelPreviewStartResult,
  type SidecarLevelPreviewStopParams,
  type SidecarLevelPreviewStopResult,
  type SidecarMicrophonesListResult,
  type SidecarPermissionStatusParams,
  type SidecarPermissionStatusResult,
  type SidecarRecordingSourcesListResult,
  type SidecarRecordingStartParams,
  type SidecarRecordingStartResult,
  type SidecarRecordingStatusResult,
  type SidecarRecordingStopResult,
  type SidecarRequestMethod,
  type SidecarSessionParams,
} from "../../packages/contracts/src/index";
import { cliError, toCliError, type RecappiCliError } from "./errors";

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: RecappiCliError) => void;
  timer: ReturnType<typeof setTimeout>;
}

export interface MiniSidecarClientOptions {
  input: Writable;
  output: Readable;
  requestTimeoutMs?: number;
}

export interface SpawnMiniSidecarOptions {
  command: string;
  args?: string[];
  env?: NodeJS.ProcessEnv;
  requestTimeoutMs?: number;
  spawnProcess?: typeof spawn;
}

export interface SpawnedMiniSidecar {
  client: MiniSidecarClient;
  kill: () => void;
}

interface LaunchServicesPipePaths {
  stdin: string;
  stdout: string;
  stderr: string;
}

export class MiniSidecarClient {
  private readonly input: Writable;
  private readonly requestTimeoutMs: number;
  private readonly pending = new Map<string | number, PendingRequest>();
  private readonly eventListeners = new Set<(event: SidecarEvent) => void>();
  private readonly lineReader: ReturnType<typeof createInterface>;
  private nextId = 1;
  private closed = false;

  constructor(opts: MiniSidecarClientOptions) {
    this.input = opts.input;
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 10_000;
    this.lineReader = createInterface({ input: opts.output });
    this.lineReader.on("line", (line) => this.handleLine(line));
    this.lineReader.on("close", () => this.rejectAll("Sidecar output closed."));
  }

  onEvent(listener: (event: SidecarEvent) => void): () => void {
    this.eventListeners.add(listener);
    return () => {
      this.eventListeners.delete(listener);
    };
  }

  handshake(params: SidecarHandshakeParams): Promise<SidecarHandshakeResult> {
    return this.request(
      "recappi.handshake",
      sidecarHandshakeParamsSchema.parse(params),
      sidecarHandshakeResultSchema,
    );
  }

  listRecordingSources(): Promise<SidecarRecordingSourcesListResult> {
    return this.request(
      "recappi.recording.sources.list",
      {},
      sidecarRecordingSourcesListResultSchema,
    );
  }

  listMicrophones(): Promise<SidecarMicrophonesListResult> {
    return this.request(
      "recappi.recording.microphones.list",
      {},
      sidecarMicrophonesListResultSchema,
    );
  }

  startRecording(params: SidecarRecordingStartParams): Promise<SidecarRecordingStartResult> {
    return this.request(
      "recappi.recording.start",
      sidecarRecordingStartParamsSchema.parse(params),
      sidecarRecordingStartResultSchema,
    );
  }

  startLevelPreview(
    params: SidecarLevelPreviewStartParams,
  ): Promise<SidecarLevelPreviewStartResult> {
    return this.request(
      "recappi.recording.level_preview.start",
      sidecarLevelPreviewStartParamsSchema.parse(params),
      sidecarLevelPreviewStartResultSchema,
    );
  }

  stopLevelPreview(
    params: SidecarLevelPreviewStopParams,
  ): Promise<SidecarLevelPreviewStopResult> {
    return this.request(
      "recappi.recording.level_preview.stop",
      sidecarLevelPreviewStopParamsSchema.parse(params),
      sidecarLevelPreviewStopResultSchema,
    );
  }

  getPermissionStatus(
    params: SidecarPermissionStatusParams,
  ): Promise<SidecarPermissionStatusResult> {
    return this.request(
      "recappi.permissions.status",
      sidecarPermissionStatusParamsSchema.parse(params),
      sidecarPermissionStatusResultSchema,
    );
  }

  stopRecording(params: SidecarSessionParams): Promise<SidecarRecordingStopResult> {
    return this.request(
      "recappi.recording.stop",
      sidecarSessionParamsSchema.parse(params),
      sidecarRecordingStopResultSchema,
    );
  }

  cancelRecording(params: SidecarSessionParams): Promise<SidecarRecordingStopResult> {
    return this.request(
      "recappi.recording.cancel",
      sidecarSessionParamsSchema.parse(params),
      sidecarRecordingStopResultSchema,
    );
  }

  getRecordingStatus(params: SidecarSessionParams): Promise<SidecarRecordingStatusResult> {
    return this.request(
      "recappi.recording.status",
      sidecarSessionParamsSchema.parse(params),
      sidecarRecordingStatusResultSchema,
    );
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.lineReader.close();
    this.rejectAll("Sidecar client closed.");
  }

  private request<T>(
    method: SidecarRequestMethod,
    params: unknown,
    resultSchema: ContractSchema,
  ): Promise<T> {
    if (this.closed) {
      return Promise.reject(
        cliError("internal.unexpected", "Sidecar client is already closed.", {
          hint: "Start a new sidecar session and retry.",
        }),
      );
    }

    const id = this.nextId;
    this.nextId += 1;
    const payload = {
      jsonrpc: "2.0" as const,
      id,
      method,
      params,
    };

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          cliError("internal.unexpected", `Sidecar request timed out: ${method}.`, {
            retryable: true,
          }),
        );
      }, this.requestTimeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          try {
            const parsed = resultSchema.parse(value) as T;
            resolve(parsed);
          } catch (error) {
            reject(toCliError(error));
          }
        },
        reject,
        timer,
      });
      this.input.write(`${JSON.stringify(payload)}\n`, (error) => {
        if (!error) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(cliError("internal.unexpected", `Could not write to sidecar: ${error.message}`));
      });
    });
  }

  private handleLine(line: string): void {
    const trimmed = line.trim();
    if (!trimmed) return;

    let raw: unknown;
    try {
      raw = JSON.parse(trimmed);
    } catch {
      this.rejectAll("Sidecar wrote invalid JSON.");
      return;
    }

    const maybeNotification = sidecarNotificationSchema.safeParse(raw);
    if (maybeNotification.success) {
      const event = sidecarEventSchema.parse(maybeNotification.data.params);
      for (const listener of this.eventListeners) listener(event);
      return;
    }

    const response = sidecarResponseSchema.safeParse(raw);
    if (!response.success) {
      this.rejectAll("Sidecar wrote an invalid JSON-RPC message.");
      return;
    }

    const id = sidecarJsonRpcIdSchema.parse(response.data.id);
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    clearTimeout(pending.timer);
    if ("error" in response.data) {
      pending.reject(sidecarErrorToCliError(response.data.error));
      return;
    }
    pending.resolve(response.data.result);
  }

  private rejectAll(message: string): void {
    for (const [id, pending] of this.pending) {
      this.pending.delete(id);
      clearTimeout(pending.timer);
      pending.reject(cliError("internal.unexpected", message));
    }
  }
}

function sidecarErrorToCliError(error: SidecarError): RecappiCliError {
  const data = isRecord(error.data) ? error.data : undefined;
  const maybeCode =
    typeof data?.cliCode === "string" ? cliErrorCodeSchema.safeParse(data.cliCode) : undefined;
  const hint = typeof data?.recovery === "string" ? data.recovery : undefined;
  const retryable =
    typeof data?.retryable === "boolean"
      ? data.retryable
      : error.code >= -32099 && error.code <= -32000;
  if (maybeCode?.success) {
    return cliError(maybeCode.data, error.message, {
      data: error,
      hint,
      retryable,
    });
  }
  return cliError("internal.unexpected", error.message, {
    data: error,
    hint,
    retryable,
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function spawnMiniSidecar(opts: SpawnMiniSidecarOptions): SpawnedMiniSidecar {
  if (isLaunchServicesAppCommand(opts.command)) {
    return spawnLaunchServicesSidecar(opts);
  }

  const spawnProcess = opts.spawnProcess ?? spawn;
  const child = spawnProcess(opts.command, opts.args ?? [], {
    env: opts.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const client = new MiniSidecarClient({
    input: child.stdin,
    output: child.stdout,
    requestTimeoutMs: opts.requestTimeoutMs,
  });
  return {
    client,
    kill: () => {
      client.close();
      child.kill();
    },
  };
}

export function defaultSidecarHandshakeParams(
  params: Omit<SidecarHandshakeParams, "protocolVersion">,
): SidecarHandshakeParams {
  return {
    protocolVersion: SIDECAR_PROTOCOL_VERSION,
    ...params,
  };
}

export function isLaunchServicesAppCommand(
  command: string,
  platform: NodeJS.Platform = process.platform,
): boolean {
  return platform === "darwin" && command.endsWith(".app");
}

export function launchServicesOpenArgs(
  appPath: string,
  pipes: LaunchServicesPipePaths,
  sidecarArgs: string[] = [],
): string[] {
  return [
    "-W",
    "-n",
    "-g",
    "--stdin",
    pipes.stdin,
    "--stdout",
    pipes.stdout,
    "--stderr",
    pipes.stderr,
    appPath,
    "--args",
    ...sidecarArgs,
  ];
}

function spawnLaunchServicesSidecar(opts: SpawnMiniSidecarOptions): SpawnedMiniSidecar {
  const spawnProcess = opts.spawnProcess ?? spawn;
  const tempDir = mkdtempSync(join(tmpdir(), "recappi-sidecar-"));
  const pipes: LaunchServicesPipePaths = {
    stdin: join(tempDir, "stdin.fifo"),
    stdout: join(tempDir, "stdout.fifo"),
    stderr: join(tempDir, "stderr.log"),
  };
  createFifo(pipes.stdin);
  createFifo(pipes.stdout);

  const output = createReadStream(pipes.stdout);
  const input = createWriteStream(pipes.stdin);
  const child = spawnProcess("open", launchServicesOpenArgs(opts.command, pipes, opts.args ?? []), {
    env: opts.env,
    stdio: ["ignore", "ignore", "pipe"],
  });
  const client = new MiniSidecarClient({
    input,
    output,
    requestTimeoutMs: opts.requestTimeoutMs,
  });

  let cleaned = false;
  const cleanup = () => {
    if (cleaned) return;
    cleaned = true;
    rmSync(tempDir, { recursive: true, force: true });
  };
  child.once("exit", cleanup);
  child.once("error", cleanup);

  return {
    client,
    kill: () => {
      requestLaunchServicesSidecarShutdown(input);
      client.close();
      input.end();
      output.destroy();
      const killTimer = setTimeout(() => child.kill(), 2_000);
      killTimer.unref?.();
      child.once("exit", () => clearTimeout(killTimer));
      cleanup();
    },
  };
}

function requestLaunchServicesSidecarShutdown(input: Writable): void {
  try {
    input.write(
      `${JSON.stringify({
        jsonrpc: "2.0",
        id: "shutdown",
        method: "recappi.shutdown",
        params: {},
      })}\n`,
    );
  } catch {
    /* best-effort shutdown before closing the FIFO */
  }
}

function createFifo(path: string): void {
  const result = spawnSync("mkfifo", [path], { encoding: "utf8" });
  if (result.status !== 0) {
    throw cliError("record.helper_unavailable", "Recappi recording helper could not start.", {
      hint: result.stderr || "Could not create the local recorder pipes. Try again.",
    });
  }
}
