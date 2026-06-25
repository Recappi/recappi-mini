import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import type {
  DownloadRecordingAudioOptions,
  RecappiApiClient,
  RecordingAudioDownload,
} from "./api";
import { cliError } from "./errors";
import {
  defaultStorePath,
  openCliStore,
  type AccountPartition,
  type CliLocalStore,
  type LocalArtifact,
} from "./store";

export interface RecordingAudioRuntimeDownload {
  recordingId: string;
  localPath: string;
  reused: boolean;
  artifactId?: number;
  contentType?: string;
  contentLength?: number;
  origin?: string;
}

export interface RecordingAudioRuntime {
  downloadRecordingAudio(
    recordingId: string,
    opts?: DownloadRecordingAudioOptions,
  ): Promise<string>;
  downloadRecordingAudioFile(
    recordingId: string,
    opts?: DownloadRecordingAudioOptions,
  ): Promise<RecordingAudioRuntimeDownload>;
  openPath(localPath: string): Promise<void>;
  revealInFinder(localPath: string): Promise<void>;
  listDownloads(): Promise<LocalArtifact[]>;
  listDownloadedRecordingIds(): Promise<Set<string>>;
}

interface RecordingAudioRuntimeOptions {
  spawnProcess?: typeof spawn;
  platform?: NodeJS.Platform;
  account?: AccountPartition | null;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  store?: CliLocalStore;
}

export function createRecordingAudioRuntime(
  client: RecappiApiClient,
  deps: RecordingAudioRuntimeOptions = {},
): RecordingAudioRuntime {
  const downloadRecordingAudioFile = async (
    recordingId: string,
    opts?: DownloadRecordingAudioOptions,
  ): Promise<RecordingAudioRuntimeDownload> => {
    const cached = await findReusableDownload(recordingId, deps);
    if (cached) return cached;

    const directory =
      opts?.directory ?? (deps.account ? defaultDownloadDirectory(deps) : undefined);
    const download = await client.downloadRecordingAudio(recordingId, {
      ...opts,
      ...(directory ? { directory } : {}),
    });
    const artifact = await rememberDownload(download, deps);
    return {
      recordingId: download.recordingId,
      localPath: download.localPath,
      reused: false,
      ...(artifact ? { artifactId: artifact.id } : {}),
      contentType: download.contentType,
      ...(download.contentLength !== undefined ? { contentLength: download.contentLength } : {}),
      origin: download.origin,
    };
  };

  return {
    downloadRecordingAudio: async (recordingId, opts) =>
      (await downloadRecordingAudioFile(recordingId, opts)).localPath,
    downloadRecordingAudioFile,
    openPath: (localPath) => openPath(localPath, deps),
    revealInFinder: (localPath) => revealInFinder(localPath, deps),
    listDownloads: () => listExistingDownloads(deps),
    listDownloadedRecordingIds: async () =>
      new Set(
        (await listExistingDownloads(deps))
          .map((artifact) => artifact.remoteId)
          .filter((remoteId): remoteId is string => Boolean(remoteId)),
      ),
  };
}

export function openPath(
  localPath: string,
  deps: RecordingAudioRuntimeOptions = {},
): Promise<void> {
  return runMacOpen([localPath], deps);
}

export function revealInFinder(
  localPath: string,
  deps: RecordingAudioRuntimeOptions = {},
): Promise<void> {
  return runMacOpen(["-R", localPath], deps);
}

async function findReusableDownload(
  recordingId: string,
  deps: RecordingAudioRuntimeOptions,
): Promise<RecordingAudioRuntimeDownload | null> {
  return withStore(deps, async (store, account) => {
    if (!account) return null;
    const artifact = store.findLocalArtifactForAccount(account, {
      kind: "download",
      remoteId: recordingId,
    });
    if (!artifact || !(await isReadableFile(artifact.localPath))) return null;
    const opened = store.markLocalArtifactOpened(artifact.id);
    return artifactToDownload(opened, recordingId);
  });
}

async function rememberDownload(
  download: RecordingAudioDownload,
  deps: RecordingAudioRuntimeOptions,
): Promise<LocalArtifact | null> {
  return withStore(deps, (store, account) => {
    if (!account) return null;
    const artifact = store.upsertLocalArtifact({
      kind: "download",
      account,
      remoteId: download.recordingId,
      localPath: download.localPath,
      metadata: {
        resource: "recording_audio",
        contentType: download.contentType,
        ...(download.contentLength !== undefined ? { contentLength: download.contentLength } : {}),
        origin: download.origin,
      },
    });
    return store.markLocalArtifactOpened(artifact.id);
  });
}

async function listExistingDownloads(deps: RecordingAudioRuntimeOptions): Promise<LocalArtifact[]> {
  const artifacts = await withStore(deps, (store, account) =>
    account ? store.listLocalArtifactsForAccount(account, { kind: "download" }) : [],
  );
  const existing: LocalArtifact[] = [];
  for (const artifact of artifacts) {
    if (await isReadableFile(artifact.localPath)) existing.push(artifact);
  }
  return existing;
}

async function withStore<T>(
  deps: RecordingAudioRuntimeOptions,
  run: (store: CliLocalStore, account: AccountPartition | null) => T | Promise<T>,
): Promise<T> {
  const store = deps.store ?? openCliStore({ homeDir: deps.homeDir, env: deps.env });
  try {
    return await run(store, deps.account ?? null);
  } finally {
    if (!deps.store) store.close();
  }
}

function defaultDownloadDirectory(deps: RecordingAudioRuntimeOptions): string {
  return path.join(path.dirname(defaultStorePath(deps.homeDir, deps.env)), "downloads");
}

async function isReadableFile(localPath: string): Promise<boolean> {
  try {
    return (await fs.stat(localPath)).isFile();
  } catch {
    return false;
  }
}

function artifactToDownload(
  artifact: LocalArtifact,
  recordingId: string,
): RecordingAudioRuntimeDownload {
  const metadata = isRecord(artifact.metadata) ? artifact.metadata : {};
  return {
    recordingId,
    localPath: artifact.localPath,
    reused: true,
    artifactId: artifact.id,
    ...(typeof metadata.contentType === "string" ? { contentType: metadata.contentType } : {}),
    ...(typeof metadata.contentLength === "number"
      ? { contentLength: metadata.contentLength }
      : {}),
    ...(typeof metadata.origin === "string" ? { origin: metadata.origin } : {}),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function runMacOpen(args: string[], deps: RecordingAudioRuntimeOptions): Promise<void> {
  if ((deps.platform ?? process.platform) !== "darwin") {
    return Promise.reject(
      cliError(
        "usage.invalid_argument",
        "Recording audio file actions are supported on macOS only.",
        {
          hint: "Download the audio and open the printed local path manually on this platform.",
        },
      ),
    );
  }
  const spawnProcess = deps.spawnProcess ?? spawn;
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true;
      if (error) reject(error);
      else resolve();
    };
    try {
      const child = spawnProcess("open", args, { stdio: "ignore" });
      child.once("error", (error) =>
        finish(error instanceof Error ? error : new Error(String(error))),
      );
      child.once("close", (code) => {
        if (code === 0) finish();
        else {
          finish(
            cliError("internal.unexpected", `open failed with exit code ${code ?? "unknown"}.`),
          );
        }
      });
    } catch (error) {
      finish(error instanceof Error ? error : new Error(String(error)));
    }
  });
}
