import { z } from "zod";

export const CLI_SCHEMA_VERSION = "2026-06-25";

// A zod schema from this package. Re-exported so consumers (e.g. the CLI's
// `schema` command) can hold contract schemas without taking a direct zod
// dependency — zod stays an implementation detail owned here.
export type ContractSchema = z.ZodType;

// Native zod v4 JSON Schema export — no third-party converter needed. Centralised
// here so every machine-readable contract dump uses the same dialect/options.
export function toJsonSchema(schema: ContractSchema): unknown {
  return z.toJSONSchema(schema, { target: "draft-2020-12" });
}

export const supportedAudioTypes = [
  "audio/wav",
  "audio/mp3",
  "audio/aiff",
  "audio/aac",
  "audio/ogg",
  "audio/flac",
] as const;

export const supportedAudioTypeSchema = z.enum(supportedAudioTypes);
export type SupportedAudioType = z.infer<typeof supportedAudioTypeSchema>;

export function normalizeAudioType(value: string): SupportedAudioType | null {
  const lower = value.toLowerCase().trim();
  const canonical =
    lower === "audio/mpeg"
      ? "audio/mp3"
      : lower === "audio/x-aiff"
        ? "audio/aiff"
        : lower === "audio/x-flac"
          ? "audio/flac"
          : lower === "audio/mp4" || lower === "audio/m4a"
            ? "audio/aac"
            : lower;
  return supportedAudioTypes.includes(canonical as SupportedAudioType)
    ? (canonical as SupportedAudioType)
    : null;
}

export const transcriptionJobStatusSchema = z.enum(["queued", "running", "succeeded", "failed"]);
export type TranscriptionJobStatus = z.infer<typeof transcriptionJobStatusSchema>;

export const recordingStatusSchema = z.enum(["uploading", "ready", "failed", "aborted"]);
export type RecordingStatus = z.infer<typeof recordingStatusSchema>;

export const cliErrorCodeSchema = z.enum([
  "usage.invalid_argument",
  "usage.missing_command",
  "auth.not_logged_in",
  "auth.unauthorized",
  "input.not_found",
  "input.not_file",
  "input.unsupported_audio",
  "input.duration_unavailable",
  "input.partial_failure",
  "record.helper_unavailable",
  "record.unsupported_platform",
  "record.capture_unavailable",
  "cloud.conflict.upload_in_progress",
  "cloud.recording_not_ready",
  "cloud.job_failed",
  "cloud.job_timed_out",
  "cloud.http_error",
  "cloud.invalid_response",
  "internal.unexpected",
]);
export type CliErrorCode = z.infer<typeof cliErrorCodeSchema>;

export const cliErrorDescriptorSchema = z.object({
  code: cliErrorCodeSchema,
  exitCode: z.number().int().min(1).max(255),
  retryable: z.boolean(),
  message: z.string(),
  hint: z.string().optional(),
});
export type CliErrorDescriptor = z.infer<typeof cliErrorDescriptorSchema>;

export const cliMetaSchema = z.object({
  schemaVersion: z.literal(CLI_SCHEMA_VERSION),
});
export type CliMeta = z.infer<typeof cliMetaSchema>;

export const authStatusDataSchema = z.object({
  loggedIn: z.boolean(),
  origin: z.string(),
  email: z.string().optional(),
  userId: z.string().optional(),
});
export type AuthStatusData = z.infer<typeof authStatusDataSchema>;

export const authLoginDataSchema = z.object({
  loggedIn: z.literal(true),
  origin: z.string(),
  email: z.string().optional(),
  userId: z.string().optional(),
});
export type AuthLoginData = z.infer<typeof authLoginDataSchema>;

export const authLogoutDataSchema = z.object({
  loggedIn: z.literal(false),
  origin: z.string(),
  cleared: z.boolean(),
});
export type AuthLogoutData = z.infer<typeof authLogoutDataSchema>;

export const authImportDataSchema = z.object({
  imported: z.boolean(),
  origin: z.string(),
  source: z.literal("macos-keychain"),
});
export type AuthImportData = z.infer<typeof authImportDataSchema>;

export const planTierSchema = z.enum(["free", "starter", "pro", "business", "unlimited"]);
export type PlanTier = z.infer<typeof planTierSchema>;

// JSON cannot represent Infinity, so unlimited caps may cross the wire as null.
// CLI consumers should treat null caps as "unlimited" rather than "unknown".
export const billingStatusDataSchema = z.object({
  origin: z.string(),
  tier: planTierSchema,
  periodStart: z.number().int(),
  periodEnd: z.number().int(),
  storageBytes: z.number().int().nonnegative(),
  storageCapBytes: z.number().int().nonnegative().nullable(),
  minutesUsed: z.number().nonnegative(),
  batchMinutesUsed: z.number().nonnegative(),
  realtimeMinutesUsed: z.number().nonnegative(),
  minutesCap: z.number().nonnegative().nullable(),
  isOverStorage: z.boolean(),
  isOverMinutes: z.boolean(),
});
export type BillingStatusData = z.infer<typeof billingStatusDataSchema>;

export const accountStatusDataSchema = z.object({
  origin: z.string(),
  loggedIn: z.boolean(),
  email: z.string().optional(),
  userId: z.string().optional(),
  localStore: z.object({
    path: z.string(),
    accountScopedArtifacts: z.number().int().nonnegative(),
    unattributedArtifacts: z.number().int().nonnegative(),
  }),
  billing: billingStatusDataSchema.optional(),
});
export type AccountStatusData = z.infer<typeof accountStatusDataSchema>;

export const SIDECAR_PROTOCOL_VERSION = 1;

export const sidecarJsonRpcIdSchema = z.union([z.string(), z.number().int()]);
export type SidecarJsonRpcId = z.infer<typeof sidecarJsonRpcIdSchema>;

export const sidecarCapabilitySchema = z.enum([
  "recording.capture",
  "recording.upload",
  "live_captions.stream",
  "local_artifacts.index",
]);
export type SidecarCapability = z.infer<typeof sidecarCapabilitySchema>;

export const sidecarAccountSchema = z.object({
  backendOrigin: z.string(),
  userId: z.string(),
  email: z.string().optional(),
});
export type SidecarAccount = z.infer<typeof sidecarAccountSchema>;

export const sidecarClientInfoSchema = z.object({
  name: z.string(),
  version: z.string(),
});
export type SidecarClientInfo = z.infer<typeof sidecarClientInfoSchema>;

export const sidecarInfoSchema = z.object({
  name: z.string(),
  version: z.string(),
});
export type SidecarInfo = z.infer<typeof sidecarInfoSchema>;

export const sidecarRecordingOptionsSchema = z.object({
  includeSystemAudio: z.boolean().default(true),
  includeMicrophone: z.boolean().default(true),
  liveCaptions: z.boolean().default(false),
  translationLanguage: z.string().optional(),
  transcriptionLanguage: z.string().optional(),
  title: z.string().optional(),
});
export type SidecarRecordingOptions = z.infer<typeof sidecarRecordingOptionsSchema>;

export const sidecarRecordingStateSchema = z.enum([
  "idle",
  "starting",
  "recording",
  "stopping",
  "finalizing",
  "uploading",
  "completed",
  "failed",
  "cancelled",
]);
export type SidecarRecordingState = z.infer<typeof sidecarRecordingStateSchema>;

export const sidecarLocalArtifactKindSchema = z.enum([
  "recording_session",
  "download",
  "live_caption_draft",
]);
export type SidecarLocalArtifactKind = z.infer<typeof sidecarLocalArtifactKindSchema>;

export const sidecarLocalArtifactSchema = z.object({
  kind: sidecarLocalArtifactKindSchema,
  localPath: z.string(),
  remoteId: z.string().optional(),
  metadata: z.unknown().optional(),
});
export type SidecarLocalArtifact = z.infer<typeof sidecarLocalArtifactSchema>;

export const sidecarHandshakeParamsSchema = z.object({
  protocolVersion: z.literal(SIDECAR_PROTOCOL_VERSION),
  client: sidecarClientInfoSchema,
  account: sidecarAccountSchema.optional(),
  capabilities: z.array(sidecarCapabilitySchema),
});
export type SidecarHandshakeParams = z.infer<typeof sidecarHandshakeParamsSchema>;

export const sidecarHandshakeResultSchema = z.object({
  protocolVersion: z.literal(SIDECAR_PROTOCOL_VERSION),
  sidecar: sidecarInfoSchema,
  capabilities: z.array(sidecarCapabilitySchema),
});
export type SidecarHandshakeResult = z.infer<typeof sidecarHandshakeResultSchema>;

export const sidecarRecordingStartParamsSchema = z.object({
  account: sidecarAccountSchema,
  options: sidecarRecordingOptionsSchema,
});
export type SidecarRecordingStartParams = z.infer<typeof sidecarRecordingStartParamsSchema>;

export const sidecarRecordingStartResultSchema = z.object({
  sessionId: z.string(),
  state: sidecarRecordingStateSchema,
  localSessionRef: z.string().optional(),
});
export type SidecarRecordingStartResult = z.infer<typeof sidecarRecordingStartResultSchema>;

export const sidecarSessionParamsSchema = z.object({
  sessionId: z.string(),
});
export type SidecarSessionParams = z.infer<typeof sidecarSessionParamsSchema>;

export const sidecarRecordingStopResultSchema = z.object({
  sessionId: z.string(),
  state: sidecarRecordingStateSchema,
  recordingId: z.string().optional(),
  localSessionRef: z.string().optional(),
  artifacts: z.array(sidecarLocalArtifactSchema).optional(),
});
export type SidecarRecordingStopResult = z.infer<typeof sidecarRecordingStopResultSchema>;

export const sidecarRecordingStatusResultSchema = z.object({
  sessionId: z.string(),
  state: sidecarRecordingStateSchema,
  recordingId: z.string().optional(),
  localSessionRef: z.string().optional(),
});
export type SidecarRecordingStatusResult = z.infer<typeof sidecarRecordingStatusResultSchema>;

export const sidecarRequestSchema = z.discriminatedUnion("method", [
  z.object({
    jsonrpc: z.literal("2.0"),
    id: sidecarJsonRpcIdSchema,
    method: z.literal("recappi.handshake"),
    params: sidecarHandshakeParamsSchema,
  }),
  z.object({
    jsonrpc: z.literal("2.0"),
    id: sidecarJsonRpcIdSchema,
    method: z.literal("recappi.recording.start"),
    params: sidecarRecordingStartParamsSchema,
  }),
  z.object({
    jsonrpc: z.literal("2.0"),
    id: sidecarJsonRpcIdSchema,
    method: z.literal("recappi.recording.stop"),
    params: sidecarSessionParamsSchema,
  }),
  z.object({
    jsonrpc: z.literal("2.0"),
    id: sidecarJsonRpcIdSchema,
    method: z.literal("recappi.recording.cancel"),
    params: sidecarSessionParamsSchema,
  }),
  z.object({
    jsonrpc: z.literal("2.0"),
    id: sidecarJsonRpcIdSchema,
    method: z.literal("recappi.recording.status"),
    params: sidecarSessionParamsSchema,
  }),
]);
export type SidecarRequest = z.infer<typeof sidecarRequestSchema>;
export type SidecarRequestMethod = SidecarRequest["method"];

export const sidecarErrorSchema = z.object({
  code: z.number().int(),
  message: z.string(),
  data: z.unknown().optional(),
});
export type SidecarError = z.infer<typeof sidecarErrorSchema>;

export const sidecarResponseSchema = z.union([
  z.object({
    jsonrpc: z.literal("2.0"),
    id: sidecarJsonRpcIdSchema,
    result: z.unknown(),
  }),
  z.object({
    jsonrpc: z.literal("2.0"),
    id: sidecarJsonRpcIdSchema,
    error: sidecarErrorSchema,
  }),
]);
export type SidecarResponse = z.infer<typeof sidecarResponseSchema>;

export const sidecarEventSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("ready"),
    protocolVersion: z.literal(SIDECAR_PROTOCOL_VERSION),
    sidecar: sidecarInfoSchema,
  }),
  z.object({
    type: z.literal("recording.state"),
    sessionId: z.string(),
    state: sidecarRecordingStateSchema,
    recordingId: z.string().optional(),
    localSessionRef: z.string().optional(),
    message: z.string().optional(),
  }),
  z.object({
    type: z.literal("audio.level"),
    sessionId: z.string(),
    input: z.enum(["system", "microphone", "mixed"]),
    rmsDb: z.number().optional(),
    peakDb: z.number().optional(),
    at: z.number().int().optional(),
  }),
  z.object({
    type: z.literal("live_caption.delta"),
    sessionId: z.string(),
    stream: z.enum(["source", "translation"]),
    text: z.string(),
    isFinal: z.boolean().optional(),
    segmentId: z.string().optional(),
    speaker: z.string().optional(),
    language: z.string().optional(),
    atMs: z.number().int().nonnegative().optional(),
    startMs: z.number().nonnegative().optional(),
    endMs: z.number().nonnegative().optional(),
  }),
  z.object({
    type: z.literal("local_artifact.upserted"),
    sessionId: z.string().optional(),
    artifact: sidecarLocalArtifactSchema,
  }),
  z.object({
    type: z.literal("error"),
    sessionId: z.string().optional(),
    code: z.string(),
    message: z.string(),
    retryable: z.boolean().optional(),
  }),
]);
export type SidecarEvent = z.infer<typeof sidecarEventSchema>;

export const sidecarNotificationSchema = z.object({
  jsonrpc: z.literal("2.0"),
  method: z.literal("recappi.event"),
  params: sidecarEventSchema,
});
export type SidecarNotification = z.infer<typeof sidecarNotificationSchema>;

export const sidecarMessageSchema = z.union([
  sidecarRequestSchema,
  sidecarResponseSchema,
  sidecarNotificationSchema,
]);
export type SidecarMessage = z.infer<typeof sidecarMessageSchema>;

export const recordCommandDataSchema = z.object({
  origin: z.string(),
  userId: z.string(),
  live: z.boolean(),
  sessionId: z.string(),
  state: sidecarRecordingStateSchema,
  recordingId: z.string().optional(),
  localSessionRef: z.string().optional(),
  sidecar: sidecarInfoSchema.optional(),
  artifacts: z.array(sidecarLocalArtifactSchema),
});
export type RecordCommandData = z.infer<typeof recordCommandDataSchema>;

export const audioCommandDataSchema = z.object({
  origin: z.string(),
  recordingId: z.string(),
  localPath: z.string(),
  action: z.enum(["download", "open", "reveal"]),
  reused: z.boolean(),
  artifactId: z.number().int().positive().optional(),
  contentType: z.string().optional(),
  contentLength: z.number().int().nonnegative().optional(),
});
export type AudioCommandData = z.infer<typeof audioCommandDataSchema>;

export const uploadSuccessSchema = z.object({
  filePath: z.string(),
  recordingId: z.string(),
  jobId: z.string().optional(),
  transcriptId: z.string().optional(),
  status: z.string(),
  origin: z.string(),
});
export type UploadSuccess = z.infer<typeof uploadSuccessSchema>;

export const uploadFailureSchema = z.object({
  filePath: z.string(),
  error: cliErrorDescriptorSchema,
});
export type UploadFailure = z.infer<typeof uploadFailureSchema>;

export const uploadBatchDataSchema = z.object({
  successes: z.array(uploadSuccessSchema),
  failures: z.array(uploadFailureSchema),
  totalCount: z.number().int().nonnegative(),
  attemptedCount: z.number().int().nonnegative(),
});
export type UploadBatchData = z.infer<typeof uploadBatchDataSchema>;

export const jobDataSchema = z.object({
  jobId: z.string(),
  recordingId: z.string().optional(),
  transcriptId: z.string().nullable().optional(),
  status: transcriptionJobStatusSchema,
  provider: z.string().optional(),
  model: z.string().optional(),
  language: z.string().nullable().optional(),
});
export type JobData = z.infer<typeof jobDataSchema>;

export const jobStatusFilterSchema = z.enum([
  "active",
  "queued",
  "running",
  "succeeded",
  "failed",
  "all",
]);
export type JobStatusFilter = z.infer<typeof jobStatusFilterSchema>;

export const jobListItemSchema = z.object({
  jobId: z.string(),
  recordingId: z.string(),
  status: transcriptionJobStatusSchema,
  provider: z.string().optional(),
  model: z.string().optional(),
  language: z.string().nullable().optional(),
  transcriptId: z.string().nullable().optional(),
  attempts: z.number().int().nonnegative().optional(),
  enqueuedAt: z.number().int().nullable().optional(),
  startedAt: z.number().int().nullable().optional(),
  finishedAt: z.number().int().nullable().optional(),
  processedDurationMs: z.number().int().nonnegative().nullable().optional(),
  heartbeatPhase: z.string().nullable().optional(),
  recording: z.object({
    title: z.string().nullable().optional(),
    durationMs: z.number().int().nonnegative().nullable().optional(),
    createdAt: z.number().int().nullable().optional(),
  }),
});
export type JobListItem = z.infer<typeof jobListItemSchema>;

export const jobListDataSchema = z.object({
  items: z.array(jobListItemSchema),
  status: jobStatusFilterSchema,
  limit: z.number().int().positive(),
  origin: z.string(),
});
export type JobListData = z.infer<typeof jobListDataSchema>;

export const recordingDataSchema = z.object({
  recordingId: z.string(),
  title: z.string().nullable().optional(),
  summaryTitle: z.string().nullable().optional(),
  status: recordingStatusSchema,
  durationMs: z.number().int().nonnegative().nullable().optional(),
  sizeBytes: z.number().int().nonnegative().nullable().optional(),
  contentType: z.string().optional(),
  activeTranscriptId: z.string().nullable().optional(),
  createdAt: z.number().int(),
  updatedAt: z.number().int(),
  origin: z.string(),
});
export type RecordingData = z.infer<typeof recordingDataSchema>;

export const recordingListDataSchema = z.object({
  items: z.array(recordingDataSchema),
  limit: z.number().int().positive(),
  nextCursor: z.string().nullable().optional(),
  totalCount: z.number().int().nonnegative().optional(),
  origin: z.string(),
});
export type RecordingListData = z.infer<typeof recordingListDataSchema>;

export const dashboardStatsDataSchema = z.object({
  origin: z.string(),
  recordings: z.object({
    total: z.number().int().nonnegative(),
    ready: z.number().int().nonnegative(),
    uploading: z.number().int().nonnegative(),
    failed: z.number().int().nonnegative(),
    aborted: z.number().int().nonnegative(),
    totalDurationMs: z.number().int().nonnegative(),
    totalSizeBytes: z.number().int().nonnegative(),
  }),
  jobs: z.object({
    active: z.number().int().nonnegative(),
    queued: z.number().int().nonnegative(),
    running: z.number().int().nonnegative(),
    succeeded: z.number().int().nonnegative(),
    failed: z.number().int().nonnegative(),
  }),
});
export type DashboardStatsData = z.infer<typeof dashboardStatsDataSchema>;

// Transcript + summary contracts. These mirror the server's source-of-truth
// shapes (apps/server/db/schema/transcripts.ts: TranscriptSegment / SummaryPayload)
// but are the CLI's own clean, agent-facing projection — the HTTP core maps the
// raw DB row (internal claim/sandbox/heartbeat columns, JSON-string fields) into
// these before they ever reach an agent.

// Segment timestamps are normalized to milliseconds at the CLI boundary. Raw
// provider rows may use seconds or milliseconds; the public contract uses the
// `Ms` suffix so agents never have to guess the unit.
export const transcriptSegmentSchema = z.object({
  startMs: z.number().nonnegative(),
  endMs: z.number().nonnegative(),
  text: z.string(),
  speaker: z.string().optional(),
});
export type TranscriptSegment = z.infer<typeof transcriptSegmentSchema>;

export const summaryStatusSchema = z.enum([
  "pending",
  "queued",
  "running",
  "succeeded",
  "failed",
  "skipped",
]);
export type SummaryStatus = z.infer<typeof summaryStatusSchema>;

export const summaryActionItemSchema = z.object({
  who: z.string().optional(),
  what: z.string(),
});

export const summaryQuoteSchema = z.object({
  speaker: z.string().optional(),
  text: z.string(),
});

// timeline entries keep startMs/endMs (milliseconds) — this matches the server's
// SummaryPayload.timeline, which is a different unit from segment start/end. The
// suffix is the contract so an agent never has to guess seconds vs. ms.
export const summaryTimelineEntrySchema = z.object({
  startMs: z.number().nonnegative(),
  endMs: z.number().nonnegative(),
  title: z.string(),
  summary: z.string(),
});

// `status` is always present so an agent has one deterministic place to check
// readiness; the content fields only appear once status === "succeeded".
export const transcriptSummarySchema = z.object({
  status: summaryStatusSchema,
  title: z.string().optional(),
  tldr: z.string().optional(),
  keyPoints: z.array(z.string()).optional(),
  topics: z.array(z.string()).optional(),
  decisions: z.array(z.string()).optional(),
  actionItems: z.array(summaryActionItemSchema).optional(),
  quotes: z.array(summaryQuoteSchema).optional(),
  timeline: z.array(summaryTimelineEntrySchema).optional(),
  error: z.string().optional(),
});
export type TranscriptSummary = z.infer<typeof transcriptSummarySchema>;

// A transcript row only exists once its job succeeded, so presence == ready;
// there is no separate transcript-level status. The summary carries its own
// lifecycle via summary.status.
export const transcriptDataSchema = z.object({
  transcriptId: z.string(),
  recordingId: z.string(),
  jobId: z.string(),
  provider: z.string(),
  model: z.string(),
  language: z.string().nullable().optional(),
  durationMs: z.number().nonnegative().nullable().optional(),
  createdAt: z.number().int(),
  text: z.string(),
  segments: z.array(transcriptSegmentSchema),
  summary: transcriptSummarySchema,
});
export type TranscriptData = z.infer<typeof transcriptDataSchema>;

export const doctorCheckStatusSchema = z.enum(["ok", "warn", "error"]);
export type DoctorCheckStatus = z.infer<typeof doctorCheckStatusSchema>;

export const doctorCheckSchema = z.object({
  name: z.string(),
  status: doctorCheckStatusSchema,
  message: z.string(),
  hint: z.string().optional(),
});
export type DoctorCheck = z.infer<typeof doctorCheckSchema>;

export const doctorDataSchema = z.object({
  status: doctorCheckStatusSchema,
  origin: z.string(),
  authSource: z.enum(["env", "config", "macos-keychain", "none"]),
  checks: z.array(doctorCheckSchema),
});
export type DoctorData = z.infer<typeof doctorDataSchema>;

export const cliEnvelopeSchema = z.discriminatedUnion("ok", [
  z.object({
    ok: z.literal(true),
    command: z.string(),
    data: z.unknown(),
    meta: cliMetaSchema,
  }),
  z.object({
    ok: z.literal(false),
    command: z.string(),
    error: cliErrorDescriptorSchema,
    data: z.unknown().optional(),
    meta: cliMetaSchema,
  }),
]);
export type CliEnvelope = z.infer<typeof cliEnvelopeSchema>;

export const operationEventTypeSchema = z.enum(["started", "progress", "result", "error"]);
export type OperationEventType = z.infer<typeof operationEventTypeSchema>;

export const operationEventSchema = z.object({
  type: operationEventTypeSchema,
  command: z.string(),
  filePath: z.string().optional(),
  recordingId: z.string().optional(),
  jobId: z.string().optional(),
  transcriptId: z.string().optional(),
  status: z.string().optional(),
  percent: z.number().min(0).max(100).optional(),
  message: z.string().optional(),
  data: z.unknown().optional(),
  error: cliErrorDescriptorSchema.optional(),
  meta: cliMetaSchema.optional(),
});
export type OperationEvent = z.infer<typeof operationEventSchema>;
