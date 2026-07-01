import {
  CLI_SCHEMA_VERSION,
  cliEnvelopeSchema,
  operationEventSchema,
  type CliEnvelope,
  type CliErrorDescriptor,
  type OperationEvent,
  type UploadBatchData,
} from "../../packages/contracts/src/index";

export type OutputMode = "human" | "json" | "jsonl";

export interface HumanProgressState {
  interactive: boolean;
  activeLineLength: number;
  lastLineByScope: Map<string, string>;
  lastUploadBucketByScope: Map<string, number>;
}

export interface RenderOptions {
  mode: OutputMode;
  compact?: boolean;
  fields?: string[];
  stdout: (text: string) => void;
  stderr: (text: string) => void;
  progress?: HumanProgressState;
}

export function createHumanProgressState(interactive: boolean): HumanProgressState {
  return {
    interactive,
    activeLineLength: 0,
    lastLineByScope: new Map(),
    lastUploadBucketByScope: new Map(),
  };
}

export function renderSuccess(command: string, data: unknown, opts: RenderOptions): void {
  const filtered = applyFields(command, data, opts.fields, opts.compact === true);
  if (opts.mode === "jsonl") {
    renderEvent(
      { type: "result", command, data: filtered, meta: { schemaVersion: CLI_SCHEMA_VERSION } },
      opts,
    );
    return;
  }
  if (opts.mode === "json") {
    const envelope: CliEnvelope = {
      ok: true,
      command,
      data: filtered,
      meta: { schemaVersion: CLI_SCHEMA_VERSION },
    };
    renderEnvelope(envelope, opts);
    return;
  }
  finishHumanProgress(opts);
  renderHumanSuccess(command, filtered, opts);
}

export function renderFailure(
  command: string,
  error: CliErrorDescriptor,
  opts: RenderOptions,
  data?: unknown,
): void {
  if (opts.mode === "jsonl") {
    renderEvent(
      {
        type: "error",
        command,
        error,
        ...(data ? { data } : {}),
        meta: { schemaVersion: CLI_SCHEMA_VERSION },
      },
      opts,
    );
    return;
  }
  if (opts.mode === "json") {
    const envelope: CliEnvelope = {
      ok: false,
      command,
      error,
      ...(data ? { data } : {}),
      meta: { schemaVersion: CLI_SCHEMA_VERSION },
    };
    renderEnvelope(envelope, opts);
    return;
  }
  finishHumanProgress(opts);
  opts.stderr(`recappi: ${error.message}\n`);
  if (command === "upload" && isUploadBatch(data) && data.failures.length > 0) {
    opts.stderr("Failures:\n");
    for (const item of data.failures) {
      const label = humanFileLabel(item.filePath) ?? item.filePath;
      opts.stderr(`  ${label}: ${item.error.message} (${item.error.code})\n`);
    }
  }
  if (error.hint) opts.stderr(`${error.hint}\n`);
}

export function renderEvent(event: OperationEvent, opts: RenderOptions): void {
  if (opts.mode === "jsonl") {
    const parsed = operationEventSchema.parse(event);
    opts.stdout(`${stableStringify(parsed, true)}\n`);
    return;
  }
  if ((event.type === "started" || event.type === "progress") && opts.mode === "human") {
    const line = formatHumanProgress(event, opts);
    if (line) writeHumanProgress(line, opts);
  }
}

function renderEnvelope(envelope: CliEnvelope, opts: RenderOptions): void {
  const parsed = cliEnvelopeSchema.parse(envelope);
  opts.stdout(`${stableStringify(parsed, opts.compact === true)}\n`);
}

function renderHumanSuccess(command: string, data: unknown, opts: RenderOptions): void {
  if (command === "auth login" && isRecord(data)) {
    opts.stdout(`Signed in${typeof data.email === "string" ? ` as ${data.email}` : ""}\n`);
    return;
  }
  if (command === "auth logout" && isRecord(data)) {
    opts.stdout(data.cleared ? "Signed out of Recappi CLI\n" : "No Recappi CLI session to clear\n");
    return;
  }
  if (command === "auth import-macos" && isRecord(data)) {
    opts.stdout("Imported the Recappi Mini app session into Recappi CLI\n");
    return;
  }
  if (command === "auth status" && isRecord(data)) {
    if (data.loggedIn) {
      opts.stdout(`Signed in${typeof data.email === "string" ? ` as ${data.email}` : ""}\n`);
      return;
    }
    opts.stdout("Not logged in\n");
    return;
  }
  if (command === "account status" && isRecord(data)) {
    if (!data.loggedIn) {
      opts.stdout("Not logged in\n");
      return;
    }
    opts.stdout(`Account: ${typeof data.email === "string" ? data.email : "signed in"}\n`);
    if (typeof data.origin === "string") opts.stdout(`  origin: ${data.origin}\n`);
    if (typeof data.userId === "string") opts.stdout(`  userId: ${data.userId}\n`);
    const billing = isRecord(data.billing) ? data.billing : {};
    if (typeof billing.tier === "string") opts.stdout(`  plan: ${billing.tier}\n`);
    if (typeof billing.minutesUsed === "number") {
      const cap = formatNullableCap(billing.minutesCap, "minutes");
      opts.stdout(`  minutes: ${billing.minutesUsed} / ${cap}\n`);
    }
    if (typeof billing.storageBytes === "number") {
      const cap = formatNullableCap(billing.storageCapBytes, "bytes");
      opts.stdout(`  storage: ${formatBytes(billing.storageBytes)} / ${cap}\n`);
    }
    const localStore = isRecord(data.localStore) ? data.localStore : {};
    if (typeof localStore.path === "string") opts.stdout(`  localStore: ${localStore.path}\n`);
    opts.stdout(
      `  localArtifacts: ${numberText(localStore.accountScopedArtifacts)} current, ${numberText(localStore.unattributedArtifacts)} unattributed\n`,
    );
    return;
  }
  if (command === "version" && isRecord(data) && typeof data.version === "string") {
    opts.stdout(`${data.version}\n`);
    return;
  }
  if (command === "doctor" && isRecord(data) && Array.isArray(data.checks)) {
    const status = typeof data.status === "string" ? data.status : "unknown";
    opts.stdout(`Doctor: ${status}\n`);
    for (const check of data.checks) {
      if (!isRecord(check)) continue;
      const checkStatus = typeof check.status === "string" ? check.status : "unknown";
      const name = typeof check.name === "string" ? check.name : "check";
      const message = typeof check.message === "string" ? ` — ${check.message}` : "";
      opts.stdout(`  ${checkStatus} ${name}${message}\n`);
      if (typeof check.hint === "string") opts.stdout(`    ${check.hint}\n`);
    }
    return;
  }
  if (command === "transcript get" && isRecord(data)) {
    renderTranscriptHuman(data, opts);
    return;
  }
  if (command === "recordings list" && isRecord(data) && Array.isArray(data.items)) {
    opts.stdout("Recordings:\n");
    for (const item of data.items) {
      if (!isRecord(item)) continue;
      opts.stdout(`  ${recordingLabel(item)}\n`);
    }
    if (data.items.length === 0) opts.stdout("  No recordings found.\n");
    if (typeof data.nextCursor === "string") {
      opts.stdout(`\nNext cursor: ${data.nextCursor}\n`);
    }
    return;
  }
  if (command === "recordings get" && isRecord(data)) {
    opts.stdout(`${recordingTitle(data)}\n`);
    opts.stdout(`  recordingId: ${String(data.recordingId)}\n`);
    if (typeof data.status === "string") opts.stdout(`  status: ${data.status}\n`);
    if (typeof data.durationMs === "number")
      opts.stdout(`  duration: ${formatDurationMs(data.durationMs)}\n`);
    if (typeof data.sizeBytes === "number") opts.stdout(`  size: ${formatBytes(data.sizeBytes)}\n`);
    if (typeof data.activeTranscriptId === "string") {
      opts.stdout(`  activeTranscriptId: ${data.activeTranscriptId}\n`);
      opts.stdout(`\nNext:\n  recappi transcript get ${data.activeTranscriptId}\n`);
    }
    return;
  }
  if (command === "recordings retranscribe" && isRecord(data)) {
    opts.stdout("Transcription started\n");
    if (typeof data.recordingId === "string") opts.stdout(`  recordingId: ${data.recordingId}\n`);
    if (typeof data.jobId === "string") opts.stdout(`  jobId: ${data.jobId}\n`);
    if (typeof data.status === "string") opts.stdout(`  status: ${data.status}\n`);
    if (typeof data.transcriptId === "string") {
      opts.stdout(`  transcriptId: ${data.transcriptId}\n`);
      opts.stdout(`\nNext:\n  recappi transcript get ${data.transcriptId}\n`);
    } else if (typeof data.jobId === "string") {
      opts.stdout(`\nNext:\n  recappi jobs wait ${data.jobId}\n`);
    }
    return;
  }
  if (command === "dashboard stats" && isRecord(data)) {
    const recordings = isRecord(data.recordings) ? data.recordings : {};
    const jobs = isRecord(data.jobs) ? data.jobs : {};
    opts.stdout(
      `Recordings: ${numberText(recordings.total)} total, ${numberText(recordings.ready)} ready\n`,
    );
    opts.stdout(
      `Jobs: ${numberText(jobs.active)} active (${numberText(jobs.queued)} queued, ${numberText(jobs.running)} running)\n`,
    );
    return;
  }
  if (command === "upload" && isUploadBatch(data)) {
    if (data.successes.length > 0) {
      opts.stdout(data.successes.length === 1 ? "Upload complete\n" : "Uploads complete\n");
    }
    for (const item of data.successes) {
      opts.stdout(`  recordingId: ${item.recordingId}\n`);
      if (item.jobId) opts.stdout(`  jobId: ${item.jobId}\n`);
      if (item.transcriptId) {
        opts.stdout(`  transcriptId: ${item.transcriptId}\n`);
        opts.stdout(`\nNext:\n  recappi transcript get ${item.transcriptId}\n`);
      } else if (item.jobId) {
        opts.stdout(`\nNext:\n  recappi jobs wait ${item.jobId}\n`);
      }
    }
    for (const item of data.failures) {
      opts.stderr(`${item.filePath}: ${item.error.message}\n`);
    }
    return;
  }
  if (command === "record" && isRecord(data)) {
    opts.stdout("Recording complete\n");
    if (typeof data.recordingId === "string") opts.stdout(`  recordingId: ${data.recordingId}\n`);
    if (typeof data.jobId === "string") opts.stdout(`  jobId: ${data.jobId}\n`);
    if (typeof data.transcriptId === "string") {
      opts.stdout(`  transcriptId: ${data.transcriptId}\n`);
    }
    if (typeof data.sessionId === "string") opts.stdout(`  sessionId: ${data.sessionId}\n`);
    if (typeof data.localSessionRef === "string") {
      opts.stdout(`  localSessionRef: ${data.localSessionRef}\n`);
    }
    if (Array.isArray(data.artifacts) && data.artifacts.length > 0) {
      opts.stdout("  artifacts:\n");
      for (const artifact of data.artifacts) {
        if (!isRecord(artifact)) continue;
        const kind = typeof artifact.kind === "string" ? artifact.kind : "artifact";
        const localPath = typeof artifact.localPath === "string" ? artifact.localPath : "";
        opts.stdout(`    - ${kind}: ${localPath}\n`);
      }
    }
    const cloudHandoffError = isRecord(data.cloudHandoffError) ? data.cloudHandoffError : undefined;
    if (cloudHandoffError && typeof cloudHandoffError.message === "string") {
      opts.stderr(`Cloud handoff failed: ${cloudHandoffError.message}\n`);
      if (typeof cloudHandoffError.hint === "string") opts.stderr(`${cloudHandoffError.hint}\n`);
    }
    if (typeof data.transcriptId === "string") {
      opts.stdout(`\nNext:\n  recappi transcript get ${data.transcriptId}\n`);
    } else if (typeof data.jobId === "string") {
      opts.stdout(`\nNext:\n  recappi jobs wait ${data.jobId}\n`);
    } else if (typeof data.recordingId === "string") {
      opts.stdout(`\nNext:\n  recappi recordings get ${data.recordingId}\n`);
    }
    return;
  }
  if (command === "audio" && isRecord(data)) {
    const action = typeof data.action === "string" ? data.action : "download";
    opts.stdout(
      action === "open"
        ? "Audio opened\n"
        : action === "reveal"
          ? "Audio revealed\n"
          : "Audio ready\n",
    );
    if (typeof data.recordingId === "string") opts.stdout(`  recordingId: ${data.recordingId}\n`);
    if (typeof data.localPath === "string") opts.stdout(`  localPath: ${data.localPath}\n`);
    if (typeof data.reused === "boolean") {
      opts.stdout(`  source: ${data.reused ? "local cache" : "downloaded"}\n`);
    }
    return;
  }
  if ((command === "jobs wait" || command === "upload") && isRecord(data)) {
    if (typeof data.transcriptId === "string") {
      opts.stdout("Transcription ready\n");
      opts.stdout(`  transcriptId: ${data.transcriptId}\n`);
      opts.stdout(`\nNext:\n  recappi transcript get ${data.transcriptId}\n`);
      return;
    }
    if (typeof data.jobId === "string") {
      opts.stdout(`Job: ${data.jobId}\n`);
      opts.stdout(`\nNext:\n  recappi jobs wait ${data.jobId}\n`);
    }
    return;
  }
  if (command === "schema" && isRecord(data) && Array.isArray(data.commands)) {
    // Human mode gives a readable index; the full JSON Schemas are agent-facing,
    // so we point at --json rather than dumping them to a terminal.
    opts.stdout("Commands:\n");
    for (const entry of data.commands) {
      if (!isRecord(entry) || typeof entry.name !== "string") continue;
      const summary = typeof entry.summary === "string" ? ` — ${entry.summary}` : "";
      opts.stdout(`  ${entry.name}${summary}\n`);
      if (Array.isArray(entry.capabilities) && entry.capabilities.length > 0) {
        opts.stdout(`    capabilities: ${entry.capabilities.join(", ")}\n`);
      }
      if (Array.isArray(entry.examples) && entry.examples.length > 0) {
        const first = entry.examples.find(
          (example) => isRecord(example) && typeof example.command === "string",
        );
        if (isRecord(first) && typeof first.command === "string") {
          opts.stdout(`    example: ${first.command}\n`);
        }
      }
    }
    const errorCount = Array.isArray(data.errorCodes) ? data.errorCodes.length : 0;
    opts.stdout(`\n${errorCount} error codes. Run recappi schema --json for the full contract.\n`);
    return;
  }
  opts.stdout(`${stableStringify(data, true)}\n`);
}

function formatHumanProgress(event: OperationEvent, opts: RenderOptions): string | undefined {
  const scope = progressScope(event);
  let line: string | undefined;
  if (event.type === "started") {
    const label = humanFileLabel(event.filePath);
    line = label ? `Preparing ${label}` : "Preparing upload";
  } else if (event.command === "upload") {
    line = formatUploadProgress(event, opts, scope);
  } else if (event.command === "jobs wait") {
    line = formatJobProgress(event);
  } else if (event.message) {
    line = event.message;
  }

  if (!line) return undefined;
  const state = opts.progress;
  if (!state) return line;
  if (state.lastLineByScope.get(scope) === line) return undefined;
  state.lastLineByScope.set(scope, line);
  return line;
}

function formatUploadProgress(
  event: OperationEvent,
  opts: RenderOptions,
  scope: string,
): string | undefined {
  if (event.status === "uploading" && typeof event.percent === "number") {
    const state = opts.progress;
    const bucket = Math.min(100, Math.max(0, Math.floor(event.percent / 10) * 10));
    const previous = state?.lastUploadBucketByScope.get(scope);
    if (previous !== undefined && bucket <= previous && bucket !== 100) return undefined;
    state?.lastUploadBucketByScope.set(scope, bucket);
    return `Uploading${event.filePath ? ` ${humanFileLabel(event.filePath)}` : ""}: ${event.percent}%`;
  }

  if (event.status === "finishing_upload") return "Finalizing upload";
  if (event.status === "starting_transcription") return "Starting transcription";
  return formatJobProgress(event);
}

function formatJobProgress(event: OperationEvent): string | undefined {
  switch (event.status) {
    case "queued":
      return "Waiting for transcription";
    case "running":
      return "Transcribing";
    case "succeeded":
      return "Transcription ready";
    case "failed":
      return "Transcription failed";
    default:
      return event.message;
  }
}

function writeHumanProgress(line: string, opts: RenderOptions): void {
  const state = opts.progress;
  if (!state?.interactive) {
    opts.stderr(`${line}\n`);
    return;
  }
  const padding =
    state.activeLineLength > line.length ? " ".repeat(state.activeLineLength - line.length) : "";
  opts.stderr(`\r${line}${padding}`);
  state.activeLineLength = line.length;
}

function finishHumanProgress(opts: RenderOptions): void {
  const state = opts.progress;
  if (!state?.interactive || state.activeLineLength === 0) return;
  opts.stderr("\n");
  state.activeLineLength = 0;
}

function progressScope(event: OperationEvent): string {
  return [event.command, event.filePath, event.recordingId, event.jobId].filter(Boolean).join(":");
}

function humanFileLabel(filePath: string | undefined): string | undefined {
  if (!filePath) return undefined;
  const normalized = filePath.replaceAll("\\", "/");
  return normalized.split("/").filter(Boolean).at(-1) ?? filePath;
}

// Human transcript view: timestamped, speaker-attributed lines a person can
// actually read, then the summary highlights. The full structured payload
// (topics, decisions, quotes, timeline, raw seconds) stays in --json for agents;
// human mode shows the parts a reader scans first.
function renderTranscriptHuman(data: Record<string, unknown>, opts: RenderOptions): void {
  const segments = Array.isArray(data.segments) ? data.segments : [];
  let printedBody = false;
  for (const segment of segments) {
    if (!isRecord(segment) || typeof segment.text !== "string") continue;
    const clock =
      typeof segment.startMs === "number" ? `[${formatClock(segment.startMs / 1000)}] ` : "";
    const speaker = typeof segment.speaker === "string" ? `${segment.speaker}: ` : "";
    opts.stdout(`${clock}${speaker}${segment.text}\n`);
    printedBody = true;
  }
  // Fall back to the flat text when the provider returned no segments.
  if (!printedBody && typeof data.text === "string") {
    opts.stdout(data.text.endsWith("\n") ? data.text : `${data.text}\n`);
    printedBody = true;
  }

  const summary = isRecord(data.summary) ? data.summary : undefined;
  if (!summary || summary.status !== "succeeded") return;
  if (typeof summary.tldr === "string" && summary.tldr.length > 0) {
    opts.stdout(`\nSummary:\n  ${summary.tldr}\n`);
  }
  if (Array.isArray(summary.keyPoints) && summary.keyPoints.length > 0) {
    opts.stdout("\nKey points:\n");
    for (const point of summary.keyPoints) {
      if (typeof point === "string") opts.stdout(`  - ${point}\n`);
    }
  }
  if (Array.isArray(summary.actionItems) && summary.actionItems.length > 0) {
    opts.stdout("\nAction items:\n");
    for (const item of summary.actionItems) {
      if (!isRecord(item) || typeof item.what !== "string") continue;
      const who = typeof item.who === "string" ? `${item.who}: ` : "";
      opts.stdout(`  - ${who}${item.what}\n`);
    }
  }
}

function recordingLabel(item: Record<string, unknown>): string {
  const id = typeof item.recordingId === "string" ? item.recordingId : "unknown";
  const status = typeof item.status === "string" ? item.status : "unknown";
  const duration =
    typeof item.durationMs === "number" ? ` · ${formatDurationMs(item.durationMs)}` : "";
  return `${recordingTitle(item)} (${status}, ${id}${duration})`;
}

function recordingTitle(item: Record<string, unknown>): string {
  for (const key of ["title", "summaryTitle"] as const) {
    const value = item[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "Untitled recording";
}

function numberText(value: unknown): string {
  return typeof value === "number" && Number.isFinite(value) ? value.toLocaleString("en-US") : "0";
}

function formatDurationMs(ms: number): string {
  return formatClock(ms / 1000);
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = units[0]!;
  for (const next of units.slice(1)) {
    if (value < 1024) break;
    value /= 1024;
    unit = next;
  }
  return `${value >= 10 ? value.toFixed(0) : value.toFixed(1)} ${unit}`;
}

function formatNullableCap(value: unknown, unit: "bytes" | "minutes"): string {
  if (value === null || value === undefined) return "Unlimited";
  if (typeof value !== "number" || !Number.isFinite(value)) return "Unlimited";
  return unit === "bytes" ? formatBytes(value) : String(value);
}

// seconds -> mm:ss, widening to h:mm:ss only past the hour mark.
function formatClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  const mm = String(minutes).padStart(2, "0");
  const ss = String(secs).padStart(2, "0");
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
}

function applyFields(
  command: string,
  data: unknown,
  fields: string[] | undefined,
  compact: boolean,
): unknown {
  if (!fields || fields.length === 0) return compact ? compactData(data) : data;
  if (command === "upload") {
    if (!isUploadBatch(data)) return data;
    const allowed = new Set([
      "filePath",
      "recordingId",
      "jobId",
      "transcriptId",
      "status",
      "origin",
    ]);
    assertKnownFields(fields, allowed);
    const filtered = {
      ...data,
      successes: data.successes.map((item) => pickFields(item, fields)),
    };
    return compact ? compactData(filtered) : filtered;
  }
  if (!isRecord(data)) return data;
  const allowed = new Set(Object.keys(data));
  assertKnownFields(fields, allowed);
  const filtered = pickFields(data, fields);
  return compact ? compactData(filtered) : filtered;
}

function assertKnownFields(fields: string[], allowed: Set<string>): void {
  const unknown = fields.filter((field) => !allowed.has(field));
  if (unknown.length > 0) {
    throw new Error(
      `Unknown --fields: ${unknown.join(", ")}. Allowed fields: ${[...allowed].sort().join(", ")}`,
    );
  }
}

function pickFields(obj: Record<string, unknown>, fields: string[]): Record<string, unknown> {
  const picked: Record<string, unknown> = {};
  for (const field of fields) {
    if (field in obj) picked[field] = obj[field];
  }
  return picked;
}

function compactData(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(compactData).filter((item) => item !== undefined);
  }
  if (isRecord(value)) {
    const out: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(value)) {
      const compacted = compactData(child);
      if (compacted === undefined) continue;
      if (Array.isArray(compacted) && compacted.length === 0) continue;
      if (compacted === null) continue;
      out[key] = compacted;
    }
    return out;
  }
  return value === "" || value === undefined ? undefined : value;
}

function stableStringify(value: unknown, compact: boolean): string {
  return JSON.stringify(sortKeys(value), null, compact ? 0 : 2);
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (!isRecord(value)) return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((key) => [key, sortKeys(value[key])]),
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUploadBatch(value: unknown): value is UploadBatchData {
  return isRecord(value) && Array.isArray(value.successes) && Array.isArray(value.failures);
}
