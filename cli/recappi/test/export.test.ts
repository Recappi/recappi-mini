import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";
import type {
  AccountStatusData,
  RecordingData,
  TranscriptData,
} from "../../packages/contracts/src/index";
import { syncRecordingAudio, syncRecordingText, type RecordingExportClient } from "../src/export";
import { openCliStore } from "../src/store";

describe("recording local sync", () => {
  it("writes app-like text session files and reuses the session directory", async () => {
    const baseDir = await mkdtemp(path.join(tmpdir(), "recappi-local-sync-"));
    const client = fakeExportClient();
    const store = openCliStore({ dbPath: path.join(baseDir, "state.sqlite") });
    try {
      const first = await syncRecordingText({
        recordingId: "rec_done",
        client,
        store,
        env: { RECAPPI_LOCAL_SESSIONS_DIR: baseDir },
      });
      const second = await syncRecordingText({
        recordingId: "rec_done",
        client,
        store,
        env: { RECAPPI_LOCAL_SESSIONS_DIR: baseDir },
      });

      expect(first.sessionDir).toBe(second.sessionDir);
      expect(first.sessionDir.startsWith(baseDir)).toBe(true);
      await expect(readFile(path.join(first.sessionDir, "transcript.md"), "utf8")).resolves.toBe(
        "# Transcript\n\nHello from the transcript\n",
      );
      const summaryMarkdown = await readFile(path.join(first.sessionDir, "summary.md"), "utf8");
      expect(summaryMarkdown).toContain("# Summary\n\n## TL;DR\n\nShort summary");
      expect(summaryMarkdown).not.toContain("recordingId:");
      expect(summaryMarkdown).not.toContain("summaryStatus:");
      await expect(
        readFile(path.join(first.sessionDir, "action-items.md"), "utf8"),
      ).resolves.toContain("- Mini: Share local handoff");
      const manifest = JSON.parse(
        await readFile(path.join(first.sessionDir, "remote-session.json"), "utf8"),
      );
      expect(manifest).toMatchObject({
        recordingId: "rec_done",
        transcriptId: "tr_done",
        stage: "done",
        accountUserId: "user_123",
      });
      expect(manifest.uploadFilename).toBeUndefined();
      expect(
        store.findLocalArtifactForAccount(
          { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
          { kind: "recording_session", remoteId: "rec_done" },
        ),
      ).toMatchObject({
        localPath: first.sessionDir,
        metadata: {
          resource: "recording_session",
          source: "text_sync",
          recording: { recordingId: "rec_done" },
          files: { transcriptPath: path.join(first.sessionDir, "transcript.md") },
        },
      });
    } finally {
      store.close();
      await rm(baseDir, { recursive: true, force: true });
    }
  });

  it("prefers the SQLite session index before scanning manifests", async () => {
    const baseDir = await mkdtemp(path.join(tmpdir(), "recappi-local-sync-"));
    const client = fakeExportClient();
    const store = openCliStore({ dbPath: path.join(baseDir, "state.sqlite") });
    try {
      const indexedDir = path.join(baseDir, "indexed-session");
      await mkdir(indexedDir);
      store.upsertLocalArtifact({
        kind: "recording_session",
        account: { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
        remoteId: "rec_done",
        localPath: indexedDir,
        metadata: { resource: "recording_session", recording },
      });

      const data = await syncRecordingText({
        recordingId: "rec_done",
        client,
        store,
        env: { RECAPPI_LOCAL_SESSIONS_DIR: baseDir },
      });

      expect(data.sessionDir).toBe(indexedDir);
      await expect(readFile(path.join(indexedDir, "remote-session.json"), "utf8")).resolves.toContain(
        '"recordingId": "rec_done"',
      );
    } finally {
      store.close();
      await rm(baseDir, { recursive: true, force: true });
    }
  });

  it("downloads audio into the same app-like session directory on demand", async () => {
    const baseDir = await mkdtemp(path.join(tmpdir(), "recappi-local-sync-"));
    const client = fakeExportClient();
    const store = openCliStore({ dbPath: path.join(baseDir, "state.sqlite") });
    const downloadRecordingAudioFile = vi.fn(async (_recordingId: string, opts?: { directory?: string }) => {
      const localPath = path.join(opts?.directory ?? baseDir, "recording.wav");
      await writeFile(localPath, Buffer.from([1, 2, 3]));
      return {
        recordingId: "rec_done",
        localPath,
        reused: false,
        contentType: "audio/wav",
        contentLength: 3,
      };
    });
    try {
      const text = await syncRecordingText({
        recordingId: "rec_done",
        client,
        store,
        env: { RECAPPI_LOCAL_SESSIONS_DIR: baseDir },
      });
      const audio = await syncRecordingAudio({
        recordingId: "rec_done",
        client,
        recordingAudio: { downloadRecordingAudioFile },
        store,
        env: { RECAPPI_LOCAL_SESSIONS_DIR: baseDir },
      });
      const textAgain = await syncRecordingText({
        recordingId: "rec_done",
        client,
        store,
        env: { RECAPPI_LOCAL_SESSIONS_DIR: baseDir },
      });

      expect(audio.sessionDir).toBe(text.sessionDir);
      expect(textAgain.sessionDir).toBe(text.sessionDir);
      expect(audio.audioPath).toBe(path.join(text.sessionDir, "recording.wav"));
      expect(downloadRecordingAudioFile).toHaveBeenCalledWith("rec_done", {
        directory: text.sessionDir,
        filenameStem: "recording",
        title: "Weekly sync",
      });
      const manifest = JSON.parse(
        await readFile(path.join(text.sessionDir, "remote-session.json"), "utf8"),
      );
      expect(manifest.uploadFilename).toBe("recording.wav");
    } finally {
      store.close();
      await rm(baseDir, { recursive: true, force: true });
    }
  });
});

function fakeExportClient(): RecordingExportClient {
  return {
    getRecording: async () => recording,
    getTranscript: async () => transcript,
    accountStatus: async () => account,
  };
}

const recording: RecordingData = {
  origin: "https://recordmeet.ing",
  recordingId: "rec_done",
  title: "Weekly sync",
  summaryTitle: "Router agent planning",
  status: "ready",
  durationMs: 720000,
  sizeBytes: 1500000,
  contentType: "audio/wav",
  activeTranscriptId: "tr_done",
  createdAt: 1710000000000,
  updatedAt: 1710000300000,
};

const transcript: TranscriptData = {
  transcriptId: "tr_done",
  recordingId: "rec_done",
  jobId: "job_done",
  provider: "gemini",
  model: "gemini-2.5-pro",
  createdAt: 1710000000000,
  text: "Hello from the transcript",
  segments: [{ startMs: 0, endMs: 1250, speaker: "Peng", text: "Hello from the transcript" }],
  summary: {
    status: "succeeded",
    title: "Short title",
    tldr: "Short summary",
    actionItems: [{ who: "Mini", what: "Share local handoff" }],
  },
};

const account: AccountStatusData = {
  origin: "https://recordmeet.ing",
  loggedIn: true,
  email: "agent@example.com",
  userId: "user_123",
  localStore: {
    path: "/tmp/recappi/store.sqlite3",
    accountScopedArtifacts: 0,
    unattributedArtifacts: 0,
  },
};
