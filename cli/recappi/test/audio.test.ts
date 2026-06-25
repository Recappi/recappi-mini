import type { ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";
import { RecappiApiClient } from "../src/api";
import { createRecordingAudioRuntime, openPath, revealInFinder } from "../src/audio";
import { openCliStore } from "../src/store";

type SpawnFn = typeof import("node:child_process").spawn;

describe("recording audio runtime", () => {
  it("downloads recording audio to a title-based local file", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "recappi-audio-test-"));
    try {
      const fetchImpl: typeof fetch = async (input, init) => {
        const url = requestUrl(input);
        expect(init?.method).toBe("GET");
        expect(url.pathname).toBe("/api/recordings/rec%2Fweird/audio");
        expect(init?.headers).toMatchObject({ authorization: "Bearer token" });
        return new Response(new Uint8Array([1, 2, 3]), {
          headers: {
            "content-type": "audio/mpeg; charset=binary",
            "content-length": "3",
          },
        });
      };
      const client = new RecappiApiClient(
        { origin: "https://recordmeet.ing", token: "token", source: "env" },
        { fetchImpl },
      );

      const result = await client.downloadRecordingAudio("rec/weird", {
        directory: dir,
        title: "产品会议 / audio",
      });

      expect(path.basename(result.localPath)).toBe("产品会议-audio-rec-weird.mp3");
      expect(result).toMatchObject({
        recordingId: "rec/weird",
        contentType: "audio/mpeg",
        contentLength: 3,
        origin: "https://recordmeet.ing",
      });
      await expect(readFile(result.localPath)).resolves.toEqual(Buffer.from([1, 2, 3]));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("exposes download as a local path for the dashboard", async () => {
    const downloadRecordingAudio = vi
      .fn()
      .mockResolvedValue({ localPath: "/tmp/design-review.wav" });
    const client = {
      downloadRecordingAudio,
    } as unknown as RecappiApiClient;
    const runtime = createRecordingAudioRuntime(client);

    await expect(runtime.downloadRecordingAudio("rec_1", { title: "Design review" })).resolves.toBe(
      "/tmp/design-review.wav",
    );
    expect(downloadRecordingAudio).toHaveBeenCalledWith("rec_1", {
      title: "Design review",
    });
  });

  it("reuses account-scoped cached downloads before hitting the network", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "recappi-audio-cache-"));
    const store = openCliStore({ dbPath: path.join(dir, "state.sqlite") });
    try {
      const localPath = path.join(dir, "cached.wav");
      await writeFile(localPath, Buffer.from([4, 5, 6]));
      store.upsertLocalArtifact({
        kind: "download",
        account: { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
        remoteId: "rec_1",
        localPath,
        metadata: { contentType: "audio/wav", contentLength: 3, origin: "https://recordmeet.ing" },
      });
      const downloadRecordingAudio = vi.fn().mockRejectedValue(new Error("must not download"));
      const client = { downloadRecordingAudio } as unknown as RecappiApiClient;
      const runtime = createRecordingAudioRuntime(client, {
        account: { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
        store,
      });

      await expect(runtime.downloadRecordingAudioFile("rec_1")).resolves.toMatchObject({
        recordingId: "rec_1",
        localPath,
        reused: true,
        contentType: "audio/wav",
        contentLength: 3,
      });
      await expect(runtime.listDownloadedRecordingIds()).resolves.toEqual(new Set(["rec_1"]));
      expect(downloadRecordingAudio).not.toHaveBeenCalled();
    } finally {
      store.close();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("opens and reveals local files through macOS open", async () => {
    const spawnProcess = vi.fn((_cmd, _args, _opts) => {
      const child = new EventEmitter() as ChildProcess;
      queueMicrotask(() => child.emit("close", 0));
      return child;
    }) as unknown as SpawnFn;

    await openPath("/tmp/design-review.wav", { platform: "darwin", spawnProcess });
    await revealInFinder("/tmp/design-review.wav", { platform: "darwin", spawnProcess });

    expect(spawnProcess).toHaveBeenNthCalledWith(1, "open", ["/tmp/design-review.wav"], {
      stdio: "ignore",
    });
    expect(spawnProcess).toHaveBeenNthCalledWith(2, "open", ["-R", "/tmp/design-review.wav"], {
      stdio: "ignore",
    });
  });

  it("reports open/reveal as macOS-only", async () => {
    await expect(openPath("/tmp/design-review.wav", { platform: "linux" })).rejects.toMatchObject({
      descriptor: { code: "usage.invalid_argument" },
    });
  });
});

function requestUrl(input: Parameters<typeof fetch>[0]): URL {
  if (typeof input === "string") return new URL(input);
  if (input instanceof URL) return input;
  return new URL(input.url);
}
