import { promises as fs } from "node:fs";
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
import { defaultStorePath } from "./store";

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
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  now?: () => Date;
}

export async function exportRecording(opts: RecordingExportOptions): Promise<RecordingExportData> {
  const recording = await opts.client.getRecording(opts.recordingId);
  const exportDir = path.resolve(
    opts.directory ?? defaultExportDirectory(recording, opts.homeDir, opts.env),
  );
  await fs.mkdir(exportDir, { recursive: true });

  const recordingJsonPath = path.join(exportDir, "recording.json");
  const sessionMetadataPath = path.join(exportDir, "session-metadata.json");
  const remoteManifestPath = path.join(exportDir, "remote-session.json");
  await writeJson(recordingJsonPath, recording);

  const subscription = await opts.client.accountStatus();
  const subscriptionPath = path.join(exportDir, "subscription.md");
  const subscriptionJsonPath = path.join(exportDir, "subscription.json");
  await fs.writeFile(subscriptionPath, renderSubscriptionMarkdown(subscription), "utf8");
  await writeJson(subscriptionJsonPath, subscription);

  const audio = await opts.recordingAudio.downloadRecordingAudioFile(recording.recordingId, {
    directory: exportDir,
    filenameStem: "recording",
    title: recording.title ?? recording.summaryTitle ?? recording.recordingId,
  });

  let transcriptId: string | null | undefined = recording.activeTranscriptId ?? undefined;
  let transcriptPath: string | undefined;
  let transcriptJsonPath: string | undefined;
  let summaryPath: string | undefined;
  let summaryJsonPath: string | undefined;
  let actionItemsPath: string | undefined;
  let summaryStatus: RecordingExportData["summaryStatus"] | undefined;
  let transcript: TranscriptData | undefined;

  if (recording.activeTranscriptId) {
    transcript = await opts.client.getTranscript(recording.activeTranscriptId);
    transcriptId = transcript.transcriptId;
    transcriptPath = path.join(exportDir, "transcript.md");
    transcriptJsonPath = path.join(exportDir, "transcript.json");
    summaryPath = path.join(exportDir, "summary.md");
    summaryJsonPath = path.join(exportDir, "summary.json");
    actionItemsPath = path.join(exportDir, "action-items.md");
    summaryStatus = transcript.summary.status;
    await fs.writeFile(transcriptPath, renderTranscriptMarkdown(transcript), "utf8");
    await writeJson(transcriptJsonPath, transcript);
    await writeJson(summaryJsonPath, transcript.summary);
    await fs.writeFile(summaryPath, renderSummaryMarkdown(recording, transcript), "utf8");
    await writeOptionalText(actionItemsPath, renderActionItemsMarkdown(transcript.summary));
  }

  await writeJson(sessionMetadataPath, renderSessionMetadata(recording));
  await writeJson(
    remoteManifestPath,
    renderRemoteSessionManifest(recording, audio, transcript, subscription, opts.now),
  );

  const textPath = path.join(exportDir, "handoff.md");
  const manifestPath = path.join(exportDir, "manifest.json");
  const data = recordingExportDataSchema.parse({
    origin: recording.origin,
    recordingId: recording.recordingId,
    exportDir,
    textPath,
    manifestPath,
    remoteManifestPath,
    sessionMetadataPath,
    recordingJsonPath,
    subscriptionPath,
    subscriptionJsonPath,
    audioPath: audio.localPath,
    ...(transcriptId !== undefined ? { transcriptId } : {}),
    ...(transcriptPath ? { transcriptPath } : {}),
    ...(transcriptJsonPath ? { transcriptJsonPath } : {}),
    ...(summaryPath ? { summaryPath } : {}),
    ...(summaryJsonPath ? { summaryJsonPath } : {}),
    ...(actionItemsPath ? { actionItemsPath } : {}),
    ...(summaryStatus ? { summaryStatus } : {}),
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
  return data;
}

function defaultExportDirectory(
  recording: RecordingData,
  homeDir?: string,
  env?: NodeJS.ProcessEnv,
): string {
  const base = path.join(path.dirname(defaultStorePath(homeDir, env)), "exports");
  const label = recording.title ?? recording.summaryTitle ?? "recording";
  return path.join(base, `${truncateFileStem(safeFileStem(label), 80)}-${recording.recordingId}`);
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
    lines.push(renderSummaryMarkdown(recording, transcript).trimEnd());
    lines.push("");
    lines.push(renderTranscriptMarkdown(transcript).trimEnd());
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
  audio: RecordingAudioRuntimeDownload,
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
    uploadFilename: path.basename(audio.localPath),
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

function renderSummaryMarkdown(recording: RecordingData, transcript: TranscriptData): string {
  const summary = transcript.summary;
  const lines: string[] = [];
  lines.push(`# ${summary.title ?? recording.title ?? recording.summaryTitle ?? "Summary"}`);
  lines.push("");
  lines.push(`- recordingId: ${recording.recordingId}`);
  lines.push(`- transcriptId: ${transcript.transcriptId}`);
  lines.push(`- summaryStatus: ${summary.status}`);
  if (summary.error) lines.push(`- error: ${summary.error}`);
  lines.push("");

  if (summary.tldr) {
    lines.push("## TL;DR", "");
    lines.push(summary.tldr, "");
  }
  appendStringList(lines, "Key Points", summary.keyPoints);
  appendStringList(lines, "Topics", summary.topics);
  appendStringList(lines, "Decisions", summary.decisions);
  appendActionItems(lines, summary.actionItems);
  appendTimeline(lines, summary.timeline);
  appendQuotes(lines, summary.quotes);

  if (lines[lines.length - 1] !== "") lines.push("");
  return lines.join("\n");
}

function renderActionItemsMarkdown(summary: TranscriptSummary): string | null {
  if (!summary.actionItems || summary.actionItems.length === 0) return null;
  const lines = ["# Action Items", ""];
  for (const item of summary.actionItems) {
    lines.push(`- ${item.who ? `${item.who} - ` : ""}${item.what}`);
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
    lines.push(`- ${item.who ? `${item.who}: ` : ""}${item.what}`);
  }
  lines.push("");
}

function appendTimeline(
  lines: string[],
  values?: NonNullable<TranscriptSummary["timeline"]>,
): void {
  if (!values || values.length === 0) return;
  lines.push("## Timeline", "");
  for (const item of values) {
    lines.push(
      `- ${formatTimestamp(item.startMs)}-${formatTimestamp(item.endMs)}: ${item.title} - ${item.summary}`,
    );
  }
  lines.push("");
}

function appendQuotes(lines: string[], values?: NonNullable<TranscriptSummary["quotes"]>): void {
  if (!values || values.length === 0) return;
  lines.push("## Quotes", "");
  for (const item of values) {
    lines.push(`- ${item.speaker ? `${item.speaker}: ` : ""}"${item.text}"`);
  }
  lines.push("");
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
