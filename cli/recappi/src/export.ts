import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import type {
  AccountStatusData,
  RecordingData,
  RecordingExportData,
  TranscriptData,
  TranscriptSummary,
} from "../../packages/contracts/src/index";
import { recordingExportDataSchema } from "../../packages/contracts/src/index";
import type { RecordingAudioRuntime, RecordingAudioRuntimeDownload } from "./audio";
import {
  accountFromStatus,
  findIndexedRecordingSessionDir,
  rememberRecordingSession,
} from "./recordingSessionCache";
import type { CliLocalStore } from "./store";

export interface RecordingExportClient {
  getRecording(recordingId: string): Promise<RecordingData>;
  getTranscript(transcriptId: string): Promise<TranscriptData>;
  accountStatus(): Promise<AccountStatusData>;
}

export interface RecordingExportOptions {
  recordingId: string;
  directory?: string;
  client: RecordingExportClient;
  recordingAudio: Pick<RecordingAudioRuntime, "downloadRecordingAudioFile">;
  store?: CliLocalStore;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  now?: () => Date;
}

export interface RecordingTextSyncOptions {
  recordingId: string;
  directory?: string;
  client: RecordingExportClient;
  store?: CliLocalStore;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  now?: () => Date;
}

export interface RecordingTextSyncData {
  recordingId: string;
  sessionDir: string;
  remoteManifestPath: string;
  sessionMetadataPath: string;
  recordingJsonPath: string;
  transcriptId?: string | null;
  transcriptPath?: string;
  transcriptJsonPath?: string;
  summaryPath?: string;
  summaryJsonPath?: string;
  actionItemsPath?: string;
  summaryStatus?: RecordingExportData["summaryStatus"];
}

export interface RecordingAudioSyncOptions extends RecordingTextSyncOptions {
  recordingAudio: Pick<RecordingAudioRuntime, "downloadRecordingAudioFile">;
}

export interface RecordingAudioSyncData extends RecordingTextSyncData {
  audioPath: string;
  audio: RecordingExportData["audio"];
}

interface RecordingBundleContext {
  recording: RecordingData;
  subscription: AccountStatusData;
  transcript?: TranscriptData;
  transcriptId?: string | null;
}

export async function syncRecordingText(
  opts: RecordingTextSyncOptions,
): Promise<RecordingTextSyncData> {
  const context = await loadRecordingBundleContext(opts);
  const account = accountFromStatus(context.subscription);
  const sessionDir = await resolveRecordingSessionDir(context.recording, opts, account);
  return writeRecordingTextFiles(context, sessionDir, {
    now: opts.now,
    store: opts.store,
    env: opts.env,
    homeDir: opts.homeDir,
    account,
    source: "text_sync",
  });
}

export async function syncRecordingAudio(
  opts: RecordingAudioSyncOptions,
): Promise<RecordingAudioSyncData> {
  const context = await loadRecordingBundleContext(opts);
  const account = accountFromStatus(context.subscription);
  const sessionDir = await resolveRecordingSessionDir(context.recording, opts, account);
  const audio = await downloadRecordingAudioToDir(context.recording, opts.recordingAudio, sessionDir);
  const text = await writeRecordingTextFiles(context, sessionDir, {
    now: opts.now,
    uploadFilename: path.basename(audio.localPath),
    store: opts.store,
    env: opts.env,
    homeDir: opts.homeDir,
    account,
    source: "audio_sync",
    audioPath: audio.localPath,
  });
  return { ...text, audioPath: audio.localPath, audio: audioMetadata(audio) };
}

export async function exportRecording(opts: RecordingExportOptions): Promise<RecordingExportData> {
  const context = await loadRecordingBundleContext(opts);
  const account = accountFromStatus(context.subscription);
  const exportDir = await resolveRecordingSessionDir(context.recording, opts, account);

  const audio = await downloadRecordingAudioToDir(context.recording, opts.recordingAudio, exportDir);
  const textFiles = await writeRecordingTextFiles(context, exportDir, {
    now: opts.now,
    uploadFilename: path.basename(audio.localPath),
    store: opts.store,
    env: opts.env,
    homeDir: opts.homeDir,
    account,
    source: "export",
    audioPath: audio.localPath,
  });

  const { recording, subscription, transcript } = context;
  const subscriptionPath = path.join(exportDir, "subscription.md");
  const subscriptionJsonPath = path.join(exportDir, "subscription.json");
  await fs.writeFile(subscriptionPath, renderSubscriptionMarkdown(subscription), "utf8");
  await writeJson(subscriptionJsonPath, subscription);

  const textPath = path.join(exportDir, "handoff.md");
  const manifestPath = path.join(exportDir, "manifest.json");
  const data = recordingExportDataSchema.parse({
    origin: recording.origin,
    recordingId: recording.recordingId,
    exportDir,
    textPath,
    manifestPath,
    remoteManifestPath: textFiles.remoteManifestPath,
    sessionMetadataPath: textFiles.sessionMetadataPath,
    recordingJsonPath: textFiles.recordingJsonPath,
    subscriptionPath,
    subscriptionJsonPath,
    audioPath: audio.localPath,
    ...(textFiles.transcriptId !== undefined ? { transcriptId: textFiles.transcriptId } : {}),
    ...(textFiles.transcriptPath ? { transcriptPath: textFiles.transcriptPath } : {}),
    ...(textFiles.transcriptJsonPath ? { transcriptJsonPath: textFiles.transcriptJsonPath } : {}),
    ...(textFiles.summaryPath ? { summaryPath: textFiles.summaryPath } : {}),
    ...(textFiles.summaryJsonPath ? { summaryJsonPath: textFiles.summaryJsonPath } : {}),
    ...(textFiles.actionItemsPath ? { actionItemsPath: textFiles.actionItemsPath } : {}),
    ...(textFiles.summaryStatus ? { summaryStatus: textFiles.summaryStatus } : {}),
    audio: audioMetadata(audio),
  });
  await fs.writeFile(
    textPath,
    renderHandoffMarkdown(recording, subscription, audio, data, transcript),
    "utf8",
  );
  await writeJson(manifestPath, {
    exportedAt: (opts.now ?? (() => new Date()))().toISOString(),
    command: "recordings export",
    data,
  });
  await rememberRecordingSession(
    {
      recording,
      sessionDir: exportDir,
      files: {
        remoteManifestPath: data.remoteManifestPath,
        sessionMetadataPath: data.sessionMetadataPath,
        recordingJsonPath: data.recordingJsonPath,
        ...(data.transcriptPath ? { transcriptPath: data.transcriptPath } : {}),
        ...(data.transcriptJsonPath ? { transcriptJsonPath: data.transcriptJsonPath } : {}),
        ...(data.summaryPath ? { summaryPath: data.summaryPath } : {}),
        ...(data.summaryJsonPath ? { summaryJsonPath: data.summaryJsonPath } : {}),
        ...(data.actionItemsPath ? { actionItemsPath: data.actionItemsPath } : {}),
        audioPath: data.audioPath,
        subscriptionPath: data.subscriptionPath,
        subscriptionJsonPath: data.subscriptionJsonPath,
        textPath: data.textPath,
        manifestPath: data.manifestPath,
      },
      ...(data.transcriptId !== undefined ? { transcriptId: data.transcriptId } : {}),
      ...(data.summaryStatus ? { summaryStatus: data.summaryStatus } : {}),
      uploadFilename: path.basename(audio.localPath),
      source: "export",
      now: opts.now,
    },
    { account, store: opts.store, env: opts.env, homeDir: opts.homeDir },
  );
  return data;
}

async function loadRecordingBundleContext(
  opts: Pick<RecordingTextSyncOptions, "recordingId" | "client">,
): Promise<RecordingBundleContext> {
  const recording = await opts.client.getRecording(opts.recordingId);
  const subscription = await opts.client.accountStatus();
  const transcript = recording.activeTranscriptId
    ? await opts.client.getTranscript(recording.activeTranscriptId)
    : undefined;
  return {
    recording,
    subscription,
    ...(transcript ? { transcript } : {}),
    transcriptId: transcript?.transcriptId ?? recording.activeTranscriptId ?? undefined,
  };
}

async function downloadRecordingAudioToDir(
  recording: RecordingData,
  recordingAudio: Pick<RecordingAudioRuntime, "downloadRecordingAudioFile">,
  directory: string,
): Promise<RecordingAudioRuntimeDownload> {
  return recordingAudio.downloadRecordingAudioFile(recording.recordingId, {
    directory,
    filenameStem: "recording",
    title: recording.title ?? recording.summaryTitle ?? recording.recordingId,
  });
}

async function writeRecordingTextFiles(
  context: RecordingBundleContext,
  sessionDir: string,
  opts: {
    uploadFilename?: string;
    now?: () => Date;
    store?: CliLocalStore;
    env?: NodeJS.ProcessEnv;
    homeDir?: string;
    account?: ReturnType<typeof accountFromStatus>;
    source: "text_sync" | "audio_sync" | "export";
    audioPath?: string;
  },
): Promise<RecordingTextSyncData> {
  const { recording, transcript, subscription } = context;
  await fs.mkdir(sessionDir, { recursive: true });
  const recordingJsonPath = path.join(sessionDir, "recording.json");
  const sessionMetadataPath = path.join(sessionDir, "session-metadata.json");
  const remoteManifestPath = path.join(sessionDir, "remote-session.json");
  const existingManifest = await readJsonRecord(remoteManifestPath);
  const uploadFilename =
    opts.uploadFilename ??
    (typeof existingManifest?.uploadFilename === "string"
      ? existingManifest.uploadFilename
      : undefined);
  await writeJson(recordingJsonPath, recording);
  await writeJson(sessionMetadataPath, renderSessionMetadata(recording));
  await writeJson(
    remoteManifestPath,
    renderRemoteSessionManifest(recording, uploadFilename, transcript, subscription, opts.now),
  );

  let transcriptPath: string | undefined;
  let transcriptJsonPath: string | undefined;
  let summaryPath: string | undefined;
  let summaryJsonPath: string | undefined;
  let actionItemsPath: string | undefined;
  let summaryStatus: RecordingExportData["summaryStatus"] | undefined;

  if (transcript) {
    transcriptPath = path.join(sessionDir, "transcript.md");
    transcriptJsonPath = path.join(sessionDir, "transcript.json");
    summaryJsonPath = path.join(sessionDir, "summary.json");
    summaryStatus = transcript.summary.status;
    await fs.writeFile(transcriptPath, renderTranscriptMarkdown(transcript), "utf8");
    await writeJson(transcriptJsonPath, transcript);
    await writeJson(summaryJsonPath, transcript.summary);
    const summaryFilePath = path.join(sessionDir, "summary.md");
    const summaryMarkdown = renderSummaryMarkdown(transcript);
    await writeOptionalText(summaryFilePath, summaryMarkdown);
    if (summaryMarkdown) summaryPath = summaryFilePath;
    const actionItemsFilePath = path.join(sessionDir, "action-items.md");
    const actionItemsMarkdown = renderActionItemsMarkdown(transcript.summary);
    await writeOptionalText(actionItemsFilePath, actionItemsMarkdown);
    if (actionItemsMarkdown) actionItemsPath = actionItemsFilePath;
  }

  const data = {
    recordingId: recording.recordingId,
    sessionDir,
    remoteManifestPath,
    sessionMetadataPath,
    recordingJsonPath,
    ...(context.transcriptId !== undefined ? { transcriptId: context.transcriptId } : {}),
    ...(transcriptPath ? { transcriptPath } : {}),
    ...(transcriptJsonPath ? { transcriptJsonPath } : {}),
    ...(summaryPath ? { summaryPath } : {}),
    ...(summaryJsonPath ? { summaryJsonPath } : {}),
    ...(actionItemsPath ? { actionItemsPath } : {}),
    ...(summaryStatus ? { summaryStatus } : {}),
  };
  await rememberRecordingSession(
    {
      recording,
      sessionDir,
      files: {
        remoteManifestPath,
        sessionMetadataPath,
        recordingJsonPath,
        ...(transcriptPath ? { transcriptPath } : {}),
        ...(transcriptJsonPath ? { transcriptJsonPath } : {}),
        ...(summaryPath ? { summaryPath } : {}),
        ...(summaryJsonPath ? { summaryJsonPath } : {}),
        ...(actionItemsPath ? { actionItemsPath } : {}),
        ...(opts.audioPath ? { audioPath: opts.audioPath } : {}),
      },
      ...(context.transcriptId !== undefined ? { transcriptId: context.transcriptId } : {}),
      ...(summaryStatus ? { summaryStatus } : {}),
      ...(uploadFilename ? { uploadFilename } : {}),
      source: opts.source,
      now: opts.now,
    },
    { account: opts.account ?? null, store: opts.store, env: opts.env, homeDir: opts.homeDir },
  );
  return data;
}

async function resolveRecordingSessionDir(
  recording: RecordingData,
  opts: Pick<RecordingTextSyncOptions, "directory" | "homeDir" | "env" | "store">,
  account: ReturnType<typeof accountFromStatus>,
): Promise<string> {
  if (opts.directory) return path.resolve(opts.directory);
  const indexed = await findIndexedRecordingSessionDir(recording.recordingId, {
    account,
    store: opts.store,
    homeDir: opts.homeDir,
    env: opts.env,
  });
  if (indexed) return indexed;
  const existing = await findExistingRecordingSessionDir(recording.recordingId, opts.homeDir, opts.env);
  if (existing) {
    await rememberRecordingSession(
      {
        recording,
        sessionDir: existing,
        files: {
          remoteManifestPath: path.join(existing, "remote-session.json"),
          sessionMetadataPath: path.join(existing, "session-metadata.json"),
          recordingJsonPath: path.join(existing, "recording.json"),
        },
        source: "manifest_scan",
      },
      { account, store: opts.store, env: opts.env, homeDir: opts.homeDir },
    );
  }
  if (existing) return existing;
  return createRecordingSessionDir(recording, opts.homeDir, opts.env);
}

async function findExistingRecordingSessionDir(
  recordingId: string,
  homeDir?: string,
  env?: NodeJS.ProcessEnv,
): Promise<string | undefined> {
  const base = recordingSessionBaseDirectory(homeDir, env);
  let entries: import("node:fs").Dirent[];
  try {
    entries = await fs.readdir(base, { withFileTypes: true });
  } catch {
    return undefined;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const dir = path.join(base, entry.name);
    const manifest = await readJsonRecord(path.join(dir, "remote-session.json"));
    if (manifest?.recordingId === recordingId) return dir;
  }
  return undefined;
}

async function createRecordingSessionDir(
  recording: RecordingData,
  homeDir?: string,
  env?: NodeJS.ProcessEnv,
): Promise<string> {
  const base = recordingSessionBaseDirectory(homeDir, env);
  await fs.mkdir(base, { recursive: true });
  const stem = formatSessionDirectoryDate(new Date(recording.createdAt));
  let candidate = path.join(base, stem);
  let suffix = 2;
  while (await pathExists(candidate)) {
    candidate = path.join(base, `${stem}-cloud-${suffix}`);
    suffix += 1;
  }
  await fs.mkdir(candidate, { recursive: true });
  return candidate;
}

function recordingSessionBaseDirectory(
  homeDir = os.homedir(),
  env: NodeJS.ProcessEnv = process.env,
): string {
  const explicit = env.RECAPPI_LOCAL_SESSIONS_DIR?.trim();
  if (explicit) return explicit;
  return path.join(homeDir, "Documents", "Recappi Mini");
}

async function readJsonRecord(filePath: string): Promise<Record<string, unknown> | undefined> {
  try {
    const parsed = JSON.parse(await fs.readFile(filePath, "utf8"));
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
      ? parsed
      : undefined;
  } catch {
    return undefined;
  }
}

async function pathExists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function formatSessionDirectoryDate(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const hour = String(date.getHours()).padStart(2, "0");
  const minute = String(date.getMinutes()).padStart(2, "0");
  const second = String(date.getSeconds()).padStart(2, "0");
  return `${year}-${month}-${day}_${hour}${minute}${second}`;
}

async function writeJson(filePath: string, value: unknown): Promise<void> {
  await fs.writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function writeOptionalText(filePath: string, value: string | null): Promise<void> {
  if (value && value.trim()) {
    await fs.writeFile(filePath, value, "utf8");
    return;
  }
  await fs.rm(filePath, { force: true });
}

function renderHandoffMarkdown(
  recording: RecordingData,
  subscription: AccountStatusData,
  audio: RecordingAudioRuntimeDownload,
  data: RecordingExportData,
  transcript: TranscriptData | undefined,
): string {
  const lines: string[] = [];
  lines.push(`# ${recording.title ?? recording.summaryTitle ?? "Recappi Recording"}`);
  lines.push("");
  lines.push("## Files", "");
  lines.push(`- Audio: ${audio.localPath}`);
  lines.push(`- Subscription: ${data.subscriptionPath}`);
  if (data.summaryPath) lines.push(`- Summary: ${data.summaryPath}`);
  if (data.transcriptPath) lines.push(`- Transcript: ${data.transcriptPath}`);
  if (data.actionItemsPath) lines.push(`- Action items: ${data.actionItemsPath}`);
  lines.push(`- Remote session manifest: ${data.remoteManifestPath}`);
  lines.push(`- Session metadata: ${data.sessionMetadataPath}`);
  lines.push(`- Manifest: ${data.manifestPath}`);
  lines.push("");

  lines.push("## Recording", "");
  lines.push(`- recordingId: ${recording.recordingId}`);
  lines.push(`- status: ${recording.status}`);
  if (recording.durationMs !== undefined && recording.durationMs !== null) {
    lines.push(`- duration: ${formatTimestamp(recording.durationMs)}`);
  }
  if (recording.sizeBytes !== undefined && recording.sizeBytes !== null) {
    lines.push(`- sizeBytes: ${recording.sizeBytes}`);
  }
  if (transcript) {
    lines.push(`- transcriptId: ${transcript.transcriptId}`);
    lines.push(`- summaryStatus: ${transcript.summary.status}`);
  } else {
    lines.push("- transcript: not available");
  }
  lines.push("");

  lines.push("## Subscription", "");
  appendSubscriptionLines(lines, subscription);
  lines.push("");

  if (transcript) {
    const summaryMarkdown = renderSummaryMarkdown(transcript);
    if (summaryMarkdown) {
      lines.push(summaryMarkdown.trimEnd());
      lines.push("");
    }
    lines.push(renderTimestampedTranscriptMarkdown(transcript).trimEnd());
    lines.push("");
  }

  return `${lines.join("\n").trimEnd()}\n`;
}

function renderSubscriptionMarkdown(subscription: AccountStatusData): string {
  const lines = ["# Subscription", ""];
  appendSubscriptionLines(lines, subscription);
  return `${lines.join("\n").trimEnd()}\n`;
}

function renderSessionMetadata(recording: RecordingData): Record<string, unknown> {
  const sourceTitle = recording.title ?? recording.summaryTitle ?? "Recappi Cloud";
  return stripUndefined({
    summaryTitle: recording.summaryTitle ?? recording.title ?? undefined,
    sourceTitle,
    sourceAppName: undefined,
    sourceBundleID: undefined,
    startedAt: new Date(recording.createdAt).toISOString(),
    sceneTemplate: undefined,
    extraPrompt: undefined,
    includesMicrophoneAudio: undefined,
  });
}

function renderRemoteSessionManifest(
  recording: RecordingData,
  uploadFilename: string | undefined,
  transcript: TranscriptData | undefined,
  subscription: AccountStatusData,
  now?: () => Date,
): Record<string, unknown> {
  return stripUndefined({
    recordingId: recording.recordingId,
    jobId: transcript?.jobId,
    transcriptId: transcript?.transcriptId ?? recording.activeTranscriptId ?? undefined,
    stage: transcript ? "done" : "synced",
    errorMessage: undefined,
    uploadFilename,
    provider: transcript?.provider,
    model: transcript?.model,
    updatedAt: (now ?? (() => new Date()))().toISOString(),
    accountUserId: subscription.userId,
    accountBackendOrigin: subscription.origin,
  });
}

function stripUndefined(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined));
}

function appendSubscriptionLines(lines: string[], subscription: AccountStatusData): void {
  lines.push(`- origin: ${subscription.origin}`);
  lines.push(`- loggedIn: ${subscription.loggedIn}`);
  if (subscription.email) lines.push(`- email: ${subscription.email}`);
  if (subscription.userId) lines.push(`- userId: ${subscription.userId}`);
  if (subscription.billing) {
    lines.push(`- plan: ${subscription.billing.tier}`);
    lines.push(`- minutesUsed: ${subscription.billing.minutesUsed}`);
    lines.push(`- minutesCap: ${subscription.billing.minutesCap ?? "unlimited"}`);
    lines.push(`- batchMinutesUsed: ${subscription.billing.batchMinutesUsed}`);
    lines.push(`- realtimeMinutesUsed: ${subscription.billing.realtimeMinutesUsed}`);
    lines.push(`- storageBytes: ${subscription.billing.storageBytes}`);
    lines.push(`- storageCapBytes: ${subscription.billing.storageCapBytes ?? "unlimited"}`);
    lines.push(`- periodStart: ${subscription.billing.periodStart}`);
    lines.push(`- periodEnd: ${subscription.billing.periodEnd}`);
  }
}

function renderTranscriptMarkdown(transcript: TranscriptData): string {
  return `# Transcript\n\n${transcript.text}\n`;
}

function renderTimestampedTranscriptMarkdown(transcript: TranscriptData): string {
  return `# Transcript\n\n${renderTranscriptLines(transcript)}\n`;
}

function renderTranscriptLines(transcript: TranscriptData): string {
  const lines = transcript.segments.map((segment) => {
    const speaker = segment.speaker ? `${segment.speaker}: ` : "";
    return `[${formatTimestamp(segment.startMs)}] ${speaker}${segment.text}`;
  });
  if (lines.length > 0) return lines.join("\n");
  return transcript.text;
}

function renderSummaryMarkdown(transcript: TranscriptData): string | null {
  const summary = transcript.summary;
  const lines: string[] = [];
  lines.push("# Summary");
  lines.push("");

  if (summary.tldr) {
    lines.push("## TL;DR", "");
    lines.push(summary.tldr, "");
  }
  appendStringList(lines, "Key Points", summary.keyPoints);
  appendStringList(lines, "Topics", summary.topics);
  appendStringList(lines, "Decisions", summary.decisions);
  appendActionItems(lines, summary.actionItems);
  appendNotableQuotes(lines, summary.quotes);

  if (lines.length === 2) return null;
  if (lines[lines.length - 1] !== "") lines.push("");
  return lines.join("\n");
}

function renderActionItemsMarkdown(summary: TranscriptSummary): string | null {
  if (!summary.actionItems || summary.actionItems.length === 0) return null;
  const lines = ["# Action Items", ""];
  for (const item of summary.actionItems) {
    lines.push(actionItemLine(item));
  }
  lines.push("");
  return lines.join("\n");
}

function appendStringList(lines: string[], title: string, values?: string[]): void {
  if (!values || values.length === 0) return;
  lines.push(`## ${title}`, "");
  for (const value of values) lines.push(`- ${value}`);
  lines.push("");
}

function appendActionItems(
  lines: string[],
  values?: NonNullable<TranscriptSummary["actionItems"]>,
): void {
  if (!values || values.length === 0) return;
  lines.push("## Action Items", "");
  for (const item of values) {
    lines.push(actionItemLine(item));
  }
  lines.push("");
}

function appendNotableQuotes(lines: string[], values?: NonNullable<TranscriptSummary["quotes"]>): void {
  if (!values || values.length === 0) return;
  lines.push("## Notable Quotes", "");
  for (const item of values) {
    lines.push(`> ${item.speaker ? `${item.speaker}: ` : ""}${item.text}`);
  }
  lines.push("");
}

function actionItemLine(item: NonNullable<TranscriptSummary["actionItems"]>[number]): string {
  return `- ${item.who ? `${item.who}: ` : ""}${item.what}`;
}

function audioMetadata(audio: RecordingAudioRuntimeDownload): RecordingExportData["audio"] {
  return {
    ...(audio.contentType ? { contentType: audio.contentType } : {}),
    ...(audio.contentLength !== undefined ? { contentLength: audio.contentLength } : {}),
    reused: audio.reused,
  };
}

function formatTimestamp(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const mm = String(minutes).padStart(2, "0");
  const ss = String(seconds).padStart(2, "0");
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
}
