import { promises as fs } from "node:fs";
import path from "node:path";
import type {
  AccountStatusData,
  RecordingData,
  RecordingListData,
} from "../../packages/contracts/src/index";
import { recordingDataSchema, recordingListDataSchema } from "../../packages/contracts/src/index";
import {
  normalizeAccountStamp,
  openCliStore,
  type AccountPartition,
  type CliLocalStore,
  type LocalArtifact,
} from "./store";

export interface RecordingSessionCacheDeps {
  account?: AccountPartition | null;
  store?: CliLocalStore;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
}

export interface RecordingSessionFiles {
  remoteManifestPath: string;
  sessionMetadataPath: string;
  recordingJsonPath: string;
  transcriptPath?: string;
  transcriptJsonPath?: string;
  summaryPath?: string;
  summaryJsonPath?: string;
  actionItemsPath?: string;
  audioPath?: string;
  subscriptionPath?: string;
  subscriptionJsonPath?: string;
  textPath?: string;
  manifestPath?: string;
}

export interface RememberRecordingSessionInput {
  recording: RecordingData;
  sessionDir: string;
  files: RecordingSessionFiles;
  transcriptId?: string | null;
  summaryStatus?: string;
  uploadFilename?: string;
  source: "text_sync" | "audio_sync" | "export" | "manifest_scan";
  now?: () => Date;
}

export function accountFromStatus(status: AccountStatusData): AccountPartition | null {
  if (!status.loggedIn || !status.userId) return null;
  return normalizeAccountStamp({ backendOrigin: status.origin, userId: status.userId });
}

export async function findIndexedRecordingSessionDir(
  recordingId: string,
  deps: RecordingSessionCacheDeps,
): Promise<string | undefined> {
  return withSessionStore(deps, async (store, account) => {
    if (!account) return undefined;
    const artifact = store.findLocalArtifactForAccount(account, {
      kind: "recording_session",
      remoteId: recordingId,
    });
    if (!artifact) return undefined;
    if (!(await isReadableDirectory(artifact.localPath))) return undefined;
    const manifest = await readJsonRecord(path.join(artifact.localPath, "remote-session.json"));
    if (manifest?.recordingId && manifest.recordingId !== recordingId) return undefined;
    return artifact.localPath;
  });
}

export async function rememberRecordingSession(
  input: RememberRecordingSessionInput,
  deps: RecordingSessionCacheDeps,
): Promise<LocalArtifact | null> {
  return withSessionStore(deps, (store, account) => {
    if (!account) return null;
    return store.upsertLocalArtifact({
      kind: "recording_session",
      account,
      remoteId: input.recording.recordingId,
      localPath: input.sessionDir,
      metadata: stripUndefined({
        resource: "recording_session",
        source: input.source,
        sessionDir: input.sessionDir,
        recording: input.recording,
        files: stripUndefined({ ...input.files }),
        transcriptId: input.transcriptId,
        summaryStatus: input.summaryStatus,
        uploadFilename: input.uploadFilename,
        origin: input.recording.origin,
        indexedAt: (input.now ?? (() => new Date()))().toISOString(),
      }),
    });
  });
}

export async function listCachedRecordingSessions(
  deps: RecordingSessionCacheDeps & { origin: string; limit?: number },
): Promise<RecordingListData> {
  const limit = deps.limit ?? 50;
  const items = await withSessionStore(deps, async (store, account) => {
    if (!account) return [];
    const artifacts = store.listLocalArtifactsForAccount(account, { kind: "recording_session" });
    const recordings: RecordingData[] = [];
    const seen = new Set<string>();
    for (const artifact of artifacts) {
      if (recordings.length >= limit) break;
      const recording = await recordingFromArtifact(artifact);
      if (!recording || seen.has(recording.recordingId)) continue;
      if (!(await isReadableDirectory(artifact.localPath))) continue;
      seen.add(recording.recordingId);
      recordings.push(recording);
    }
    return recordings.sort((a, b) => b.createdAt - a.createdAt || b.updatedAt - a.updatedAt);
  });
  return recordingListDataSchema.parse({
    items,
    limit,
    nextCursor: null,
    totalCount: items.length,
    origin: deps.origin,
  });
}

async function recordingFromArtifact(artifact: LocalArtifact): Promise<RecordingData | null> {
  const metadata = isRecord(artifact.metadata) ? artifact.metadata : {};
  const cached = recordingDataSchema.safeParse(metadata.recording);
  if (cached.success) return cached.data;
  const fromFile = await readJsonRecord(path.join(artifact.localPath, "recording.json"));
  const parsed = recordingDataSchema.safeParse(fromFile);
  return parsed.success ? parsed.data : null;
}

async function withSessionStore<T>(
  deps: RecordingSessionCacheDeps,
  run: (store: CliLocalStore, account: AccountPartition | null) => T | Promise<T>,
): Promise<T> {
  const store = deps.store ?? openCliStore({ homeDir: deps.homeDir, env: deps.env });
  try {
    return await run(store, deps.account ?? null);
  } finally {
    if (!deps.store) store.close();
  }
}

async function readJsonRecord(filePath: string): Promise<Record<string, unknown> | undefined> {
  try {
    const parsed = JSON.parse(await fs.readFile(filePath, "utf8"));
    return isRecord(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

async function isReadableDirectory(localPath: string): Promise<boolean> {
  try {
    return (await fs.stat(localPath)).isDirectory();
  } catch {
    return false;
  }
}

function stripUndefined(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
