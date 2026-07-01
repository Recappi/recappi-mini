import { createWriteStream, promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { ReadableStream as NodeReadableStream } from "node:stream/web";
import type {
  AccountStatusData,
  AuthStatusData,
  BillingStatusData,
  DashboardStatsData,
  DoctorData,
  DoctorCheck,
  JobData,
  JobListData,
  JobStatusFilter,
  OperationEvent,
  RecordingData,
  RecordingListData,
  RecordingTranscribeData,
  SummaryStatus,
  TranscriptData,
  TranscriptSegment,
  UploadBatchData,
  UploadSuccess,
} from "../../packages/contracts/src/index";
import {
  accountStatusDataSchema,
  billingStatusDataSchema,
  dashboardStatsDataSchema,
  doctorDataSchema,
  jobListDataSchema,
  recordingDataSchema,
  recordingListDataSchema,
  recordingTranscribeDataSchema,
  transcriptDataSchema,
} from "../../packages/contracts/src/index";
import { cliError, describeHttpError, RecappiCliError, toCliError } from "./errors";
import { type AudioFilePlan, planAudioFile } from "./files";
import { inspectMacOSAppKeychain, requireToken, type AuthContext } from "./auth";
import { defaultStorePath, openCliStore, requireAccountPartition } from "./store";

export interface RecappiApiClientOptions {
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
}

export interface UploadOptions {
  inputPaths: string[];
  title?: string;
  transcribe?: boolean;
  wait?: boolean;
  language?: string;
  provider?: string;
  prompt?: string;
  force?: boolean;
  onEvent?: (event: OperationEvent) => void;
}

export interface ListJobsOptions {
  status: JobStatusFilter;
  limit: number;
}

export interface ListRecordingsOptions {
  limit: number;
  cursor?: string;
  search?: string;
}

export interface TranscribeRecordingOptions {
  recordingId: string;
  language?: string;
  provider?: string;
  model?: string;
  prompt?: string;
  scene?: string;
  wait?: boolean;
  onEvent?: (event: OperationEvent) => void;
}

export interface RecordingAudioDownload {
  recordingId: string;
  localPath: string;
  contentType: string;
  contentLength?: number;
  origin: string;
}

export interface DownloadRecordingAudioOptions {
  directory?: string;
  title?: string | null;
}

interface InitUploadResponse {
  id: string;
  partSize: number;
}

interface UploadPartResponse {
  partNumber: number;
  etag: string;
}

interface TranscribeResponse {
  jobId: string;
  status: string;
  transcriptId?: string | null;
}

export class RecappiApiClient {
  private readonly fetchImpl: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly env: NodeJS.ProcessEnv;
  private readonly homeDir?: string;

  constructor(
    private readonly auth: AuthContext,
    opts: RecappiApiClientOptions = {},
  ) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.sleep = opts.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.env = opts.env ?? process.env;
    this.homeDir = opts.homeDir;
  }

  async authStatus(): Promise<AuthStatusData> {
    if (!this.auth.token) {
      return { loggedIn: false, origin: this.auth.origin };
    }
    const response = await this.request("GET", "/api/auth/get-session", undefined, {
      allowAuthFailure: true,
    });
    if (response.status === 401 || response.status === 403) {
      return { loggedIn: false, origin: this.auth.origin };
    }
    const body = await parseJson(response);
    const user = isRecord(body) && isRecord(body.user) ? body.user : undefined;
    return {
      loggedIn: Boolean(user),
      origin: this.auth.origin,
      ...(typeof user?.email === "string" ? { email: user.email } : {}),
      ...(typeof user?.id === "string" ? { userId: user.id } : {}),
    };
  }

  async doctor(): Promise<DoctorData> {
    const checks: DoctorCheck[] = [];
    const nodeMajor = Number.parseInt(process.versions.node.split(".")[0] ?? "0", 10);
    checks.push({
      name: "runtime.node",
      status: nodeMajor >= 20 ? "ok" : "error",
      message:
        nodeMajor >= 20
          ? `Node ${process.versions.node} satisfies Recappi CLI runtime requirements.`
          : `Node ${process.versions.node} is too old; Recappi CLI requires Node 20 or newer.`,
      ...(nodeMajor >= 20 ? {} : { hint: "Install Node 20+ and retry." }),
    });
    checks.push({
      name: "cloud.origin",
      status: "ok",
      message: `Using ${this.auth.origin}.`,
    });
    checks.push({
      name: "auth.token",
      status: this.auth.token ? "ok" : "error",
      message: this.auth.token
        ? `Found auth token from ${this.auth.source}.`
        : "No Recappi auth token found.",
      ...(this.auth.token
        ? {}
        : {
            hint: "Run recappi auth login, or set RECAPPI_AUTH_TOKEN for automation.",
          }),
    });

    if (this.auth.token) {
      try {
        const status = await this.authStatus();
        checks.push({
          name: "auth.session",
          status: status.loggedIn ? "ok" : "error",
          message: status.loggedIn
            ? `Cloud session is valid${status.email ? ` for ${status.email}` : ""}.`
            : "Cloud did not accept the configured auth token.",
          ...(status.loggedIn
            ? {}
            : {
                hint: `Run recappi auth login again. If you use --origin, make sure the token belongs to ${this.auth.origin}.`,
              }),
        });
      } catch (error) {
        const cli = toCliError(error);
        checks.push({
          name: "auth.session",
          status: "error",
          message: cli.descriptor.message,
          ...(cli.descriptor.hint ? { hint: cli.descriptor.hint } : {}),
        });
      }
    }

    const keychain = await inspectMacOSAppKeychain({ env: this.env });
    checks.push({
      name: "auth.macos_keychain",
      status: keychain.status === "error" ? "warn" : "ok",
      message: keychain.message,
      ...(keychain.status === "ok"
        ? { hint: "Run recappi auth import-macos to copy this app session into CLI config." }
        : keychain.hint
          ? { hint: keychain.hint }
          : {}),
    });

    checks.push({
      name: "audio.wav",
      status: "ok",
      message: "Built-in WAV duration parser is available.",
    });
    try {
      await import("music-metadata");
      checks.push({
        name: "audio.metadata",
        status: "ok",
        message: "music-metadata is available for non-WAV duration detection.",
      });
    } catch {
      checks.push({
        name: "audio.metadata",
        status: "warn",
        message: "music-metadata is not available; non-WAV duration detection may fail.",
        hint: "Reinstall recappi or upload WAV files.",
      });
    }

    const status = checks.some((check) => check.status === "error")
      ? "error"
      : checks.some((check) => check.status === "warn")
        ? "warn"
        : "ok";
    return doctorDataSchema.parse({
      status,
      origin: this.auth.origin,
      authSource: this.auth.source,
      checks,
    });
  }

  async getTranscript(transcriptId: string): Promise<TranscriptData> {
    const parsed = await this.getJson<Record<string, unknown>>(
      `/api/transcripts/${encodeURIComponent(transcriptId)}`,
    );
    return mapTranscript(parsed);
  }

  async listJobs(opts: ListJobsOptions): Promise<JobListData> {
    const params = new URLSearchParams({
      status: opts.status,
      limit: String(opts.limit),
    });
    const parsed = await this.getJson<Record<string, unknown>>(`/api/jobs?${params}`);
    const items = Array.isArray(parsed.items)
      ? parsed.items.filter(isRecord).map(mapJobListItem)
      : [];
    return jobListDataSchema.parse({
      items,
      status: typeof parsed.status === "string" ? parsed.status : opts.status,
      limit: typeof parsed.limit === "number" ? parsed.limit : opts.limit,
      origin: this.auth.origin,
    });
  }

  async listRecordings(opts: ListRecordingsOptions): Promise<RecordingListData> {
    const params = new URLSearchParams({ limit: String(opts.limit) });
    if (opts.cursor) params.set("cursor", opts.cursor);
    if (opts.search) params.set("search", opts.search);
    const parsed = await this.getJson<Record<string, unknown>>(`/api/recordings?${params}`);
    const items = Array.isArray(parsed.items)
      ? parsed.items.filter(isRecord).map((row) => mapRecording(row, this.auth.origin))
      : [];
    return recordingListDataSchema.parse({
      items,
      limit: opts.limit,
      ...(typeof parsed.nextCursor === "string" || parsed.nextCursor === null
        ? { nextCursor: parsed.nextCursor }
        : {}),
      ...(typeof parsed.totalCount === "number" ? { totalCount: parsed.totalCount } : {}),
      origin: this.auth.origin,
    });
  }

  async getRecording(recordingId: string): Promise<RecordingData> {
    const parsed = await this.getJson<Record<string, unknown>>(
      `/api/recordings/${encodeURIComponent(recordingId)}`,
    );
    return mapRecording(parsed, this.auth.origin);
  }

  async transcribeRecording(opts: TranscribeRecordingOptions): Promise<RecordingTranscribeData> {
    if (opts.scene && opts.scene !== "default") {
      throw cliError("usage.invalid_argument", `Unknown transcription scene '${opts.scene}'.`, {
        hint: "Only the default scene is available today; use --prompt for custom context.",
      });
    }

    opts.onEvent?.({
      type: "started",
      command: "recordings retranscribe",
      recordingId: opts.recordingId,
      message: "Starting transcription",
    });
    const hasPrompt = Boolean(opts.prompt?.trim());
    const parsed = await this.postJson<TranscribeResponse>(
      `/api/recordings/${encodeURIComponent(opts.recordingId)}/transcribe`,
      {
        ...(opts.language ? { language: opts.language } : {}),
        ...(opts.provider ? { provider: opts.provider } : {}),
        ...(opts.model ? { model: opts.model } : {}),
        ...(hasPrompt ? { prompt: opts.prompt } : { force: true }),
      },
    );
    let result = recordingTranscribeDataSchema.parse({
      origin: this.auth.origin,
      recordingId: opts.recordingId,
      jobId: parsed.jobId,
      status: parsed.status,
      ...(typeof parsed.transcriptId === "string" || parsed.transcriptId === null
        ? { transcriptId: parsed.transcriptId }
        : {}),
    });
    opts.onEvent?.({
      type: "progress",
      command: "recordings retranscribe",
      recordingId: opts.recordingId,
      jobId: result.jobId,
      status: result.status,
      ...(result.transcriptId ? { transcriptId: result.transcriptId } : {}),
      message:
        result.status === "succeeded" ? "Transcription already ready" : "Transcription queued",
    });
    if (opts.wait && result.status !== "succeeded") {
      const waited = await this.waitForJob(result.jobId, {
        onEvent: (event) =>
          opts.onEvent?.({
            ...event,
            command: "recordings retranscribe",
            recordingId: opts.recordingId,
          }),
      });
      result = recordingTranscribeDataSchema.parse({
        origin: this.auth.origin,
        recordingId: opts.recordingId,
        jobId: waited.jobId,
        status: waited.status,
        ...(waited.transcriptId !== undefined ? { transcriptId: waited.transcriptId } : {}),
      });
    }
    return result;
  }

  async downloadRecordingAudio(
    recordingId: string,
    opts: DownloadRecordingAudioOptions = {},
  ): Promise<RecordingAudioDownload> {
    const response = await this.request(
      "GET",
      `/api/recordings/${encodeURIComponent(recordingId)}/audio`,
    );
    if (!response.body) {
      throw cliError("cloud.invalid_response", "Recording audio response was empty.");
    }
    const contentType = normalizeContentType(response.headers.get("content-type"));
    const contentLength = numberHeader(response.headers.get("content-length"));
    const dir = opts.directory ?? (await fs.mkdtemp(path.join(os.tmpdir(), "recappi-cli-audio-")));
    if (opts.directory) await fs.mkdir(dir, { recursive: true });
    const filePath = path.join(dir, recordingAudioFileName(recordingId, opts.title, contentType));
    try {
      await pipeline(
        Readable.fromWeb(response.body as unknown as NodeReadableStream),
        createWriteStream(filePath),
      );
    } catch (error) {
      await fs.rm(filePath, { force: true }).catch(() => undefined);
      throw error;
    }
    return {
      recordingId,
      localPath: filePath,
      contentType,
      ...(contentLength !== undefined ? { contentLength } : {}),
      origin: this.auth.origin,
    };
  }

  async dashboardStats(): Promise<DashboardStatsData> {
    const parsed = await this.getJson<Record<string, unknown>>("/api/dashboard/stats");
    return mapDashboardStats(parsed, this.auth.origin);
  }

  async billingStatus(): Promise<BillingStatusData> {
    const parsed = await this.getJson<Record<string, unknown>>("/api/billing/status");
    return mapBillingStatus(parsed, this.auth.origin);
  }

  async accountStatus(): Promise<AccountStatusData> {
    const status = await this.authStatus();
    const storePath = defaultStorePath(this.homeDir, this.env);
    let accountScopedArtifacts = 0;
    let unattributedArtifacts = 0;
    if (status.loggedIn && status.userId) {
      const store = openCliStore({
        dbPath: storePath,
        env: this.env,
        homeDir: this.homeDir,
      });
      try {
        const account = requireAccountPartition({
          backendOrigin: this.auth.origin,
          userId: status.userId,
        });
        store.recordAccountSeen(account, status.email);
        accountScopedArtifacts = store.listLocalArtifactsForAccount(account).length;
        unattributedArtifacts = store.listUnattributedLocalArtifacts().length;
      } finally {
        store.close();
      }
    }
    const billing = status.loggedIn ? await this.billingStatus() : undefined;
    return accountStatusDataSchema.parse({
      origin: this.auth.origin,
      loggedIn: status.loggedIn,
      ...(status.email ? { email: status.email } : {}),
      ...(status.userId ? { userId: status.userId } : {}),
      localStore: {
        path: storePath,
        accountScopedArtifacts,
        unattributedArtifacts,
      },
      ...(billing ? { billing } : {}),
    });
  }

  async uploadPathBatch(opts: UploadOptions): Promise<UploadBatchData> {
    const files = opts.inputPaths;
    if (files.length === 0) {
      throw cliError(
        "usage.invalid_argument",
        "Missing upload file path.",
        {
          hint: "Pass one or more audio files, e.g. recappi upload talk.m4a notes.wav.",
        },
      );
    }

    const successes: UploadSuccess[] = [];
    const failures: UploadBatchData["failures"] = [];
    let attemptedCount = 0;
    for (const filePath of files) {
      attemptedCount += 1;
      try {
        const plan = await planAudioFile(filePath, files.length === 1 ? opts.title : undefined);
        const result = await this.uploadFile(plan, opts);
        successes.push(result);
      } catch (error) {
        const cli = toCliError(error);
        failures.push({ filePath, error: cli.descriptor });
        if (cli.descriptor.exitCode !== 4) {
          break;
        }
      }
    }
    return { successes, failures, totalCount: files.length, attemptedCount };
  }

  async waitForJob(
    jobId: string,
    opts: { onEvent?: (event: OperationEvent) => void } = {},
  ): Promise<JobData> {
    for (;;) {
      const job = await this.getJob(jobId);
      opts.onEvent?.({
        type: "progress",
        command: "jobs wait",
        origin: this.auth.origin,
        jobId,
        ...(job.recordingId ? { recordingId: job.recordingId } : {}),
        status: job.status,
        ...(job.transcriptId ? { transcriptId: job.transcriptId } : {}),
        ...(typeof job.progressPercent === "number" ? { percent: job.progressPercent } : {}),
      });
      if (job.status === "succeeded") return job;
      if (job.status === "failed") {
        throw new RecappiCliError({
          code: "cloud.job_failed",
          exitCode: 5,
          retryable: false,
          message: "Transcription job failed.",
          hint: "Open Recappi Cloud for details, or retry transcription with --force.",
        });
      }
      await this.sleep(2000);
    }
  }

  private async uploadFile(plan: AudioFilePlan, opts: UploadOptions): Promise<UploadSuccess> {
    const relative = plan.filePath;
    opts.onEvent?.({
      type: "started",
      command: "upload",
      filePath: relative,
      message: `Preparing ${relative}`,
    });
    const init = await this.postJson<InitUploadResponse>("/api/recordings", {
      title: plan.title,
      contentType: plan.contentType,
      ...(plan.durationMs ? { durationMs: plan.durationMs } : {}),
    });

    const parts = await this.uploadParts(init.id, plan, init.partSize, opts.onEvent);
    opts.onEvent?.({
      type: "progress",
      command: "upload",
      filePath: relative,
      recordingId: init.id,
      status: "finishing_upload",
      message: "Finishing upload",
    });
    await this.postJson(`/api/recordings/${init.id}/complete`, { parts });
    opts.onEvent?.({
      type: "progress",
      command: "upload",
      origin: this.auth.origin,
      filePath: relative,
      recordingId: init.id,
      status: "uploaded",
      message: `Uploaded · ${recordingCloudUrl(this.auth.origin, init.id)}`,
    });

    let jobId: string | undefined;
    let transcriptId: string | undefined;
    let status = "ready";
    if (opts.transcribe) {
      opts.onEvent?.({
        type: "progress",
        command: "upload",
        origin: this.auth.origin,
        filePath: relative,
        recordingId: init.id,
        status: "starting_transcription",
        message: "Starting transcription",
      });
      const transcribe = await this.postJson<TranscribeResponse>(
        `/api/recordings/${init.id}/transcribe`,
        {
          ...(opts.language ? { language: opts.language } : {}),
          ...(opts.provider ? { provider: opts.provider } : {}),
          ...(opts.prompt ? { prompt: opts.prompt } : {}),
          ...(opts.force ? { force: true } : {}),
        },
      );
      jobId = transcribe.jobId;
      status = transcribe.status;
      if (transcribe.transcriptId) transcriptId = transcribe.transcriptId;
      opts.onEvent?.({
        type: "progress",
        command: "upload",
        origin: this.auth.origin,
        filePath: relative,
        recordingId: init.id,
        jobId,
        status,
        ...(transcriptId ? { transcriptId } : {}),
        message:
          status === "succeeded" ? "Transcription already ready" : "Transcription queued",
      });
      if (opts.wait) {
        const waited = await this.waitForJob(jobId, {
          onEvent: (event) =>
            opts.onEvent?.({
              ...event,
              command: "upload",
              filePath: relative,
              recordingId: init.id,
            }),
        });
        status = waited.status;
        if (waited.transcriptId) transcriptId = waited.transcriptId;
      }
    }

    return {
      filePath: plan.filePath,
      recordingId: init.id,
      ...(jobId ? { jobId } : {}),
      ...(transcriptId ? { transcriptId } : {}),
      status,
      origin: this.auth.origin,
    };
  }

  private async uploadParts(
    recordingId: string,
    plan: AudioFilePlan,
    partSize: number,
    onEvent?: (event: OperationEvent) => void,
  ): Promise<UploadPartResponse[]> {
    const handle = await fs.open(plan.filePath, "r");
    const parts: UploadPartResponse[] = [];
    try {
      let offset = 0;
      let partNumber = 1;
      while (offset < plan.sizeBytes) {
        const size = Math.min(partSize, plan.sizeBytes - offset);
        const buffer = Buffer.alloc(size);
        const { bytesRead } = await handle.read(buffer, 0, size, offset);
        const body = buffer.subarray(0, bytesRead);
        const response = await this.request(
          "PUT",
          `/api/recordings/${recordingId}/parts/${partNumber}`,
          body,
          {
            headers: {
              "content-type": "application/octet-stream",
              "content-length": String(body.byteLength),
            },
          },
        );
        const parsed = await parseJson(response);
        if (!isRecord(parsed) || typeof parsed.etag !== "string") {
          throw cliError("cloud.invalid_response", "Upload part response was missing etag.");
        }
        parts.push({ partNumber, etag: parsed.etag });
        offset += bytesRead;
        onEvent?.({
          type: "progress",
          command: "upload",
          filePath: plan.filePath,
          recordingId,
          status: "uploading",
          percent: Math.round((offset / plan.sizeBytes) * 100),
        });
        partNumber += 1;
      }
    } finally {
      await handle.close();
    }
    return parts;
  }

  private async getJob(jobId: string): Promise<JobData> {
    const parsed = await this.getJson<Record<string, unknown>>(`/api/jobs/${jobId}`);
    if (typeof parsed.id !== "string" || typeof parsed.status !== "string") {
      throw cliError("cloud.invalid_response", "Job response was missing id or status.");
    }
    const recording = isRecord(parsed.recording) ? parsed.recording : undefined;
    const processedDurationMs =
      typeof parsed.processedDurationMs === "number" || parsed.processedDurationMs === null
        ? parsed.processedDurationMs
        : undefined;
    const recordingDurationMs =
      recording && (typeof recording.durationMs === "number" || recording.durationMs === null)
        ? recording.durationMs
        : undefined;
    const progressPercent = jobProgressPercent(parsed, processedDurationMs, recordingDurationMs);
    return {
      jobId: parsed.id,
      origin: this.auth.origin,
      ...(typeof parsed.recordingId === "string" ? { recordingId: parsed.recordingId } : {}),
      status: parsed.status as JobData["status"],
      ...(typeof parsed.transcriptId === "string" || parsed.transcriptId === null
        ? { transcriptId: parsed.transcriptId }
        : {}),
      ...(typeof parsed.provider === "string" ? { provider: parsed.provider } : {}),
      ...(typeof parsed.model === "string" ? { model: parsed.model } : {}),
      ...(typeof parsed.language === "string" || parsed.language === null
        ? { language: parsed.language }
        : {}),
      ...(progressPercent !== undefined ? { progressPercent } : {}),
      ...(processedDurationMs !== undefined ? { processedDurationMs } : {}),
      ...(recording
        ? {
            recording: {
              ...(typeof recording.title === "string" || recording.title === null
                ? { title: recording.title }
                : {}),
              ...(recordingDurationMs !== undefined ? { durationMs: recordingDurationMs } : {}),
            },
          }
        : {}),
    };
  }

  private async getJson<T>(path: string): Promise<T> {
    const response = await this.request("GET", path);
    return (await parseJson(response)) as T;
  }

  private async postJson<T = unknown>(path: string, body: unknown): Promise<T> {
    const response = await this.request("POST", path, JSON.stringify(body), {
      headers: { "content-type": "application/json" },
    });
    return (await parseJson(response)) as T;
  }

  private async request(
    method: string,
    pathname: string,
    body?: BodyInit,
    opts: { headers?: Record<string, string>; allowAuthFailure?: boolean } = {},
  ): Promise<Response> {
    const token = requireToken(this.auth);
    let response: Response;
    try {
      response = await this.fetchImpl(new URL(pathname, this.auth.origin), {
        method,
        headers: {
          authorization: `Bearer ${token}`,
          ...opts.headers,
        },
        ...(body ? { body } : {}),
      });
    } catch (error) {
      if (error instanceof RecappiCliError) throw error;
      throw cliError(
        "cloud.http_error",
        `Recappi Cloud request failed: ${transportErrorMessage(error)}`,
        {
          retryable: true,
          hint: `Check your network connection and Recappi Cloud origin (${this.auth.origin}), then retry.`,
        },
      );
    }
    if (
      !response.ok &&
      !(opts.allowAuthFailure && (response.status === 401 || response.status === 403))
    ) {
      const message = await responseMessage(response);
      throw new RecappiCliError(describeHttpError(response.status, message));
    }
    return response;
  }
}

function transportErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return String(error || "network request failed");
}

async function parseJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    throw cliError("cloud.invalid_response", "Recappi Cloud returned invalid JSON.");
  }
}

async function responseMessage(response: Response): Promise<string> {
  try {
    const parsed = await response.clone().json();
    if (isRecord(parsed) && typeof parsed.message === "string") return parsed.message;
    if (isRecord(parsed) && typeof parsed.error === "string") return parsed.error;
  } catch {
    // Fall through to text.
  }
  try {
    const text = await response.text();
    return text.trim() || response.statusText;
  } catch {
    return response.statusText;
  }
}

function normalizeContentType(value: string | null): string {
  return value?.split(";")[0]?.trim().toLowerCase() || "audio/wav";
}

function numberHeader(value: string | null): number | undefined {
  if (!value) return undefined;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : undefined;
}

function audioExtensionForContentType(contentType: string): string {
  switch (contentType) {
    case "audio/mpeg":
    case "audio/mp3":
      return "mp3";
    case "audio/aiff":
    case "audio/x-aiff":
      return "aiff";
    case "audio/aac":
    case "audio/mp4":
    case "audio/m4a":
    case "audio/x-m4a":
      return "m4a";
    case "audio/ogg":
      return "ogg";
    case "audio/flac":
    case "audio/x-flac":
      return "flac";
    case "audio/webm":
      return "webm";
    case "audio/wav":
    case "audio/x-wav":
    default:
      return "wav";
  }
}

function recordingAudioFileName(
  recordingId: string,
  title: string | null | undefined,
  contentType: string,
): string {
  const idStem = truncateFileStem(safeFileStem(recordingId), 48);
  const titleStem = title ? truncateFileStem(safeFileStem(title), 80) : "";
  const stem = titleStem ? `${titleStem}-${idStem}` : idStem;
  return `${stem}.${audioExtensionForContentType(contentType)}`;
}

function truncateFileStem(value: string, maxLength: number): string {
  return [...value].slice(0, maxLength).join("");
}

function safeFileStem(value: string): string {
  const safe = value
    .normalize("NFKC")
    .replace(/[^\p{L}\p{N}._-]+/gu, "-")
    .replace(/^-+|-+$/g, "");
  return safe || "recording";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function mapTranscript(row: Record<string, unknown>): TranscriptData {
  const id = requiredString(row, "id");
  const recordingId = requiredString(row, "recordingId");
  const jobId = requiredString(row, "jobId");
  const provider = requiredString(row, "provider");
  const model = requiredString(row, "model");
  const text = requiredString(row, "text");
  const createdAt = requiredNumber(row, "createdAt");
  const durationMs =
    typeof row.durationMs === "number" || row.durationMs === null ? row.durationMs : undefined;
  const language =
    typeof row.language === "string" || row.language === null ? row.language : undefined;
  const data = {
    transcriptId: id,
    recordingId,
    jobId,
    provider,
    model,
    ...(language !== undefined ? { language } : {}),
    ...(durationMs !== undefined ? { durationMs } : {}),
    createdAt,
    text,
    segments: parseSegments(row.segmentsJson, text, durationMs),
    summary: parseSummary(row),
  };
  return transcriptDataSchema.parse(data);
}

function requiredString(row: Record<string, unknown>, key: string): string {
  const value = row[key];
  if (typeof value !== "string") {
    throw cliError("cloud.invalid_response", `Transcript response was missing ${key}.`);
  }
  return value;
}

function requiredNumber(row: Record<string, unknown>, key: string): number {
  const value = row[key];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw cliError("cloud.invalid_response", `Transcript response was missing ${key}.`);
  }
  return value;
}

function parseSegments(
  value: unknown,
  text: string,
  durationMs: number | null | undefined,
): TranscriptSegment[] {
  const decoded = decodeJsonArray(value);
  const rawSegments = decoded
    .filter(isRecord)
    .map((segment) => {
      const segmentText = typeof segment.text === "string" ? segment.text.trim() : "";
      if (!segmentText) return null;
      const start = typeof segment.start === "number" && segment.start >= 0 ? segment.start : 0;
      const end = typeof segment.end === "number" && segment.end >= 0 ? segment.end : start;
      return {
        start,
        end,
        text: segmentText,
        ...(typeof segment.speaker === "string" && segment.speaker.trim()
          ? { speaker: segment.speaker.trim() }
          : {}),
      };
    })
    .filter(
      (
        segment,
      ): segment is {
        start: number;
        end: number;
        text: string;
        speaker?: string;
      } => segment !== null,
    );
  const scale = segmentValueScaleToMs(rawSegments, durationMs);
  const segments = rawSegments.map((segment) => ({
    startMs: segment.start * scale,
    endMs: segment.end * scale,
    text: segment.text,
    ...(segment.speaker ? { speaker: segment.speaker } : {}),
  }));
  if (segments.length > 0) return segments;
  const fallbackText = text.trim();
  if (!fallbackText) return [];
  return [{ startMs: 0, endMs: durationMs ?? 0, text: fallbackText }];
}

function segmentValueScaleToMs(
  segments: { start: number; end: number }[],
  durationMs: number | null | undefined,
): number {
  let maxEnd = 0;
  for (const segment of segments) {
    if (segment.end > maxEnd) maxEnd = segment.end;
    if (segment.start > maxEnd) maxEnd = segment.start;
  }
  if (maxEnd <= 0) return 1000;
  if (durationMs && durationMs > 0) {
    return maxEnd * 1000 <= durationMs * 1.5 ? 1000 : 1;
  }
  // Without a duration hint, values above ten minutes are almost certainly
  // already milliseconds; smaller values are treated as seconds.
  return maxEnd > 600 ? 1 : 1000;
}

function parseSummary(row: Record<string, unknown>): TranscriptData["summary"] {
  const status = parseSummaryStatus(row.summaryStatus);
  const payload = decodeJsonRecord(row.summaryJson);
  const summary: TranscriptData["summary"] = { status };
  if (typeof payload?.title === "string" && payload.title.trim()) summary.title = payload.title;
  if (typeof payload?.tldr === "string" && payload.tldr.trim()) summary.tldr = payload.tldr;
  for (const key of ["keyPoints", "topics", "decisions"] as const) {
    const value = payload?.[key];
    if (Array.isArray(value)) {
      const strings = value.filter((item): item is string => typeof item === "string");
      if (strings.length > 0) summary[key] = strings;
    }
  }
  const actionItems = Array.isArray(payload?.actionItems)
    ? payload.actionItems.filter(isRecord).flatMap((item) => {
        if (typeof item.what !== "string" || !item.what.trim()) return [];
        return [{ what: item.what, ...(typeof item.who === "string" ? { who: item.who } : {}) }];
      })
    : [];
  if (actionItems.length > 0) summary.actionItems = actionItems;
  const quotes = Array.isArray(payload?.quotes)
    ? payload.quotes.filter(isRecord).flatMap((item) => {
        if (typeof item.text !== "string" || !item.text.trim()) return [];
        return [
          {
            text: item.text,
            ...(typeof item.speaker === "string" ? { speaker: item.speaker } : {}),
          },
        ];
      })
    : [];
  if (quotes.length > 0) summary.quotes = quotes;
  const timeline = Array.isArray(payload?.timeline)
    ? payload.timeline.filter(isRecord).flatMap((item) => {
        if (
          typeof item.startMs !== "number" ||
          typeof item.endMs !== "number" ||
          typeof item.title !== "string" ||
          typeof item.summary !== "string"
        ) {
          return [];
        }
        return [
          {
            startMs: item.startMs,
            endMs: item.endMs,
            title: item.title,
            summary: item.summary,
          },
        ];
      })
    : [];
  if (timeline.length > 0) summary.timeline = timeline;
  if (typeof row.summaryError === "string" && row.summaryError.trim()) {
    summary.error = row.summaryError;
  }
  return summary;
}

function mapJobListItem(row: Record<string, unknown>): JobListData["items"][number] {
  const recording = isRecord(row.recording) ? row.recording : {};
  return {
    jobId: stringValue(row.jobId) ?? stringValue(row.id) ?? "",
    recordingId: stringValue(row.recordingId) ?? "",
    status: (stringValue(row.status) ?? "queued") as JobListData["items"][number]["status"],
    ...(typeof row.provider === "string" ? { provider: row.provider } : {}),
    ...(typeof row.model === "string" ? { model: row.model } : {}),
    ...(typeof row.language === "string" || row.language === null
      ? { language: row.language }
      : {}),
    ...(typeof row.transcriptId === "string" || row.transcriptId === null
      ? { transcriptId: row.transcriptId }
      : {}),
    ...(typeof row.attempts === "number" ? { attempts: row.attempts } : {}),
    ...(typeof row.enqueuedAt === "number" || row.enqueuedAt === null
      ? { enqueuedAt: row.enqueuedAt }
      : {}),
    ...(typeof row.startedAt === "number" || row.startedAt === null
      ? { startedAt: row.startedAt }
      : {}),
    ...(typeof row.finishedAt === "number" || row.finishedAt === null
      ? { finishedAt: row.finishedAt }
      : {}),
    ...(typeof row.processedDurationMs === "number" || row.processedDurationMs === null
      ? { processedDurationMs: row.processedDurationMs }
      : {}),
    ...(typeof row.heartbeatPhase === "string" || row.heartbeatPhase === null
      ? { heartbeatPhase: row.heartbeatPhase }
      : {}),
    recording: {
      ...(typeof recording.title === "string" || recording.title === null
        ? { title: recording.title }
        : {}),
      ...(typeof recording.durationMs === "number" || recording.durationMs === null
        ? { durationMs: recording.durationMs }
        : {}),
      ...(typeof recording.createdAt === "number" || recording.createdAt === null
        ? { createdAt: recording.createdAt }
        : {}),
    },
  };
}

function mapRecording(row: Record<string, unknown>, origin: string): RecordingData {
  const recordingId = stringValue(row.id) ?? stringValue(row.recordingId);
  const status = stringValue(row.status);
  const createdAt = numberValue(row.createdAt);
  const updatedAt = numberValue(row.updatedAt);
  if (!recordingId) {
    throw cliError("cloud.invalid_response", "Recording response was missing id.");
  }
  if (!status) {
    throw cliError("cloud.invalid_response", "Recording response was missing status.");
  }
  if (createdAt === undefined || updatedAt === undefined) {
    throw cliError("cloud.invalid_response", "Recording response was missing timestamps.");
  }
  return recordingDataSchema.parse({
    recordingId,
    ...(typeof row.title === "string" || row.title === null ? { title: row.title } : {}),
    ...(typeof row.summaryTitle === "string" || row.summaryTitle === null
      ? { summaryTitle: row.summaryTitle }
      : {}),
    status,
    ...(typeof row.durationMs === "number" || row.durationMs === null
      ? { durationMs: row.durationMs }
      : {}),
    ...(typeof row.sizeBytes === "number" || row.sizeBytes === null
      ? { sizeBytes: row.sizeBytes }
      : {}),
    ...(typeof row.contentType === "string" ? { contentType: row.contentType } : {}),
    ...(typeof row.activeTranscriptId === "string" || row.activeTranscriptId === null
      ? { activeTranscriptId: row.activeTranscriptId }
      : {}),
    createdAt,
    updatedAt,
    origin,
  });
}

function mapDashboardStats(row: Record<string, unknown>, origin: string): DashboardStatsData {
  return dashboardStatsDataSchema.parse({
    origin,
    recordings: mapCountObject(row.recordings, [
      "total",
      "ready",
      "uploading",
      "failed",
      "aborted",
      "totalDurationMs",
      "totalSizeBytes",
    ]),
    jobs: mapCountObject(row.jobs, ["active", "queued", "running", "succeeded", "failed"]),
  });
}

function mapBillingStatus(row: Record<string, unknown>, origin: string): BillingStatusData {
  return billingStatusDataSchema.parse({
    origin,
    tier: row.tier,
    periodStart: numberValue(row.periodStart),
    periodEnd: numberValue(row.periodEnd),
    storageBytes: numberValue(row.storageBytes) ?? 0,
    storageCapBytes: nullableCap(row.storageCapBytes),
    minutesUsed: numberValue(row.minutesUsed) ?? 0,
    batchMinutesUsed: numberValue(row.batchMinutesUsed) ?? 0,
    realtimeMinutesUsed: numberValue(row.realtimeMinutesUsed) ?? 0,
    minutesCap: nullableCap(row.minutesCap),
    isOverStorage: row.isOverStorage === true,
    isOverMinutes: row.isOverMinutes === true,
  });
}

function mapCountObject(value: unknown, keys: string[]): Record<string, number> {
  const source = isRecord(value) ? value : {};
  return Object.fromEntries(keys.map((key) => [key, numberValue(source[key]) ?? 0]));
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function recordingCloudUrl(origin: string, recordingId: string): string {
  return `${origin.replace(/\/+$/, "")}/recordings/${encodeURIComponent(recordingId)}`;
}

function jobProgressPercent(
  row: Record<string, unknown>,
  processedDurationMs: number | null | undefined,
  recordingDurationMs: number | null | undefined,
): number | undefined {
  const chunkProgress = isRecord(row.chunkProgress) ? row.chunkProgress : undefined;
  const chunkPercent = numberValue(chunkProgress?.percent);
  if (chunkPercent !== undefined) return clampPercent(chunkPercent);
  if (
    typeof processedDurationMs === "number" &&
    typeof recordingDurationMs === "number" &&
    recordingDurationMs > 0
  ) {
    return clampPercent((processedDurationMs / recordingDurationMs) * 100);
  }
  return undefined;
}

function clampPercent(value: number): number {
  return Math.max(0, Math.min(100, Math.round(value)));
}

function nullableCap(value: unknown): number | null {
  if (value === null) return null;
  const number = numberValue(value);
  return number === undefined ? null : number;
}

function parseSummaryStatus(value: unknown): SummaryStatus {
  const allowed = new Set<SummaryStatus>([
    "pending",
    "queued",
    "running",
    "succeeded",
    "failed",
    "skipped",
  ]);
  return typeof value === "string" && allowed.has(value as SummaryStatus)
    ? (value as SummaryStatus)
    : "pending";
}

function decodeJsonArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (typeof value !== "string" || !value.trim()) return [];
  try {
    const decoded = JSON.parse(value);
    return Array.isArray(decoded) ? decoded : [];
  } catch {
    return [];
  }
}

function decodeJsonRecord(value: unknown): Record<string, unknown> | null {
  if (isRecord(value)) return value;
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const decoded = JSON.parse(value);
    return isRecord(decoded) ? decoded : null;
  } catch {
    return null;
  }
}
