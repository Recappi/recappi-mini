import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type {
  SidecarEvent,
  SidecarHandshakeParams,
  SidecarRecordingStartParams,
} from "../../packages/contracts/src/index";
import { runCli, type CliDeps } from "../src/cli";
import { cliError } from "../src/errors";
import { bundledSidecarCommand, type RecordRuntimeDeps } from "../src/record";
import { openCliStore, requireAccountPartition } from "../src/store";
import { CLI_VERSION } from "../src/version";

describe("recappi CLI contract", () => {
  it("hard-fails explicit machine mode without command", async () => {
    const result = await run(["--json"]);
    expect(result.exitCode).toBe(2);
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      command: "recappi",
      error: { code: "usage.missing_command", exitCode: 2, retryable: false },
      meta: { schemaVersion: "2026-06-25" },
    });
  });

  it("routes commander parse errors through the JSON error envelope", async () => {
    const result = await run(["--wat", "--json"]);
    expect(result.exitCode).toBe(2);
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      command: "recappi",
      error: {
        code: "usage.invalid_argument",
        exitCode: 2,
        message: "unknown option '--wat'",
      },
      meta: { schemaVersion: "2026-06-25" },
    });
  });

  it("accepts wrapper-provided verbose flag without changing JSON output", async () => {
    const result = await run(["--verbose", "--version", "--json"]);
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      command: "version",
      data: { version: CLI_VERSION },
      meta: { schemaVersion: "2026-06-25" },
    });
  });

  it("shows commander subcommand help without running the command", async () => {
    const result = await run(["auth", "status", "--help"]);
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe("");
    expect(result.stdout).toContain("Usage: recappi auth status");
    expect(result.stdout).toContain("--json");
  });

  it("opens the dashboard for bare `recappi` in an interactive terminal", async () => {
    let dashboardCalls = 0;
    const recordingRequests: string[] = [];
    const result = await run([], {
      fetchImpl: dashboardFetch(recordingRequests),
      isTTY: true,
      runDashboard: async (deps) => {
        dashboardCalls += 1;
        expect(deps.initialView).toBe("overview");
        const data = await deps.fetchJobs();
        expect(data.status).toBe("active");
        expect(data.limit).toBe(20);
        expect(data.items[0]?.jobId).toBe("job_running");
        const firstPage = await deps.fetchRecordings?.();
        expect(firstPage).toMatchObject({
          limit: 50,
          nextCursor: "cursor_2",
          items: [{ recordingId: "rec_page_1" }],
        });
        const secondPage = await deps.fetchRecordings?.({ cursor: firstPage?.nextCursor ?? "" });
        expect(secondPage).toMatchObject({
          limit: 50,
          nextCursor: null,
          items: [{ recordingId: "rec_page_2" }],
        });
        const account = await deps.fetchAccountStatus?.();
        expect(account).toMatchObject({
          loggedIn: true,
          email: "agent@example.com",
          billing: { tier: "pro", minutesUsed: 42.5 },
        });
      },
    });

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("");
    expect(dashboardCalls).toBe(1);
    expect(recordingRequests).toEqual(["limit=50", "limit=50&cursor=cursor_2"]);
  });

  it("exposes a live record session launcher to dashboard deps", async () => {
    const homeDir = await mkdtemp(path.join(tmpdir(), "recappi-cli-home-"));
    const fake = fakeRecordRuntime();
    try {
      let dashboardCalls = 0;
      const result = await run([], {
        homeDir,
        env: {
          RECAPPI_AUTH_TOKEN: "token",
          RECAPPI_DISABLE_KEYCHAIN_AUTH: "1",
          RECAPPI_MINI_SIDECAR: "fake-sidecar",
        },
        fetchImpl: dashboardFetch([]),
        isTTY: true,
        recordRuntime: fake.runtime,
        runDashboard: async (deps) => {
          dashboardCalls += 1;
          const inputs = await deps.fetchRecordSetup?.();
          expect(inputs).toMatchObject({
            sources: [
              { id: "system", kind: "system" },
              { id: "app:com.apple.Safari", bundleId: "com.apple.Safari" },
            ],
            microphones: [{ id: "mic_default", isDefault: true }],
          });
          const session = await deps.startLiveRecord?.({
            sourceId: "system",
            includeMicrophone: true,
            sceneId: "default",
          }, [{ id: "system", kind: "system", label: "System audio · all apps" }]);
          expect(session?.source).toBe(fake.client);
          await session?.stop();
        },
      });

      expect(result.exitCode).toBe(0);
      expect(dashboardCalls).toBe(1);
      expect(fake.calls.map((call) => call.method)).toEqual([
        "spawn",
        "handshake",
        "sources",
        "microphones",
        "kill",
        "spawn",
        "handshake",
        "permissions",
        "start",
        "stop",
        "kill",
      ]);
    } finally {
      await rm(homeDir, { recursive: true, force: true });
    }
  });

  it("exposes account-scoped downloaded recording ids to dashboard deps", async () => {
    const homeDir = await mkdtemp(path.join(tmpdir(), "recappi-cli-home-"));
    const store = openCliStore({ homeDir });
    try {
      const localPath = path.join(homeDir, "rec_page_1.wav");
      await writeFile(localPath, Buffer.from([1]));
      store.upsertLocalArtifact({
        kind: "download",
        account: { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
        remoteId: "rec_page_1",
        localPath,
      });
    } finally {
      store.close();
    }

    try {
      let dashboardCalls = 0;
      const result = await run([], {
        homeDir,
        fetchImpl: dashboardFetch([]),
        isTTY: true,
        runDashboard: async (deps) => {
          dashboardCalls += 1;
          await expect(deps.listDownloadedRecordingIds?.()).resolves.toEqual(
            new Set(["rec_page_1"]),
          );
        },
      });

      expect(result.exitCode).toBe(0);
      expect(dashboardCalls).toBe(1);
    } finally {
      await rm(homeDir, { recursive: true, force: true });
    }
  });

  it("opens the dashboard for `recappi jobs` in an interactive terminal", async () => {
    let dashboardCalls = 0;
    const result = await run(["jobs"], {
      fetchImpl: jobsFetch(),
      isTTY: true,
      runDashboard: async (deps) => {
        dashboardCalls += 1;
        expect(deps.initialView).toBe("jobs");
        const data = await deps.fetchJobs();
        expect(data.status).toBe("active");
      },
    });

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("");
    expect(dashboardCalls).toBe(1);
  });

  it("does not start the dashboard for machine-mode `recappi jobs`", async () => {
    const result = await run(["jobs", "--json"], {
      isTTY: true,
      runDashboard: async () => {
        throw new Error("dashboard must not run in JSON mode");
      },
    });

    expect(result.exitCode).toBe(2);
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      command: "recappi",
      error: { code: "usage.invalid_argument", exitCode: 2 },
    });
  });

  it("does not start the dashboard when a positional token follows --", async () => {
    const result = await run(["--", "--not-a-command"], {
      isTTY: true,
      runDashboard: async () => {
        throw new Error("dashboard must not run for positional tokens");
      },
    });

    expect(result.exitCode).toBe(2);
  });

  it("accepts common options before nested subcommands", async () => {
    const result = await run(["auth", "--json", "status", "--fields", "userId"], {
      fetchImpl: sessionFetch(),
    });
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      command: "auth status",
      data: { userId: "user_123" },
      meta: { schemaVersion: "2026-06-25" },
      ok: true,
    });
  });

  it("returns auth status as JSON on non-TTY stdout", async () => {
    const result = await run(["auth", "status"], { fetchImpl: sessionFetch() });
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toEqual({
      command: "auth status",
      data: {
        email: "agent@example.com",
        loggedIn: true,
        origin: "https://recordmeet.ing",
        userId: "user_123",
      },
      meta: { schemaVersion: "2026-06-25" },
      ok: true,
    });
  });

  it("returns account status with billing and current local artifact scope", async () => {
    const homeDir = await mkdtemp(path.join(tmpdir(), "recappi-cli-home-"));
    const store = openCliStore({ homeDir, now: fixedClock() });
    try {
      const currentAccount = requireAccountPartition({
        backendOrigin: "https://recordmeet.ing/",
        userId: "user_123",
      });
      store.addLocalArtifact({
        kind: "recording_session",
        account: currentAccount,
        localPath: "/tmp/current-session",
        remoteId: "rec_current",
      });
      store.addLocalArtifact({
        kind: "download",
        localPath: "/tmp/unattributed-download",
      });
      store.addLocalArtifact({
        kind: "live_caption_draft",
        account: {
          backendOrigin: "https://staging.recordmeet.ing",
          userId: "user_123",
        },
        localPath: "/tmp/other-origin-draft",
      });
    } finally {
      store.close();
    }

    try {
      const result = await run(["account", "status", "--json"], {
        homeDir,
        fetchImpl: accountStatusFetch(),
      });
      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout)).toEqual({
        ok: true,
        command: "account status",
        meta: { schemaVersion: "2026-06-25" },
        data: {
          origin: "https://recordmeet.ing",
          loggedIn: true,
          email: "agent@example.com",
          userId: "user_123",
          localStore: {
            path: path.join(homeDir, ".local", "share", "recappi", "cli-state.sqlite"),
            accountScopedArtifacts: 1,
            unattributedArtifacts: 1,
          },
          billing: {
            origin: "https://recordmeet.ing",
            tier: "pro",
            periodStart: 1710000000000,
            periodEnd: 1712592000000,
            storageBytes: 1234,
            storageCapBytes: 5000000,
            minutesUsed: 42.5,
            batchMinutesUsed: 40,
            realtimeMinutesUsed: 2.5,
            minutesCap: 120,
            isOverStorage: false,
            isOverMinutes: false,
          },
        },
      });
    } finally {
      await rm(homeDir, { recursive: true, force: true });
    }
  });

  it("returns logged-out account status without touching the network", async () => {
    const homeDir = await mkdtemp(path.join(tmpdir(), "recappi-cli-home-"));
    try {
      const result = await run(["account", "status", "--json"], {
        homeDir,
        env: { RECAPPI_DISABLE_KEYCHAIN_AUTH: "1" },
        fetchImpl: (() => {
          throw new Error("logged-out account status must not hit the network");
        }) as unknown as typeof fetch,
      });
      expect(result.exitCode).toBe(3);
      expect(JSON.parse(result.stdout)).toEqual({
        ok: true,
        command: "account status",
        meta: { schemaVersion: "2026-06-25" },
        data: {
          origin: "https://recordmeet.ing",
          loggedIn: false,
          localStore: {
            path: path.join(homeDir, ".local", "share", "recappi", "cli-state.sqlite"),
            accountScopedArtifacts: 0,
            unattributedArtifacts: 0,
          },
        },
      });
    } finally {
      await rm(homeDir, { recursive: true, force: true });
    }
  });

  it("signs in with device code and stores the CLI token in config", async () => {
    const homeDir = await mkdtemp(path.join(tmpdir(), "recappi-cli-home-"));
    try {
      const result = await run(["auth", "login", "--json", "--no-open"], {
        homeDir,
        env: { RECAPPI_DISABLE_KEYCHAIN_AUTH: "1" },
        fetchImpl: deviceAuthFetch(),
        sleep: async () => {},
      });
      expect(result.exitCode).toBe(0);
      expect(result.stderr).toContain("Open https://recordmeet.ing/device");
      expect(result.stderr).toContain("Enter code: WDJB-MJHT");
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: true,
        command: "auth login",
        data: {
          loggedIn: true,
          origin: "https://recordmeet.ing",
          email: "agent@example.com",
          userId: "user_123",
        },
      });
      const config = JSON.parse(
        await readFile(path.join(homeDir, ".config", "recappi", "config.json"), "utf8"),
      );
      expect(config).toMatchObject({
        origin: "https://recordmeet.ing",
        authToken: "signed-token",
      });
    } finally {
      await rm(homeDir, { recursive: true, force: true });
    }
  });

  it("clears the CLI config token on auth logout", async () => {
    const homeDir = await mkdtemp(path.join(tmpdir(), "recappi-cli-home-"));
    try {
      await mkdir(path.join(homeDir, ".config", "recappi"), { recursive: true });
      await writeFile(
        path.join(homeDir, ".config", "recappi", "config.json"),
        JSON.stringify({ origin: "https://recordmeet.ing", authToken: "signed-token" }),
      );
      const result = await run(["auth", "logout", "--json"], {
        homeDir,
        env: { RECAPPI_DISABLE_KEYCHAIN_AUTH: "1" },
      });
      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: true,
        command: "auth logout",
        data: { loggedIn: false, origin: "https://recordmeet.ing", cleared: true },
      });
      const config = JSON.parse(
        await readFile(path.join(homeDir, ".config", "recappi", "config.json"), "utf8"),
      );
      expect(config.authToken).toBeUndefined();
    } finally {
      await rm(homeDir, { recursive: true, force: true });
    }
  });

  it("starts and stops a sidecar recording, then indexes returned artifacts", async () => {
    const homeDir = await mkdtemp(path.join(tmpdir(), "recappi-cli-home-"));
    const fake = fakeRecordRuntime();
    try {
      const result = await run(
        [
          "record",
          "--json",
          "--title",
          "CLI smoke",
          "--live",
          "--translation-language",
          "zh",
          "--sidecar-command",
          "fake-sidecar",
        ],
        {
          homeDir,
          fetchImpl: sessionFetch(),
          recordRuntime: fake.runtime,
        },
      );

      expect(result.exitCode).toBe(0);
      expect(fake.calls.map((call) => call.method)).toEqual([
        "spawn",
        "handshake",
        "permissions",
        "start",
        "waitForStop",
        "stop",
        "kill",
      ]);
      expect(fake.calls.find((call) => call.method === "handshake")?.params).toMatchObject({
        account: {
          backendOrigin: "https://recordmeet.ing",
          userId: "user_123",
          email: "agent@example.com",
        },
        capabilities: ["recording.capture", "recording.upload", "live_captions.stream"],
      });
      expect(fake.calls.find((call) => call.method === "start")?.params).toMatchObject({
        account: { backendOrigin: "https://recordmeet.ing", userId: "user_123" },
        options: {
          title: "CLI smoke",
          liveCaptions: true,
          translationLanguage: "zh",
        },
      });
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: true,
        command: "record",
        data: {
          origin: "https://recordmeet.ing",
          userId: "user_123",
          live: true,
          sessionId: "sidecar_session_1",
          state: "completed",
          recordingId: "rec_123",
          localSessionRef: "2026-06-25_153000",
          artifacts: [
            { kind: "live_caption_draft", localPath: "/tmp/live-captions.json" },
            {
              kind: "recording_session",
              localPath: "/Users/pengx17/Documents/Recappi Mini/2026-06-25_153000",
              remoteId: "rec_123",
            },
          ],
        },
      });

      const store = openCliStore({ homeDir, readonly: true });
      try {
        const artifacts = store.listLocalArtifactsForAccount({
          backendOrigin: "https://recordmeet.ing",
          userId: "user_123",
        });
        expect(artifacts.map((artifact) => artifact.kind).sort()).toEqual([
          "live_caption_draft",
          "recording_session",
        ]);
      } finally {
        store.close();
      }
    } finally {
      await rm(homeDir, { recursive: true, force: true });
    }
  });

  it("uses the live captions renderer in interactive record --live mode", async () => {
    const fake = fakeRecordRuntime();
    const result = await run(["record", "--live", "--sidecar-command", "fake-sidecar"], {
      isTTY: true,
      fetchImpl: sessionFetch(),
      recordRuntime: fake.runtime,
    });

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("Recording complete");
    expect(fake.calls.map((call) => call.method)).toEqual([
      "spawn",
      "handshake",
      "permissions",
      "start",
      "createLiveRenderer",
      "liveWait",
      "stop",
      "kill",
      "liveClose",
    ]);
    expect(fake.calls.find((call) => call.method === "createLiveRenderer")?.source).toBe(
      fake.client,
    );
  });

  it("reports a platform-neutral helper error when the helper cannot be started", async () => {
    const result = await run(["record", "--json", "--sidecar-command", "fake-sidecar"], {
      fetchImpl: sessionFetch(),
      env: { RECAPPI_AUTH_TOKEN: "token", RECAPPI_DISABLE_KEYCHAIN_AUTH: "1" },
      recordRuntime: {
        spawnSidecar: () => {
          throw cliError("record.helper_unavailable", "Recappi recording helper is not available.", {
            hint: "Run npm install -g recappi@latest, or use npx -y recappi@latest.",
          });
        },
      },
    });

    expect(result.exitCode).toBe(2);
    const parsed = JSON.parse(result.stdout);
    expect(parsed).toMatchObject({
      ok: false,
      command: "record",
      error: { code: "record.helper_unavailable", exitCode: 2 },
      meta: { schemaVersion: "2026-06-25" },
    });
    expect(parsed.error.message).toMatch(
      /recording helper is not available/,
    );
    expect(parsed.error.hint).toContain("npm install -g recappi@latest");
  });

  it("rejects helpers that do not advertise recording capture", async () => {
    const fake = fakeRecordRuntime({ capabilities: [] });
    const result = await run(["record", "--json", "--sidecar-command", "fake-sidecar"], {
      fetchImpl: sessionFetch(),
      recordRuntime: fake.runtime,
    });

    expect(result.exitCode).toBe(2);
    expect(fake.calls.map((call) => call.method)).toEqual(["spawn", "handshake", "kill"]);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      command: "record",
      error: {
        code: "record.capture_unavailable",
        message: "Recappi recording helper does not support capture.",
      },
    });
  });

  it("resolves bundled helper locations per platform and architecture", () => {
    expect(bundledSidecarCommand("darwin", "arm64")).toMatch(
      /helpers\/darwin-arm64\/RecappiMiniSidecar$/,
    );
    expect(bundledSidecarCommand("darwin", "x64")).toMatch(
      /helpers\/darwin-x64\/RecappiMiniSidecar$/,
    );
    expect(bundledSidecarCommand("win32", "x64")).toMatch(
      /helpers\/win32-x64\/RecappiMiniSidecar\.exe$/,
    );
    expect(bundledSidecarCommand("linux", "x64")).toBeNull();
  });

  it("rejects record when all audio inputs are disabled", async () => {
    const result = await run([
      "record",
      "--json",
      "--no-system-audio",
      "--no-microphone",
      "--sidecar-command",
      "fake-sidecar",
    ]);
    expect(result.exitCode).toBe(2);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      command: "recappi",
      error: {
        code: "usage.invalid_argument",
        message: "Choose at least one recording input.",
      },
    });
  });

  it("prints version through the JSON envelope when requested in machine mode", async () => {
    const result = await run(["--version", "--json"]);
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      command: "version",
      data: { version: CLI_VERSION },
      meta: { schemaVersion: "2026-06-25" },
    });
  });

  it(
    "runs doctor checks without changing the machine envelope",
    async () => {
      const result = await run(["doctor", "--json"], { fetchImpl: sessionFetch() });
      expect(result.exitCode).toBe(0);
      const env = JSON.parse(result.stdout);
      expect(env).toMatchObject({
        ok: true,
        command: "doctor",
        data: {
          status: "ok",
          origin: "https://recordmeet.ing",
          authSource: "env",
        },
        meta: { schemaVersion: "2026-06-25" },
      });
      expect(env.data.checks.map((check: { name: string }) => check.name)).toEqual(
        expect.arrayContaining(["runtime.node", "auth.token", "auth.session", "audio.metadata"]),
      );
    },
    15_000,
  );

  it("fetches a transcript by transcript id", async () => {
    const result = await run(["transcript", "get", "tr_123", "--json"], {
      fetchImpl: transcriptFetch(),
    });
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      command: "transcript get",
      data: {
        transcriptId: "tr_123",
        recordingId: "rec_123",
        jobId: "job_123",
        text: "Hello from the transcript",
        segments: [{ startMs: 0, endMs: 1250, speaker: "Peng", text: "Hello from the transcript" }],
        summary: { status: "succeeded", title: "Short title", tldr: "Short summary" },
      },
    });
  });

  it("normalizes millisecond-scale transcript segments to explicit ms fields", async () => {
    const result = await run(["transcript", "get", "tr_ms", "--json"], {
      fetchImpl: transcriptFetch(),
    });
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      command: "transcript get",
      data: {
        transcriptId: "tr_ms",
        durationMs: 73_300,
        segments: [
          {
            startMs: 25_020,
            endMs: 27_000,
            speaker: "Speaker 1",
            text: "Hello there.",
          },
        ],
      },
    });
  });

  it("renders a transcript in human mode with timestamps, speakers, and summary", async () => {
    const result = await run(["transcript", "get", "tr_123", "--human"], {
      fetchImpl: transcriptFetch(),
    });
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("[00:00] Peng: Hello from the transcript");
    expect(result.stdout).toContain("Summary:");
    expect(result.stdout).toContain("Short summary");
  });

  it("lists recent transcription jobs as JSON", async () => {
    const result = await run(["jobs", "list", "--status", "active", "--limit", "5", "--json"], {
      fetchImpl: jobsFetch(),
    });
    expect(result.exitCode).toBe(0);
    const env = JSON.parse(result.stdout);
    expect(env).toMatchObject({
      ok: true,
      command: "jobs list",
      data: {
        status: "active",
        limit: 5,
        origin: "https://recordmeet.ing",
        items: [
          {
            jobId: "job_running",
            recordingId: "rec_running",
            status: "running",
            recording: { title: "Design review", durationMs: 720000 },
          },
          {
            jobId: "job_done",
            recordingId: "rec_done",
            status: "succeeded",
            transcriptId: "tr_done",
          },
        ],
      },
    });
  });

  it("lists recent recordings as JSON", async () => {
    const result = await run(["recordings", "list", "--limit", "5", "--json"], {
      fetchImpl: recordingsFetch(),
    });
    expect(result.exitCode).toBe(0);
    const env = JSON.parse(result.stdout);
    expect(env).toMatchObject({
      ok: true,
      command: "recordings list",
      data: {
        origin: "https://recordmeet.ing",
        limit: 5,
        totalCount: 2,
        items: [
          {
            recordingId: "rec_done",
            title: "Weekly sync",
            summaryTitle: "Router agent planning",
            status: "ready",
            activeTranscriptId: "tr_done",
          },
          {
            recordingId: "rec_processing",
            title: "Audio recording",
            status: "ready",
            activeTranscriptId: null,
          },
        ],
      },
    });
  });

  it("fetches a recording by recording id", async () => {
    const result = await run(["recordings", "get", "rec_done", "--json"], {
      fetchImpl: recordingsFetch(),
    });
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      command: "recordings get",
      data: {
        recordingId: "rec_done",
        title: "Weekly sync",
        summaryTitle: "Router agent planning",
        status: "ready",
        activeTranscriptId: "tr_done",
        origin: "https://recordmeet.ing",
      },
    });
  });

  it("downloads recording audio once and reuses the local artifact on the next run", async () => {
    const homeDir = await mkdtemp(path.join(tmpdir(), "recappi-cli-home-"));
    const audio = audioDownloadFetch();
    try {
      const first = await run(["audio", "rec_done", "--json"], {
        homeDir,
        fetchImpl: audio.fetchImpl,
      });
      const second = await run(["audio", "rec_done", "--json"], {
        homeDir,
        fetchImpl: audio.fetchImpl,
      });

      expect(first.exitCode).toBe(0);
      expect(second.exitCode).toBe(0);
      expect(audio.audioRequests()).toBe(1);
      const firstEnv = JSON.parse(first.stdout);
      const secondEnv = JSON.parse(second.stdout);
      expect(firstEnv).toMatchObject({
        ok: true,
        command: "audio",
        data: {
          recordingId: "rec_done",
          action: "download",
          reused: false,
          contentType: "audio/wav",
          contentLength: 3,
        },
      });
      expect(secondEnv).toMatchObject({
        ok: true,
        command: "audio",
        data: {
          recordingId: "rec_done",
          action: "download",
          reused: true,
          contentType: "audio/wav",
          contentLength: 3,
        },
      });
      expect(secondEnv.data.localPath).toBe(firstEnv.data.localPath);
      await expect(readFile(secondEnv.data.localPath)).resolves.toEqual(Buffer.from([1, 2, 3]));
    } finally {
      await rm(homeDir, { recursive: true, force: true });
    }
  }, 10_000);

  it("fetches dashboard stats as JSON", async () => {
    const result = await run(["dashboard", "stats", "--json"], {
      fetchImpl: recordingsFetch(),
    });
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      command: "dashboard stats",
      data: {
        origin: "https://recordmeet.ing",
        recordings: { total: 2, ready: 2, totalDurationMs: 845000 },
        jobs: { active: 1, queued: 1, running: 0 },
      },
    });
  });

  it("emits one terminal JSONL result for upload --transcribe --wait", async () => {
    const fixture = await writeWavFixture();
    try {
      const result = await run(["upload", fixture, "--transcribe", "--wait", "--jsonl"], {
        fetchImpl: uploadFetch(),
        sleep: async () => {},
      });
      expect(result.exitCode).toBe(0);
      const lines = result.stdout
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
      const terminal = lines.filter((line) => line.type === "result" || line.type === "error");
      expect(terminal).toHaveLength(1);
      expect(terminal[0]).toMatchObject({
        type: "result",
        command: "upload",
        data: {
          successes: [
            {
              recordingId: "rec_123",
              jobId: "job_123",
              transcriptId: "tr_123",
              status: "succeeded",
            },
          ],
          failures: [],
          totalCount: 1,
          attemptedCount: 1,
        },
        meta: { schemaVersion: "2026-06-25" },
      });
    } finally {
      await rm(path.dirname(fixture), { recursive: true, force: true });
    }
  });

  it("renders upload and transcription progress as readable human stages", async () => {
    const fixture = await writeWavFixture();
    try {
      const result = await run(["upload", fixture, "--transcribe", "--wait"], {
        fetchImpl: uploadFetch(),
        isTTY: true,
        sleep: async () => {},
      });
      expect(result.exitCode).toBe(0);
      expect(result.stderr).toContain("Preparing");
      expect(result.stderr).toContain("Uploading");
      expect(result.stderr).toContain("Finalizing upload");
      expect(result.stderr).toContain("Starting transcription");
      expect(result.stderr).toContain("Waiting for transcription");
      expect(result.stderr).toContain("Transcribing");
      expect(result.stderr).not.toMatch(/\bqueued\b|\brunning\b/);
      expect(result.stdout).toContain("Upload complete");
      expect(result.stdout).toContain("recordingId: rec_123");
      expect(result.stdout).toContain("jobId: job_123");
      expect(result.stdout).toContain("transcriptId: tr_123");
      expect(result.stdout).toContain("recappi transcript get tr_123");
    } finally {
      await rm(path.dirname(fixture), { recursive: true, force: true });
    }
  });

  it("filters upload successes with --fields and keeps ids intact", async () => {
    const fixture = await writeWavFixture();
    try {
      const result = await run(
        ["upload", fixture, "--json", "--fields", "recordingId,status", "--compact"],
        {
          fetchImpl: uploadFetch(),
        },
      );
      expect(result.exitCode).toBe(0);
      expect(result.stdout).not.toContain("\n ");
      expect(JSON.parse(result.stdout)).toEqual({
        command: "upload",
        data: {
          attemptedCount: 1,
          successes: [{ recordingId: "rec_123", status: "ready" }],
          totalCount: 1,
        },
        meta: { schemaVersion: "2026-06-25" },
        ok: true,
      });
    } finally {
      await rm(path.dirname(fixture), { recursive: true, force: true });
    }
  });

  it("hard-fails missing --fields value", async () => {
    const result = await run(["auth", "status", "--json", "--fields"]);
    expect(result.exitCode).toBe(2);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      error: {
        code: "usage.invalid_argument",
        message: "Missing value for --fields.",
      },
    });
  });

  it("hard-fails flag-like and empty --fields values", async () => {
    for (const argv of [
      ["auth", "status", "--fields", "--json"],
      ["auth", "status", "--json", "--fields", ",,"],
    ]) {
      const result = await run(argv);
      expect(result.exitCode).toBe(2);
      expect(result.stderr).toBe("");
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: false,
        error: {
          code: "usage.invalid_argument",
          message: "Missing value for --fields.",
        },
      });
    }
  });

  it("returns the machine contract from `schema` with no auth and no network", async () => {
    // No token, no fetch impl: schema must resolve offline before auth so an
    // agent can discover the contract before it is signed in.
    const result = await run(["schema", "--json"], {
      env: { RECAPPI_DISABLE_KEYCHAIN_AUTH: "1" },
      fetchImpl: (() => {
        throw new Error("schema must not hit the network");
      }) as unknown as typeof fetch,
    });
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe("");
    const env = JSON.parse(result.stdout);
    expect(env).toMatchObject({
      ok: true,
      command: "schema",
      meta: { schemaVersion: "2026-06-25" },
    });
    expect(env.data.schemaVersion).toBe("2026-06-25");
    const upload = env.data.commands.find((c: { name: string }) => c.name === "upload");
    expect(upload).toBeTruthy();
    expect(upload.arguments).toEqual([{ name: "file-or-dir", required: true }]);
    expect(upload.data.type).toBe("object");
    const audio = env.data.commands.find((c: { name: string }) => c.name === "audio");
    expect(audio.arguments).toEqual([
      { name: "recording-id", required: true, description: "recording id" },
    ]);
    expect(audio.data.properties.localPath.type).toBe("string");
    expect(audio.data.properties.reused.type).toBe("boolean");
    const record = env.data.commands.find((c: { name: string }) => c.name === "record");
    expect(record.data.properties.artifacts.type).toBe("array");
    const transcript = env.data.commands.find((c: { name: string }) => c.name === "transcript get");
    expect(transcript.data.properties.transcriptId.type).toBe("string");
    const doctor = env.data.commands.find((c: { name: string }) => c.name === "doctor");
    expect(doctor.data.properties.status.enum).toContain("ok");
    const jobsList = env.data.commands.find((c: { name: string }) => c.name === "jobs list");
    expect(jobsList.data.properties.items.type).toBe("array");
    const recordingsList = env.data.commands.find(
      (c: { name: string }) => c.name === "recordings list",
    );
    expect(recordingsList.data.properties.items.type).toBe("array");
    const dashboardStats = env.data.commands.find(
      (c: { name: string }) => c.name === "dashboard stats",
    );
    expect(dashboardStats.data.properties.jobs.type).toBe("object");
    const accountStatus = env.data.commands.find(
      (c: { name: string }) => c.name === "account status",
    );
    expect(accountStatus.data.properties.localStore.type).toBe("object");
    expect(accountStatus.data.properties.billing.type).toBe("object");
    expect(accountStatus.data.required).not.toContain("billing");
    // Common options live once at the top, not duplicated onto every command.
    expect(upload.options.some((o: { flags: string }) => o.flags === "--json")).toBe(false);
    expect(env.data.commonOptions.some((o: { flags: string }) => o.flags === "--json")).toBe(true);
    // partial_failure advertises a dynamic exit code, not a misleading fixed one.
    const partial = env.data.errorCodes.find(
      (c: { code: string }) => c.code === "input.partial_failure",
    );
    expect(partial).toMatchObject({ exitCode: null, retryable: false });
    const errorCodes = env.data.errorCodes.map((c: { code: string }) => c.code);
    expect(errorCodes).toEqual(
      expect.arrayContaining([
        "record.helper_unavailable",
        "record.unsupported_platform",
        "record.capture_unavailable",
        "record.permission_required",
        "record.capture_failed",
      ]),
    );
    // Envelope/event are real JSON Schemas (zod v4 native export).
    expect(env.data.envelope.$schema).toContain("json-schema.org");
    expect(env.data.event.properties.type.enum).toContain("result");
  });

  it("prints a readable command index for `schema --human`", async () => {
    const result = await run(["schema", "--human"], {
      env: { RECAPPI_DISABLE_KEYCHAIN_AUTH: "1" },
    });
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("Commands:");
    expect(result.stdout).toContain("upload — Upload an audio file");
    expect(result.stdout).toContain("recappi schema --json");
  });

  it("reports a partial directory upload as input.partial_failure with per-file errors intact", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "recappi-cli-test-"));
    await writeFile(path.join(dir, "a.wav"), buildWav(1600));
    await writeFile(path.join(dir, "b.wav"), buildWav(1600));
    try {
      const result = await run(["upload", dir, "--json"], { fetchImpl: partialUploadFetch() });
      const env = JSON.parse(result.stdout);
      // Top-level code is the aggregate (NOT one file's category); the real
      // per-file codes stay in data.failures so an agent can retry selectively.
      expect(env).toMatchObject({
        ok: false,
        command: "upload",
        error: { code: "input.partial_failure", retryable: false },
        data: { successes: [{ recordingId: "rec_123" }], totalCount: 2 },
      });
      expect(env.data.failures).toHaveLength(1);
      expect(env.data.failures[0].filePath).toContain("b.wav");
      // Aggregate exit code == worst per-file exit code == process exit code.
      expect(env.error.exitCode).toBe(env.data.failures[0].error.exitCode);
      expect(result.exitCode).toBe(env.error.exitCode);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

async function run(
  argv: string[],
  opts: {
    fetchImpl?: typeof fetch;
    sleep?: (ms: number) => Promise<void>;
    env?: NodeJS.ProcessEnv;
    homeDir?: string;
    isTTY?: boolean;
    openUrl?: CliDeps["openUrl"];
    runDashboard?: CliDeps["runDashboard"];
    recordRuntime?: RecordRuntimeDeps;
  } = {},
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  let stdout = "";
  let stderr = "";
  const exitCode = await runCli({
    argv,
    env: opts.env ?? { RECAPPI_AUTH_TOKEN: "token", RECAPPI_DISABLE_KEYCHAIN_AUTH: "1" },
    homeDir: opts.homeDir,
    isTTY: opts.isTTY ?? false,
    fetchImpl: opts.fetchImpl ?? sessionFetch(),
    sleep: opts.sleep,
    openUrl: opts.openUrl,
    runDashboard: opts.runDashboard,
    recordRuntime: opts.recordRuntime,
    stdout: (text) => {
      stdout += text;
    },
    stderr: (text) => {
      stderr += text;
    },
  });
  return { exitCode, stdout, stderr };
}

function fakeRecordRuntime(opts: { capabilities?: string[] } = {}): {
  runtime: RecordRuntimeDeps;
  client: unknown;
  calls: Array<{ method: string; params?: unknown; source?: unknown }>;
} {
  const calls: Array<{ method: string; params?: unknown; source?: unknown }> = [];
  const listeners = new Set<(event: SidecarEvent) => void>();
  const emit = (event: SidecarEvent) => {
    for (const listener of listeners) listener(event);
  };
  const client = {
    onEvent(listener: (event: SidecarEvent) => void): () => void {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    async handshake(params: SidecarHandshakeParams) {
      calls.push({ method: "handshake", params });
      return {
        protocolVersion: 1,
        sidecar: { name: "fake-sidecar", version: "1.0.0" },
        capabilities: opts.capabilities ?? params.capabilities,
      };
    },
    async startRecording(params: SidecarRecordingStartParams) {
      calls.push({ method: "start", params });
      emit({
        type: "local_artifact.upserted",
        sessionId: "sidecar_session_1",
        artifact: { kind: "live_caption_draft", localPath: "/tmp/live-captions.json" },
      });
      return {
        sessionId: "sidecar_session_1",
        state: "recording",
        localSessionRef: "2026-06-25_153000",
      };
    },
    async getPermissionStatus(params: unknown) {
      calls.push({ method: "permissions", params });
      return {
        permissions: [
          { name: "screen_recording", status: "granted" },
          { name: "microphone", status: "granted" },
        ],
      };
    },
    async listRecordingSources() {
      calls.push({ method: "sources" });
      return {
        sources: [
          { id: "system", kind: "system", label: "System audio · all apps" },
          {
            id: "app:com.apple.Safari",
            kind: "app",
            label: "Safari",
            appName: "Safari",
            bundleId: "com.apple.Safari",
          },
        ],
      };
    },
    async listMicrophones() {
      calls.push({ method: "microphones" });
      return {
        microphones: [{ id: "mic_default", label: "MacBook Pro Microphone", isDefault: true }],
      };
    },
    async stopRecording(params: { sessionId: string }) {
      calls.push({ method: "stop", params });
      return {
        sessionId: "sidecar_session_1",
        state: "completed",
        recordingId: "rec_123",
        localSessionRef: "2026-06-25_153000",
        artifacts: [
          {
            kind: "recording_session",
            localPath: "/Users/pengx17/Documents/Recappi Mini/2026-06-25_153000",
            remoteId: "rec_123",
          },
        ],
      };
    },
    async cancelRecording(params: { sessionId: string }) {
      calls.push({ method: "cancel", params });
      return { sessionId: params.sessionId, state: "cancelled" };
    },
  };
  return {
    client,
    calls,
    runtime: {
      spawnSidecar: ({ command }) => {
        calls.push({ method: "spawn", params: { command } });
        return {
          client: client as never,
          kill: () => calls.push({ method: "kill" }),
        };
      },
      waitForStop: async () => {
        calls.push({ method: "waitForStop" });
      },
      createLiveRenderer: (source) => {
        calls.push({ method: "createLiveRenderer", source });
        return {
          waitUntilStop: async () => {
            calls.push({ method: "liveWait" });
          },
          close: () => calls.push({ method: "liveClose" }),
        };
      },
    },
  };
}

function sessionFetch(): typeof fetch {
  return async (input) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/auth/get-session") {
      return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
    }
    return jsonResponse({ message: "not found" }, { status: 404 });
  };
}

function deviceAuthFetch(): typeof fetch {
  let polls = 0;
  return async (input, init) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/device-auth/start" && init?.method === "POST") {
      return jsonResponse({
        device_code: "device-code",
        user_code: "WDJB-MJHT",
        verification_uri: "https://recordmeet.ing/device",
        verification_uri_complete: "https://recordmeet.ing/device?user_code=WDJB-MJHT",
        expires_in: 600,
        interval: 1,
      });
    }
    if (url.pathname === "/api/device-auth/poll" && init?.method === "POST") {
      polls += 1;
      if (polls === 1) return jsonResponse({ status: "pending", interval: 1 });
      return jsonResponse({
        status: "authorized",
        token: "signed-token",
        user: { id: "user_123", email: "agent@example.com" },
      });
    }
    if (url.pathname === "/api/auth/get-session") {
      return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
    }
    return jsonResponse({ message: "not found" }, { status: 404 });
  };
}

function accountStatusFetch(): typeof fetch {
  return async (input) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/auth/get-session") {
      return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
    }
    if (url.pathname === "/api/billing/status") {
      return jsonResponse({
        tier: "pro",
        periodStart: 1710000000000,
        periodEnd: 1712592000000,
        storageBytes: 1234,
        storageCapBytes: 5000000,
        minutesUsed: 42.5,
        batchMinutesUsed: 40,
        realtimeMinutesUsed: 2.5,
        minutesCap: 120,
        isOverStorage: false,
        isOverMinutes: false,
      });
    }
    return jsonResponse({ message: `unexpected ${url.pathname}` }, { status: 404 });
  };
}

function uploadFetch(): typeof fetch {
  let jobPolls = 0;
  return async (input, init) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/recordings" && init?.method === "POST") {
      return jsonResponse({ id: "rec_123", partSize: 4096 });
    }
    if (url.pathname === "/api/recordings/rec_123/parts/1" && init?.method === "PUT") {
      return jsonResponse({ partNumber: 1, etag: "etag_1", sizeBytes: 44 });
    }
    if (url.pathname === "/api/recordings/rec_123/complete" && init?.method === "POST") {
      return jsonResponse({ id: "rec_123", status: "ready" });
    }
    if (url.pathname === "/api/recordings/rec_123/transcribe" && init?.method === "POST") {
      return jsonResponse({ jobId: "job_123", status: "queued" });
    }
    if (url.pathname === "/api/jobs/job_123") {
      jobPolls += 1;
      return jsonResponse({
        id: "job_123",
        recordingId: "rec_123",
        status: jobPolls === 1 ? "queued" : jobPolls === 2 ? "running" : "succeeded",
        transcriptId: jobPolls < 3 ? null : "tr_123",
      });
    }
    if (url.pathname === "/api/auth/get-session") {
      return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
    }
    return jsonResponse({ message: `unexpected ${url.pathname}` }, { status: 404 });
  };
}

function transcriptFetch(): typeof fetch {
  return async (input) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/transcripts/tr_123") {
      return jsonResponse({
        id: "tr_123",
        recordingId: "rec_123",
        jobId: "job_123",
        provider: "gemini",
        model: "gemini-2.5-pro",
        language: "en",
        durationMs: 1250,
        createdAt: 1710000000000,
        text: "Hello from the transcript",
        segmentsJson: JSON.stringify([
          { start: 0, end: 1.25, speaker: "Peng", text: "Hello from the transcript" },
        ]),
        summaryStatus: "succeeded",
        summaryJson: JSON.stringify({ title: "Short title", tldr: "Short summary" }),
      });
    }
    if (url.pathname === "/api/transcripts/tr_ms") {
      return jsonResponse({
        id: "tr_ms",
        recordingId: "rec_ms",
        jobId: "job_ms",
        provider: "gemini",
        model: "gemini-2.5-pro",
        language: "en",
        durationMs: 73_300,
        createdAt: 1710000000000,
        text: "Hello there.",
        segmentsJson: JSON.stringify([
          { start: 25_020, end: 27_000, speaker: "Speaker 1", text: "Hello there." },
        ]),
        summaryStatus: "skipped",
        summaryJson: null,
      });
    }
    if (url.pathname === "/api/auth/get-session") {
      return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
    }
    return jsonResponse({ message: `unexpected ${url.pathname}` }, { status: 404 });
  };
}

function jobsFetch(): typeof fetch {
  return async (input) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/jobs") {
      expect(url.searchParams.get("status")).toBe("active");
      return jsonResponse({
        status: url.searchParams.get("status"),
        limit: Number(url.searchParams.get("limit") ?? 10),
        items: [
          {
            jobId: "job_running",
            recordingId: "rec_running",
            status: "running",
            provider: "gemini",
            model: "gemini-2.5-pro",
            language: "en",
            attempts: 1,
            enqueuedAt: 1710000000000,
            startedAt: 1710000002000,
            transcriptId: null,
            processedDurationMs: 60000,
            heartbeatPhase: "transcribing",
            recording: {
              title: "Design review",
              durationMs: 720000,
              createdAt: 1709999900000,
            },
          },
          {
            jobId: "job_done",
            recordingId: "rec_done",
            status: "succeeded",
            provider: "gemini",
            model: "gemini-2.5-pro",
            language: "en",
            attempts: 1,
            enqueuedAt: 1709990000000,
            startedAt: 1709990001000,
            finishedAt: 1709990030000,
            transcriptId: "tr_done",
            processedDurationMs: 125000,
            heartbeatPhase: null,
            recording: {
              title: "Weekly sync",
              durationMs: 125000,
              createdAt: 1709989900000,
            },
          },
        ],
      });
    }
    if (url.pathname === "/api/auth/get-session") {
      return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
    }
    return jsonResponse({ message: `unexpected ${url.pathname}` }, { status: 404 });
  };
}

function dashboardFetch(recordingRequests: string[]): typeof fetch {
  const base = jobsFetch();
  return async (input, init) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/recordings") {
      recordingRequests.push(url.searchParams.toString());
      const cursor = url.searchParams.get("cursor");
      return jsonResponse({
        nextCursor: cursor ? null : "cursor_2",
        totalCount: 2,
        items: [
          {
            id: cursor ? "rec_page_2" : "rec_page_1",
            title: cursor ? "Second page" : "First page",
            status: "ready",
            activeTranscriptId: null,
            createdAt: 1710000000000,
            updatedAt: 1710000000000,
          },
        ],
      });
    }
    if (url.pathname === "/api/billing/status") {
      return jsonResponse({
        tier: "pro",
        periodStart: 1710000000000,
        periodEnd: 1712592000000,
        storageBytes: 1234,
        storageCapBytes: 5000000,
        minutesUsed: 42.5,
        batchMinutesUsed: 40,
        realtimeMinutesUsed: 2.5,
        minutesCap: 120,
        isOverStorage: false,
        isOverMinutes: false,
      });
    }
    return base(input, init);
  };
}

function recordingsFetch(): typeof fetch {
  return async (input) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/recordings") {
      expect(url.searchParams.get("limit")).toBe("5");
      return jsonResponse({
        nextCursor: null,
        totalCount: 2,
        items: recordingRows(),
      });
    }
    if (url.pathname === "/api/recordings/rec_done") {
      return jsonResponse(recordingRows()[0]);
    }
    if (url.pathname === "/api/dashboard/stats") {
      return jsonResponse({
        recordings: {
          total: 2,
          ready: 2,
          uploading: 0,
          failed: 0,
          aborted: 0,
          totalDurationMs: 845000,
          totalSizeBytes: 2000000,
        },
        jobs: {
          active: 1,
          queued: 1,
          running: 0,
          succeeded: 4,
          failed: 1,
        },
      });
    }
    if (url.pathname === "/api/auth/get-session") {
      return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
    }
    return jsonResponse({ message: `unexpected ${url.pathname}` }, { status: 404 });
  };
}

function audioDownloadFetch(): { fetchImpl: typeof fetch; audioRequests: () => number } {
  let requests = 0;
  return {
    audioRequests: () => requests,
    fetchImpl: async (input) => {
      const url = requestUrl(input);
      if (url.pathname === "/api/auth/get-session") {
        return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
      }
      if (url.pathname === "/api/recordings/rec_done/audio") {
        requests += 1;
        return new Response(new Uint8Array([1, 2, 3]), {
          headers: {
            "content-type": "audio/wav",
            "content-length": "3",
          },
        });
      }
      return jsonResponse({ message: `unexpected ${url.pathname}` }, { status: 404 });
    },
  };
}

function recordingRows() {
  return [
    {
      id: "rec_done",
      title: "Weekly sync",
      summaryTitle: "Router agent planning",
      status: "ready",
      sizeBytes: 1500000,
      durationMs: 720000,
      contentType: "audio/wav",
      activeTranscriptId: "tr_done",
      createdAt: 1710000000000,
      updatedAt: 1710000300000,
    },
    {
      id: "rec_processing",
      title: "Audio recording",
      summaryTitle: null,
      status: "ready",
      sizeBytes: 500000,
      durationMs: 125000,
      contentType: "audio/wav",
      activeTranscriptId: null,
      createdAt: 1709990000000,
      updatedAt: 1709990100000,
    },
  ];
}

function partialUploadFetch(): typeof fetch {
  let createCount = 0;
  return async (input, init) => {
    const url = requestUrl(input);
    if (url.pathname === "/api/recordings" && init?.method === "POST") {
      createCount += 1;
      // First file uploads cleanly; second file's recording create fails so the
      // batch ends with one success + one failure.
      if (createCount === 1) return jsonResponse({ id: "rec_123", partSize: 4096 });
      return jsonResponse({ message: "server boom" }, { status: 500 });
    }
    if (url.pathname === "/api/recordings/rec_123/parts/1" && init?.method === "PUT") {
      return jsonResponse({ partNumber: 1, etag: "etag_1", sizeBytes: 44 });
    }
    if (url.pathname === "/api/recordings/rec_123/complete" && init?.method === "POST") {
      return jsonResponse({ id: "rec_123", status: "ready" });
    }
    if (url.pathname === "/api/auth/get-session") {
      return jsonResponse({ user: { id: "user_123", email: "agent@example.com" } });
    }
    return jsonResponse({ message: `unexpected ${url.pathname}` }, { status: 404 });
  };
}

function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  headers.set("content-type", "application/json");
  return new Response(JSON.stringify(body), {
    ...init,
    headers,
  });
}

function requestUrl(input: Parameters<typeof fetch>[0]): URL {
  if (input instanceof Request) return new URL(input.url);
  if (input instanceof URL) return input;
  return new URL(input);
}

async function writeWavFixture(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "recappi-cli-test-"));
  const filePath = path.join(dir, "sample.wav");
  await writeFile(filePath, buildWav(1600));
  return filePath;
}

function buildWav(dataLength: number): Buffer {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0, "ascii");
  header.writeUInt32LE(36 + dataLength, 4);
  header.write("WAVE", 8, "ascii");
  header.write("fmt ", 12, "ascii");
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(16000, 24);
  header.writeUInt32LE(32000, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36, "ascii");
  header.writeUInt32LE(dataLength, 40);
  return Buffer.concat([header, Buffer.alloc(dataLength)]);
}

function fixedClock(): () => number {
  let now = 1710000000000;
  return () => {
    now += 1;
    return now;
  };
}
