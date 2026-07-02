import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  isLocalStoreUnavailableError,
  normalizeAccountStamp,
  normalizeManifestAccountStamp,
  openCliStore,
  requireAccountPartition,
  resetLocalStoreUnavailableWarning,
  tryOpenCliStore,
  type AccountPartition,
} from "../src/store";

const accountA: AccountPartition = {
  backendOrigin: "https://recordmeet.ing",
  userId: "user_a",
};

const accountB: AccountPartition = {
  backendOrigin: "https://staging.recordmeet.ing",
  userId: "user_a",
};

describe("local store graceful degradation (G9)", () => {
  const throwUnavailable = () => {
    const err = new Error("node:sqlite missing") as Error & { localStoreUnavailable?: boolean };
    err.localStoreUnavailable = true;
    throw err;
  };

  it("detects the local-store-unavailable marker, not other errors", () => {
    const tagged = new Error("x") as Error & { localStoreUnavailable?: boolean };
    tagged.localStoreUnavailable = true;
    expect(isLocalStoreUnavailableError(tagged)).toBe(true);
    expect(isLocalStoreUnavailableError(new Error("real failure"))).toBe(false);
    expect(isLocalStoreUnavailableError(null)).toBe(false);
  });

  it("returns null and warns once when the runtime lacks node:sqlite", () => {
    resetLocalStoreUnavailableWarning();
    let warned = 0;
    const onUnavailable = () => {
      warned += 1;
    };
    expect(tryOpenCliStore({ open: throwUnavailable, onUnavailable })).toBeNull();
    expect(tryOpenCliStore({ open: throwUnavailable, onUnavailable })).toBeNull();
    expect(warned).toBe(1); // once per process, not once per command
  });

  it("rethrows real store failures instead of swallowing them", () => {
    resetLocalStoreUnavailableWarning();
    expect(() =>
      tryOpenCliStore({
        open: () => {
          throw new Error("disk full");
        },
      }),
    ).toThrow("disk full");
  });

  it("opens a usable store on a supported runtime", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "recappi-cli-store-"));
    try {
      const store = tryOpenCliStore({ dbPath: path.join(dir, "state.sqlite") });
      expect(store).not.toBeNull();
      store?.close();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

describe("CLI local SQLite store", () => {
  it("isolates artifacts by normalized backend origin and user id", async () => {
    await withStore((store) => {
      const a = store.addLocalArtifact({
        kind: "recording_session",
        account: accountA,
        localPath: "/tmp/a",
        remoteId: "rec_a",
      });
      const b = store.addLocalArtifact({
        kind: "recording_session",
        account: accountB,
        localPath: "/tmp/b",
        remoteId: "rec_b",
      });

      expect(
        store.listLocalArtifactsForAccount({
          backendOrigin: "https://recordmeet.ing/",
          userId: "user_a",
        }),
      ).toEqual([a]);
      expect(store.listLocalArtifactsForAccount(accountB)).toEqual([b]);
    });
  });

  it("hides unattributed artifacts from account queries until explicit claim", async () => {
    await withStore((store) => {
      const legacy = store.addLocalArtifact({
        kind: "recording_session",
        localPath: "/tmp/legacy",
      });
      const other = store.addLocalArtifact({
        kind: "recording_session",
        account: accountB,
        localPath: "/tmp/other",
      });

      expect(store.listLocalArtifactsForAccount(accountA)).toEqual([]);
      expect(store.listUnattributedLocalArtifacts()).toEqual([legacy]);

      expect(store.claimUnattributedLocalArtifact(legacy.id, accountA)).toBe(true);
      expect(store.listUnattributedLocalArtifacts()).toEqual([]);
      expect(store.listLocalArtifactsForAccount(accountA)).toMatchObject([
        { id: legacy.id, account: accountA },
      ]);

      expect(store.claimUnattributedLocalArtifact(other.id, accountA)).toBe(false);
      expect(store.listLocalArtifactsForAccount(accountB)).toMatchObject([{ id: other.id }]);
    });
  });

  it("upserts download artifacts by account, kind, and remote id", async () => {
    await withStore((store) => {
      const first = store.upsertLocalArtifact({
        kind: "download",
        account: accountA,
        remoteId: "rec_1",
        localPath: "/tmp/old.wav",
        metadata: { contentType: "audio/wav" },
      });
      const second = store.upsertLocalArtifact({
        kind: "download",
        account: accountA,
        remoteId: "rec_1",
        localPath: "/tmp/new.wav",
        metadata: { contentType: "audio/mpeg", contentLength: 3 },
      });
      const opened = store.markLocalArtifactOpened(second.id);

      expect(second.id).toBe(first.id);
      expect(opened).toMatchObject({
        id: first.id,
        localPath: "/tmp/new.wav",
        remoteId: "rec_1",
        metadata: { contentType: "audio/mpeg", contentLength: 3 },
      });
      expect(opened.lastOpenedAt).toBeGreaterThan(opened.createdAt);
      expect(store.listDownloadedRecordingIdsForAccount(accountA)).toEqual(new Set(["rec_1"]));
      expect(store.listLocalArtifactsForAccount(accountA, { kind: "download" })).toHaveLength(1);
    });
  });

  it("treats partial or invalid account stamps as unattributed when reading legacy state", () => {
    expect(normalizeAccountStamp({ backendOrigin: "https://recordmeet.ing" })).toBeNull();
    expect(normalizeAccountStamp({ userId: "user_a" })).toBeNull();
    expect(normalizeAccountStamp({ backendOrigin: "not a url", userId: "user_a" })).toBeNull();
    expect(() => requireAccountPartition({ backendOrigin: "https://recordmeet.ing" })).toThrow(
      /Account stamp must include both backend origin and user id/,
    );
  });

  it("normalizes Mini manifest account field names", () => {
    expect(
      normalizeManifestAccountStamp({
        accountBackendOrigin: "https://recordmeet.ing/",
        accountUserId: "user_a",
      }),
    ).toEqual(accountA);
    expect(
      normalizeManifestAccountStamp({
        accountBackendOrigin: "https://recordmeet.ing",
      }),
    ).toBeNull();
  });
});

async function withStore(run: (store: ReturnType<typeof openCliStore>) => void): Promise<void> {
  const dir = await mkdtemp(path.join(tmpdir(), "recappi-cli-store-"));
  const store = openCliStore({
    dbPath: path.join(dir, "state.sqlite"),
    now: fixedClock(),
  });
  try {
    run(store);
  } finally {
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
}

function fixedClock(): () => number {
  let now = 1710000000000;
  return () => {
    now += 1;
    return now;
  };
}
