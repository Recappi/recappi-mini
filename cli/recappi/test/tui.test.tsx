import React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render } from "ink-testing-library";
import {
  countJobs,
  formatAge,
  formatClockMs,
  jobDetail,
  listWindow,
  groupedListWindow,
  windowByHeights,
  padCell,
  progressBar,
  resolveJobLinks,
  statusGlyph,
  transcribeFraction,
} from "../src/tui/format";
import { TranscriptView } from "../src/tui/TranscriptView";
import { LiveCaptionsView } from "../src/tui/LiveCaptionsView";
import { PermissionPreflightView } from "../src/tui/PermissionPreflightView";
import { LiveCaptionsScreen } from "../src/tui/LiveCaptionsScreen";
import { RecordSetupView } from "../src/tui/RecordSetupView";
import { RecordingHeroScreen } from "../src/tui/RecordingHeroScreen";
import { RecordFrame } from "../src/tui/RecordFrame";
import { applyRecordingEventToTelemetry } from "../src/recordingCore";
import {
  liveCaptionReducer,
  initialLiveCaptionsState,
  sidecarToLiveCaptionEvent,
  type LiveCaptionsState,
} from "../src/tui/liveCaptions";
import { JobsView } from "../src/tui/JobsView";
import { OverviewView } from "../src/tui/OverviewView";
import { JobDetailView } from "../src/tui/JobDetailView";
import { RecordingsView } from "../src/tui/RecordingsView";
import { RecordingDetailView } from "../src/tui/RecordingDetailView";
import {
  AppShell,
  permissionItemsFromRecordError,
  recordErrorCopy,
  recordErrorState,
  transcribeHandoffErrorCopy,
  type AppShellProps,
} from "../src/tui/AppShell";
import { DASHBOARD_RENDER_OPTIONS, runDashboard, type RunDashboardDeps } from "../src/tui";
import type {
  AccountStatusData,
  JobListData,
  JobListItem,
  RecordingData,
  RecordingListData,
  SidecarEvent,
  TranscriptData,
} from "../../packages/contracts/src/index";

vi.setConfig({ testTimeout: 20_000 });

const flush = () => new Promise((resolve) => setTimeout(resolve, 20));

async function waitFor(assertion: () => void, timeoutMs = 1_000): Promise<void> {
  const started = Date.now();
  let lastError: unknown;
  while (Date.now() - started < timeoutMs) {
    try {
      assertion();
      return;
    } catch (error) {
      lastError = error;
      await flush();
    }
  }
  assertion();
  if (lastError) throw lastError;
}
const noAnsi = (s: string | undefined) => (s ?? "").replace(/\[[0-9;]*m/g, "");
const DOWN = "[B";
const ENTER = "\r";

afterEach(() => {
  cleanup();
});

const running = (over: Partial<JobListItem> = {}): JobListItem => ({
  jobId: "job_1",
  recordingId: "rec_1",
  status: "running",
  provider: "gemini",
  processedDurationMs: 6000,
  recording: { title: "Design review", durationMs: 12000 },
  ...over,
});
const done = (over: Partial<JobListItem> = {}): JobListItem => ({
  jobId: "job_2",
  recordingId: "rec_2",
  status: "succeeded",
  transcriptId: "tr_2",
  recording: { title: "Product call", durationMs: 60000 },
  ...over,
});
const rec = (over: Partial<RecordingData> = {}): RecordingData => ({
  recordingId: "rec_1",
  title: "Design review",
  status: "ready",
  durationMs: 13 * 60_000 + 48_000,
  sizeBytes: 7_900_000,
  activeTranscriptId: "tr_1",
  createdAt: 1,
  updatedAt: 1,
  origin: "https://recordmeet.ing",
  ...over,
});

describe("record error copy", () => {
  it("maps helper error codes to friendly, jargon-free copy", () => {
    const unavailable = recordErrorCopy("record.helper_unavailable", "x");
    expect(unavailable.title).toContain("missing its local recorder");
    expect(unavailable.detail).toContain("npm install -g recappi@latest");
    expect(unavailable.detail).toContain("npx -y recappi@latest");
    expect(unavailable.tone).toBe("yellow");
    expect(recordErrorCopy("record.unsupported_platform", "x").title).toContain("supported");
    expect(recordErrorCopy("record.unsupported_platform", "x").detail).toContain("Recappi Mini");
    const captureUnavailable = recordErrorCopy("record.capture_unavailable", "x");
    expect(captureUnavailable.title).toContain("local recorder");
    expect(captureUnavailable.detail).toContain("Update recappi");
    const permissionRequired = recordErrorCopy("record.permission_required", "x");
    expect(permissionRequired.title).toContain("permission");
    expect(permissionRequired.detail).toContain("System Settings");
    const captureFailed = recordErrorCopy("record.capture_failed", "x");
    expect(captureFailed.title).toContain("Couldn't start");
    expect(captureFailed.detail).toContain("please try again");
    expect(captureFailed.tone).toBe("red");
    // unknown/undefined code falls back to the raw message + red tone
    const fallback = recordErrorCopy(undefined, "boom");
    expect(fallback.title).toContain("Couldn't start");
    expect(fallback.detail).toBe("boom");
    expect(fallback.tone).toBe("red");
    // never leak internal jargon
    for (const code of [
      "record.helper_unavailable",
      "record.unsupported_platform",
      "record.capture_unavailable",
      "record.permission_required",
      "record.capture_failed",
    ]) {
      const c = recordErrorCopy(code, "x");
      const text = `${c.title} ${c.detail ?? ""}`.toLowerCase();
      expect(text).not.toContain("helper");
      expect(text).not.toContain("sidecar");
      expect(text).not.toContain("env");
      expect(text).not.toContain("path");
    }
  });

  it("extracts descriptor codes and permission items from CLI errors", () => {
    const error = Object.assign(new Error("Microphone access is required."), {
      descriptor: { code: "record.permission_required" },
      data: {
        code: -32020,
        message: "Microphone access is required.",
        data: {
          cliCode: "record.permission_required",
          permission: "microphone",
          recovery: "Open System Settings > Privacy & Security > Microphone, then retry.",
        },
      },
    });
    const state = recordErrorState(error);
    expect(state.code).toBe("record.permission_required");
    expect(permissionItemsFromRecordError(state.data)).toEqual([
      {
        name: "Microphone",
        status: "denied",
        hint: "Open System Settings > Privacy & Security > Microphone, then retry.",
      },
    ]);

    const restartError = Object.assign(new Error("Screen Recording enabled."), {
      descriptor: { code: "record.permission_required" },
      data: {
        code: -32020,
        message: "Screen Recording enabled.",
        data: {
          cliCode: "record.permission_required",
          permission: "screen_recording",
          recovery: "Screen Recording enabled. Run recappi record again to start.",
          requiresProcessRestart: true,
        },
      },
    });
    expect(permissionItemsFromRecordError(recordErrorState(restartError).data)).toEqual([
      {
        name: "Screen Recording",
        status: "granted",
        hint: "Screen Recording enabled. Run recappi record again to start.",
        requiresProcessRestart: true,
      },
    ]);

    const microphoneRestartError = Object.assign(new Error("Microphone enabled."), {
      descriptor: { code: "record.permission_required" },
      data: {
        code: -32020,
        message: "Microphone enabled.",
        data: {
          cliCode: "record.permission_required",
          permission: "microphone",
          recovery: "Microphone enabled. Run recappi record again to start.",
          requiresProcessRestart: "true",
        },
      },
    });
    expect(permissionItemsFromRecordError(recordErrorState(microphoneRestartError).data)).toEqual([
      {
        name: "Microphone",
        status: "granted",
        hint: "Microphone enabled. Run recappi record again to start.",
        requiresProcessRestart: true,
      },
    ]);
  });

  it("maps transcribe handoff failures without leaking internal details", () => {
    const notFound = Object.assign(new Error("ENOENT: /Users/private/rec.m4a"), {
      descriptor: { code: "input.not_found" },
    });
    expect(transcribeHandoffErrorCopy(notFound)).toBe(
      "The local recording file is no longer available.",
    );

    const raw = new Error("uploadPathBatch failed at /Users/private/rec.m4a\nstack: internal");
    const copy = transcribeHandoffErrorCopy(raw);
    expect(copy).toBe("Could not start transcription. Please try again.");
    expect(copy).not.toContain("/Users/private");
    expect(copy).not.toContain("uploadPathBatch");
    expect(copy).not.toContain("stack");
  });
});

describe("tui format helpers", () => {
  it("formats clock from ms", () => {
    expect(formatClockMs(0)).toBe("00:00");
    expect(formatClockMs(75_000)).toBe("01:15");
    expect(formatClockMs(3_700_000)).toBe("1:01:40");
    expect(formatClockMs(null)).toBe("--:--");
  });
  it("draws a clamped progress bar", () => {
    expect(progressBar(0.5, 10)).toBe("[█████░░░░░]");
    expect(progressBar(2, 10)).toBe("[██████████]");
  });
  it("computes real transcribe fraction, null without a total", () => {
    expect(
      transcribeFraction(running({ processedDurationMs: 6000, recording: { durationMs: 12000 } })),
    ).toBe(0.5);
    expect(transcribeFraction(running({ recording: {} }))).toBeNull();
  });
  it("uses single-width glyphs, animates running", () => {
    expect(statusGlyph("queued", 0)).toBe("○");
    expect(statusGlyph("succeeded", 0)).toBe("✓");
    expect(statusGlyph("running", 0)).not.toBe(statusGlyph("running", 1));
  });
  it("renders job detail string", () => {
    expect(jobDetail(running())).toContain("50%");
    expect(jobDetail(done())).toBe("transcript ready");
  });
  it("pads/truncates cells", () => {
    expect(padCell("ab", 5)).toBe("ab   ");
    expect(padCell("abcdef", 4)).toBe("abc…");
  });
  it("counts jobs by status", () => {
    const c = countJobs([running(), running({ jobId: "j", status: "queued" }), done()]);
    expect(c).toMatchObject({ total: 3, running: 1, queued: 1, succeeded: 1, active: 2 });
  });
  it("windows a list to keep the selection in view", () => {
    expect(listWindow(0, 3, 10)).toEqual({ start: 0, end: 3 });
    expect(listWindow(0, 100, 10)).toEqual({ start: 0, end: 10 });
    expect(listWindow(50, 100, 10)).toEqual({ start: 45, end: 55 });
    expect(listWindow(99, 100, 10)).toEqual({ start: 90, end: 100 });
  });

  it("windows a grouped list so headers + spacing fit the budget", () => {
    // 5 contiguous groups of 4. A header costs 1 line; each inner group change
    // also adds a blank spacing line. Budget must never be exceeded.
    const buckets = Array.from({ length: 20 }, (_, i) => `g${Math.floor(i / 4)}`);
    const cost = (w: { start: number; end: number }) => {
      let boundaries = 0;
      for (let i = w.start + 1; i < w.end; i++) if (buckets[i] !== buckets[i - 1]) boundaries++;
      return w.end - w.start + 1 + boundaries * 2;
    };
    for (const selected of [0, 7, 10, 19]) {
      const w = groupedListWindow(buckets, selected, 12);
      expect(cost(w)).toBeLessThanOrEqual(12);
      expect(selected).toBeGreaterThanOrEqual(w.start);
      expect(selected).toBeLessThan(w.end);
    }
    // Degenerate budgets stay safe.
    expect(groupedListWindow(buckets, 0, 0)).toEqual({ start: 0, end: 0 });
    expect(groupedListWindow([], 0, 10)).toEqual({ start: 0, end: 0 });
  });

  it("windows variable-height items so the tail is reachable and fits the budget", () => {
    const heights = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1]; // 10 single-row items
    // From the top, only the budget fits.
    expect(windowByHeights(heights, 0, 4)).toEqual({ start: 0, end: 4, maxScroll: 6 });
    // Scrolling past maxScroll clamps so the last item is always visible.
    expect(windowByHeights(heights, 99, 4)).toEqual({ start: 6, end: 10, maxScroll: 6 });
    // A tall item never starves the view — always show at least one.
    expect(windowByHeights([5, 1, 1], 0, 3).start).toBe(0);
    expect(windowByHeights([5, 1, 1], 0, 3).end).toBe(1);
    // Degenerate inputs stay safe.
    expect(windowByHeights([], 0, 5)).toEqual({ start: 0, end: 0, maxScroll: 0 });
    expect(windowByHeights([1, 1], 0, 0)).toEqual({ start: 0, end: 0, maxScroll: 0 });
  });

  it("formats relative age", () => {
    const now = 1_000_000_000;
    expect(formatAge(now, now)).toBe("just now");
    expect(formatAge(now - 5 * 60_000, now)).toBe("5m ago");
    expect(formatAge(now - 3 * 3_600_000, now)).toBe("3h ago");
    expect(formatAge(null, now)).toBe("");
  });
  it("resolves links from contract, falls back to agreed shape", () => {
    expect(
      resolveJobLinks({ ...running(), links: { webUrl: "X" } } as JobListItem, "https://o"),
    ).toEqual({ webUrl: "X" });
    expect(resolveJobLinks(running(), "https://o").webUrl).toBe(
      "https://o/recordings/rec_1?job=job_1",
    );
    expect(resolveJobLinks(running({ recordingId: "" }), "https://o").webUrl).toBeUndefined();
  });
});

describe("views render", () => {
  it("JobsView lists rows and marks selection", () => {
    const { lastFrame } = render(
      <JobsView items={[running(), done()]} selectedIndex={1} spinnerFrame={0} />,
    );
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("Design review");
    expect(frame).toContain("50%");
    expect(frame.split("\n").find((l) => l.includes("Product call"))).toContain("▸");
  });
  it("JobsView shows empty state", () => {
    const { lastFrame } = render(<JobsView items={[]} selectedIndex={0} spinnerFrame={0} />);
    expect(noAnsi(lastFrame())).toContain("No transcription jobs yet");
  });
  it("OverviewView shows a stats bar + the grouped recordings list", () => {
    const { lastFrame } = render(
      <OverviewView
        recordings={[rec()]}
        jobs={[running()]}
        selectedIndex={0}
        spinnerFrame={0}
        nowMs={10_000_000}
        columns={80}
      />,
    );
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("recordings"); // stats bar (headline count + label)
    expect(frame).toContain("1 transcribing"); // running job count in stats bar
    expect(frame).toContain("Design review"); // the recordings list
  });
  it("RecordingsView lists recordings and marks selection", () => {
    const { lastFrame } = render(
      <RecordingsView
        items={[
          rec(),
          rec({ recordingId: "rec_2", title: "Weekly sync", activeTranscriptId: null }),
        ]}
        selectedIndex={1}
        nowMs={10_000_000}
        columns={80}
      />,
    );
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("Design review");
    expect(frame.split("\n").find((l) => l.includes("Weekly sync"))).toContain("▸");
  });
  it("RecordingsView marks recordings that are downloaded locally", () => {
    const { lastFrame } = render(
      <RecordingsView
        items={[rec({ recordingId: "rec_dl", title: "Has download" })]}
        selectedIndex={0}
        nowMs={1}
        columns={100}
        downloadedRecordingIds={new Set(["rec_dl"])}
      />,
    );
    expect(noAnsi(lastFrame())).toContain("⤓");
  });
  it("RecordingsView shows empty state", () => {
    const { lastFrame } = render(
      <RecordingsView items={[]} selectedIndex={0} nowMs={1} columns={80} />,
    );
    expect(noAnsi(lastFrame())).toContain("No recordings yet");
  });
  it("PermissionPreflightView shows status and guidance", () => {
    const denied = render(
      <PermissionPreflightView
        items={[
          { name: "Screen Recording", status: "denied" },
          { name: "Microphone", status: "granted" },
        ]}
      />,
    );
    const deniedFrame = noAnsi(denied.lastFrame());
    expect(deniedFrame).toContain("Screen Recording");
    expect(deniedFrame).toContain("not allowed");
    expect(deniedFrame).toContain("System Settings");
    expect(deniedFrame).toContain("press r to recheck");
    expect(deniedFrame).not.toContain("All set");

    const granted = render(
      <PermissionPreflightView
        items={[
          { name: "Screen Recording", status: "granted" },
          { name: "Microphone", status: "granted" },
        ]}
      />,
    );
    expect(noAnsi(granted.lastFrame())).toContain("All set");

    const restart = render(
      <PermissionPreflightView
        items={[
          { name: "Screen Recording", status: "granted", requiresProcessRestart: true },
        ]}
      />,
    );
    const restartFrame = noAnsi(restart.lastFrame());
    expect(restartFrame).toContain("Run recappi record again");
    expect(restartFrame).not.toContain("All set");

    const micRestart = render(
      <PermissionPreflightView
        items={[
          {
            name: "Microphone",
            status: "granted",
            hint: "Microphone enabled. Run recappi record again to start.",
            requiresProcessRestart: true,
          },
        ]}
      />,
    );
    const micRestartFrame = noAnsi(micRestart.lastFrame());
    expect(micRestartFrame).toContain("Microphone enabled");
    expect(micRestartFrame).not.toContain("Screen Recording enabled");
  });
  it("RecordingDetailView shows title, status, audio + transcript actions", () => {
    const { lastFrame } = render(<RecordingDetailView item={rec()} nowMs={10_000_000} />);
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("‹ Recordings");
    expect(frame).toContain("Design review");
    expect(frame).toContain("Ready");
    expect(frame).toContain("o open");
    expect(frame).toContain("d download");
  });
  it("RecordingDetailView renders the audio download state", () => {
    const { lastFrame } = render(
      <RecordingDetailView
        item={rec()}
        nowMs={10_000_000}
        audio={{ status: "ready", localPath: "/tmp/design-review.aac" }}
      />,
    );
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("Downloaded");
    expect(frame).toContain("design-review.aac");
  });
  it("RecordingDetailView shows Summary/Chapters/Transcript tabs, Summary active", () => {
    const transcript = {
      transcriptId: "t",
      recordingId: "rec_1",
      jobId: "j",
      provider: "g",
      model: "m",
      createdAt: 1,
      text: "full text",
      segments: [{ startMs: 0, endMs: 1000, speaker: "A", text: "segment one text" }],
      summary: {
        status: "succeeded" as const,
        tldr: "the gist of it",
        keyPoints: ["key point one"],
        timeline: [{ startMs: 5000, endMs: 9000, title: "Chapter Alpha", summary: "c" }],
      },
    };
    const { lastFrame } = render(
      <RecordingDetailView item={rec()} nowMs={1} transcript={transcript} />,
    );
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("Summary");
    expect(frame).toContain("Chapters");
    expect(frame).toContain("Transcript");
    // Summary tab active by default: its tldr shows; other panes' content does not.
    expect(frame).toContain("the gist of it");
    expect(frame).not.toContain("Chapter Alpha");
    expect(frame).not.toContain("segment one text");
  });
  it("TranscriptView windows a long transcript from the top (not just the tail)", () => {
    const segments = Array.from({ length: 80 }, (_, i) => ({
      startMs: i * 1000,
      endMs: i * 1000 + 500,
      speaker: "S",
      text: `line ${i}`,
    }));
    const { lastFrame } = render(
      <TranscriptView
        loading={false}
        data={{
          transcriptId: "t",
          recordingId: "r",
          jobId: "j",
          provider: "g",
          model: "m",
          createdAt: 1,
          text: "x",
          segments,
          summary: { status: "skipped" },
        }}
      />,
    );
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("line 0"); // top is visible
    expect(frame).not.toContain("line 79"); // tail is windowed out
    expect(frame).toContain("/ 80"); // scroll position indicator
  });
  it("liveCaptionReducer folds status/partial/final/error", () => {
    let s = initialLiveCaptionsState();
    expect(s.status).toBe("connecting");
    s = liveCaptionReducer(s, { kind: "status", status: "live", atMs: 1000 });
    expect(s.status).toBe("live");
    expect(s.startedAtMs).toBe(1000);
    s = liveCaptionReducer(s, { kind: "partial", text: "hello wor" });
    expect(s.partial).toBe("hello wor");
    s = liveCaptionReducer(s, {
      kind: "final",
      line: { id: "1", text: "hello world", speaker: "A" },
    });
    expect(s.partial).toBeUndefined(); // final supersedes partial
    expect(s.lines.map((l) => l.text)).toEqual(["hello world"]);
    s = liveCaptionReducer(s, { kind: "error", message: "stream dropped" });
    expect(s.status).toBe("error");
    expect(s.error).toBe("stream dropped");
  });
  it("LiveCaptionsView renders status, finalized lines, and the partial", () => {
    const state: LiveCaptionsState = {
      status: "live",
      startedAtMs: 0,
      lines: [{ id: "1", text: "first finalized line", speaker: "Speaker 1" }],
      partial: "in progress words",
    };
    const { lastFrame } = render(<LiveCaptionsView state={state} nowMs={5_000} />);
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("LIVE");
    expect(frame).toContain("first finalized line");
    expect(frame).toContain("in progress words");
  });
  it("LiveCaptionsScreen drives the view from a sidecar event source", async () => {
    let emit: (e: unknown) => void = () => {};
    const source = {
      onEvent(listener: (e: unknown) => void) {
        emit = listener;
        return () => {};
      },
    };
    const { lastFrame } = render(<LiveCaptionsScreen source={source as never} now={() => 0} />);
    await flush();
    expect(noAnsi(lastFrame())).toContain("Waiting for captions…");
    emit({ type: "recording.state", sessionId: "s", state: "recording" });
    emit({ type: "live_caption.delta", sessionId: "s", stream: "source", text: "live words here" });
    await flush();
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("LIVE");
    expect(frame).toContain("live words here");
  });
  it("RecordSetupView keeps microphone additive instead of listing it as a source", async () => {
    const onStart = vi.fn();
    const onCancel = vi.fn();
    const model = {
      sources: [
        { id: "sys", kind: "system" as const, label: "System audio · all apps" },
        {
          id: "app:com.apple.Safari",
          kind: "app" as const,
          label: "Safari",
          appName: "Safari",
          bundleId: "com.apple.Safari",
        },
      ],
      microphones: [
        { id: "mic_default", label: "MacBook Pro Microphone", isDefault: true },
        { id: "mic_usb", label: "USB Mic" },
      ],
      scenes: [{ id: "default", label: "Default" }],
    };
    const { lastFrame, stdin } = render(
      <RecordSetupView model={model} onStart={onStart} onCancel={onCancel} />,
    );
    await flush();
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("New recording");
    expect(frame).toContain("System audio · all apps");
    expect(frame).toContain("Safari");
    expect(frame).not.toContain("No app-specific sources available right now");
    expect(frame).toContain("[x] include mic");
    expect(frame).toContain("MacBook Pro Microphone");
    expect(frame).toContain("Capture");
    expect(frame).not.toContain("Microphone only");
    expect(frame).not.toContain("INPUT PREVIEW");
    stdin.write("m");
    await flush();
    expect(noAnsi(lastFrame())).toContain("USB Mic");
    stdin.write(" ");
    await flush();
    expect(noAnsi(lastFrame())).toContain("[ ] include mic");
    stdin.write("\r");
    await flush();
    expect(onStart).toHaveBeenCalledWith(
      expect.objectContaining({ sourceId: "sys", includeMicrophone: false, sceneId: "default" }),
    );
  });

  it("RecordSetupView shows a live level for the previewed source/mic and — for the rest", () => {
    const model = {
      sources: [
        { id: "sys", kind: "system" as const, label: "System audio · all apps" },
        { id: "app:arc", kind: "app" as const, label: "Arc", bundleId: "x" },
      ],
      microphones: [{ id: "mic_default", label: "MacBook Pro Microphone", isDefault: true }],
      scenes: [{ id: "default", label: "Default" }],
    };
    // P0: only the selected source (sys) + mic are previewed; others show "—".
    const { lastFrame } = render(
      <RecordSetupView
        model={model}
        levels={{ bySourceId: { sys: 0.6 }, byMicrophoneId: { mic_default: 0.22 } }}
        onStart={() => {}}
        onCancel={() => {}}
      />,
    );
    const f = noAnsi(lastFrame());
    expect(f).toContain("-24 dB"); // sys: 0.6*60-60 = -24
    expect(f).toContain("-47 dB"); // mic: 0.22*60-60 ≈ -47
    expect(f).toContain("—"); // Arc not previewed
    // A silent (dead) source reads "silent", not a misleading low dB — catches
    // the Arc-silent capture bug at setup, before recording.
    const silent = render(
      <RecordSetupView
        model={model}
        levels={{ bySourceId: { sys: 0 }, byMicrophoneId: {} }}
        onStart={() => {}}
        onCancel={() => {}}
      />,
    );
    expect(noAnsi(silent.lastFrame())).toContain("silent");
  });
  it("RecordSetupView snaps to the default mic when the list arrives async", async () => {
    // The mic list loads after mount; the default isn't index 0. Setup must
    // select the system default (and thus preview it), not the first device.
    const base = {
      sources: [{ id: "sys", kind: "system" as const, label: "System audio" }],
      scenes: [{ id: "default", label: "Default" }],
    };
    const { lastFrame, rerender } = render(<RecordSetupView model={{ ...base, microphones: [] }} onStart={() => {}} onCancel={() => {}} />);
    await flush();
    rerender(
      <RecordSetupView
        model={{ ...base, microphones: [{ id: "usb", label: "USB Mic" }, { id: "builtin", label: "Built-in Mic", isDefault: true }] }}
        onStart={() => {}}
        onCancel={() => {}}
      />,
    );
    await flush();
    // Default (Built-in) is selected as the mic device, not the first (USB).
    expect(noAnsi(lastFrame())).toContain("Built-in Mic");
  });
  it("RecordSetupView treats missing app sources as current state, not future work", async () => {
    const { lastFrame } = render(
      <RecordSetupView
        model={{
          sources: [{ id: "sys", kind: "system" as const, label: "System audio · all apps" }],
          microphones: [],
          scenes: [{ id: "default", label: "Default" }],
        }}
        onStart={vi.fn()}
        onCancel={vi.fn()}
      />,
    );
    await flush();
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("No app-specific sources available right now");
    expect(frame).not.toContain("coming soon");
  });

  it("RecordingHeroScreen renders the recording hero and the saved state", () => {
    const recording = render(
      <RecordingHeroScreen
        telemetry={{
          status: "recording",
          startedAtMs: 0,
          sourceLabel: "System audio · Google Meet (Arc)",
          micEnabled: true,
          level: { system: 0.6, mic: 0.3 },
        }}
        now={() => 42_000}
      />,
    );
    const rf = noAnsi(recording.lastFrame());
    expect(rf).toContain("recappi");
    expect(rf).toContain("REC");
    expect(rf).toContain("00:42");
    expect(rf).toContain("Google Meet");
    expect(rf).toContain("Microphone");
    expect(rf).not.toContain("Waiting for captions");

    const stopped = render(
      <RecordingHeroScreen
        telemetry={{
          status: "stopped",
          sourceLabel: "System audio",
          micEnabled: false,
          durationMs: 42_000,
          sizeBytes: 1_200_000,
          savedPath: "/Users/x/rec.m4a",
        }}
        now={() => 0}
      />,
    );
    const sf = noAnsi(stopped.lastFrame());
    expect(sf).toContain("Saved to your Mac");
    expect(sf).toContain("Saved locally");
    stopped.rerender(
      <RecordingHeroScreen
        telemetry={{
          status: "stopped",
          sourceLabel: "System audio",
          micEnabled: false,
          savedPath: "/Users/x/rec.m4a",
        }}
        artifact={{
          sessionId: "s",
          audioPath: "/Users/x/rec.m4a",
          uploadStatus: "local_only",
          transcriptionStatus: "not_started",
        }}
        canTranscribe
        now={() => 0}
      />,
    );
    // Auto-flow: stopped + local + not-yet-transcribed shows the auto handoff
    // ("Starting transcription…"), not a manual "Transcribe now?" prompt.
    expect(noAnsi(stopped.lastFrame())).toContain("Starting transcription…");
    // Failed handoff: the retry prompt and the error reason must be on separate
    // lines (the column box), not concatenated onto one line.
    stopped.rerender(
      <RecordingHeroScreen
        telemetry={{
          status: "stopped",
          sourceLabel: "System audio",
          micEnabled: false,
          savedPath: "/Users/x/rec.m4a",
        }}
        artifact={{
          sessionId: "s",
          audioPath: "/Users/x/rec.m4a",
          uploadStatus: "failed",
          error: "Network unreachable",
        }}
        canTranscribe
        now={() => 0}
      />,
    );
    const failedFrame = noAnsi(stopped.lastFrame());
    expect(failedFrame).toContain("Transcription failed · ⏎ retry");
    expect(failedFrame).toContain("Network unreachable");
    expect(failedFrame).not.toContain("not nowNetwork");
  });
  it("RecordingHeroScreen shows honest activity (not a flat meter) before level telemetry arrives", () => {
    // No `level` field → helper hasn't emitted audio.level yet. Must not draw a
    // flat waveform that reads as silence (the bug peng saw as "audio is 0").
    const noLevel = render(
      <RecordingHeroScreen
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "System audio", micEnabled: false }}
        now={() => 0}
      />,
    );
    const nf = noAnsi(noLevel.lastFrame());
    expect(nf).toContain("REC");
    expect(nf).toContain("Capturing audio");
    // Once real level telemetry arrives, the waveform replaces the placeholder.
    const withLevel = render(
      <RecordingHeroScreen
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "System audio", micEnabled: false, level: { system: 0.7 } }}
        now={() => 0}
      />,
    );
    expect(noAnsi(withLevel.lastFrame())).not.toContain("Capturing audio");
  });
  it("RecordFrame renders the two-pane frame with a scrollable caption split", () => {
    let caps = initialLiveCaptionsState();
    caps = liveCaptionReducer(caps, { kind: "status", status: "live", atMs: 0 });
    caps = liveCaptionReducer(caps, { kind: "final", line: { id: "1", text: "看着抽下面大哥逆转" } });
    caps = liveCaptionReducer(caps, { kind: "translationFinal", segmentId: "1", text: "watching the guy below" });
    const { lastFrame } = render(
      <RecordFrame
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "System audio", micEnabled: true, level: { system: 0.6, mic: 0.2 } }}
        captions={caps}
        recordings={[rec(), rec({ recordingId: "rec_2", title: "Weekly sync" })]}
        selectedIndex={0}
        title="New recording"
        recordingId="rec_abc"
        jobId="job_xyz"
        nowMs={60_000}
      />,
    );
    const f = noAnsi(lastFrame());
    expect(f).toContain("RECORDINGS"); // left list header
    expect(f).toContain("rec_abc"); // ids in status header
    expect(f).toContain("ORIGINAL"); // caption split columns
    expect(f).toContain("TRANSLATION");
    expect(f).toContain("看着抽下面大哥逆转"); // source stream
    expect(f).toContain("watching the guy below"); // translation stream (independent)
    expect(f).toContain("OUTCOME");
  });
  it("RecordingHeroScreen shows the post-stop upload/transcribe lifecycle with a bar", () => {
    // Uploading: stays "Saved to your Mac" (not yet on cloud) + a progress bar.
    const uploading = render(
      <RecordingHeroScreen
        telemetry={{ status: "stopped", sourceLabel: "Arc", micEnabled: true, durationMs: 60_000, sizeBytes: 1_000_000 }}
        artifact={{ sessionId: "s", audioPath: "a", uploadStatus: "uploading", uploadProgress: 0.64 }}
        canTranscribe
        now={() => 0}
      />,
    );
    const uf = noAnsi(uploading.lastFrame());
    expect(uf).toContain("Saved to your Mac");
    expect(uf).toContain("Uploading to Recappi Cloud");
    expect(uf).toContain("64%");
    // Uploaded + transcribing: now claims the cloud + shows transcribe progress,
    // as a percent only (never "N/M parts").
    const transcribing = render(
      <RecordingHeroScreen
        telemetry={{ status: "stopped", sourceLabel: "Arc", micEnabled: true, durationMs: 60_000 }}
        artifact={{ sessionId: "s", audioPath: "a", uploadStatus: "uploaded", transcriptionStatus: "processing", transcriptionProgress: 0.6 }}
        canTranscribe
        now={() => 0}
      />,
    );
    const tf = noAnsi(transcribing.lastFrame());
    expect(tf).toContain("Saved to Recappi Cloud");
    expect(tf).toContain("Transcribing");
    expect(tf).toContain("60%");
    expect(tf).not.toMatch(/\d+\s*\/\s*\d+\s*parts?/); // no internal chunk exposure
  });
  it("RecordingHeroScreen shows separate System/Mic meters with honest dB", () => {
    // Two per-source meters so a dead mic is visible, not merged into one bar.
    // dB is the real value the helper sent, recovered exactly from the 0..1 level
    // (level*60-60): 0.72 -> -17 dB, 0.18 -> -49 dB. Not fabricated.
    const { lastFrame } = render(
      <RecordingHeroScreen
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "Arc", micEnabled: true, level: { system: 0.72, mic: 0.18 } }}
        now={() => 0}
      />,
    );
    const f = noAnsi(lastFrame());
    expect(f).toContain("System");
    expect(f).toContain("Mic");
    expect(f).toContain("-17 dB");
    expect(f).toContain("-49 dB");
    // Mic row is hidden when mic is off (no merged/phantom mic meter).
    const noMic = render(
      <RecordingHeroScreen
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "Arc", micEnabled: false, level: { system: 0.5 } }}
        now={() => 0}
      />,
    );
    expect(noAnsi(noMic.lastFrame())).not.toContain("Mic");
  });
  it("RecordingHeroScreen flags a silent source instead of a misleading low dB", () => {
    // A dead source (the Arc-silent capture bug) must read "silent", not "-60 dB".
    const { lastFrame } = render(
      <RecordingHeroScreen
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "Arc", micEnabled: false, level: { system: 0 } }}
        now={() => 0}
      />,
    );
    expect(noAnsi(lastFrame())).toContain("silent");
  });
  it("RecordingHeroScreen shows live captions (source + translation + partial) when streaming", () => {
    const withCaptions = render(
      <RecordingHeroScreen
        telemetry={{
          status: "recording",
          startedAtMs: 0,
          sourceLabel: "System audio · all apps",
          micEnabled: true,
          level: { system: 0.6 },
        }}
        captions={{
          status: "live",
          startedAtMs: 0,
          lines: [
            { id: "1", text: "Hello everyone, thanks for joining.", translation: "大家好" },
          ],
          partial: "So the first item",
        }}
        now={() => 0}
      />,
    );
    const cf = noAnsi(withCaptions.lastFrame());
    expect(cf).toContain("Hello everyone, thanks for joining.");
    expect(cf).toContain("大家好"); // bilingual translation row
    expect(cf).toContain("So the first item"); // in-flight partial
    // captions stream on but no speech yet → honest "listening" hint
    const listening = render(
      <RecordingHeroScreen
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "System audio", micEnabled: false, level: { system: 0 } }}
        captions={{ status: "live", startedAtMs: 0, lines: [] }}
        now={() => 0}
      />,
    );
    expect(noAnsi(listening.lastFrame())).toContain("Listening for speech");
    const captionError = render(
      <RecordingHeroScreen
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "System audio", micEnabled: false, level: { system: 0 } }}
        captions={{
          status: "error",
          lines: [],
          error: "Live captions claim failed (HTTP 429): too many claims",
        }}
        now={() => 0}
      />,
    );
    const ef = noAnsi(captionError.lastFrame());
    expect(ef).toContain("Captions unavailable");
    expect(ef).toContain("HTTP 429"); // surfaces the real WS reason, not a bare label
    expect(ef).not.toContain("Recording error");
    expect(ef).toContain("REC"); // recording continues despite caption error
    // no captions prop → no caption area at all (plain hero)
    const noCaptions = render(
      <RecordingHeroScreen
        telemetry={{ status: "recording", startedAtMs: 0, sourceLabel: "System audio", micEnabled: false, level: { system: 0 } }}
        now={() => 0}
      />,
    );
    expect(noAnsi(noCaptions.lastFrame())).not.toContain("Listening for speech");
  });
  it("LiveCaptionsView shows a waiting state before any captions", () => {
    const { lastFrame } = render(<LiveCaptionsView state={initialLiveCaptionsState()} nowMs={0} />);
    expect(noAnsi(lastFrame())).toContain("Waiting for captions…");
  });
  it("sidecarToLiveCaptionEvent maps sidecar events to the view-model", () => {
    expect(
      sidecarToLiveCaptionEvent({ type: "ready", protocolVersion: 1, sidecar: {} } as never),
    ).toEqual({
      kind: "status",
      status: "connecting",
    });
    expect(
      sidecarToLiveCaptionEvent({
        type: "recording.state",
        sessionId: "s",
        state: "recording",
      } as never),
    ).toEqual({ kind: "status", status: "live" });
    expect(
      sidecarToLiveCaptionEvent({
        type: "recording.state",
        sessionId: "s",
        state: "failed",
        message: "boom",
      } as never),
    ).toEqual({ kind: "error", message: "boom" });
    expect(
      sidecarToLiveCaptionEvent({
        type: "live_caption.delta",
        sessionId: "s",
        stream: "source",
        text: "hi",
      } as never),
    ).toEqual({ kind: "partial", text: "hi" });
    expect(
      sidecarToLiveCaptionEvent({
        type: "live_caption.delta",
        sessionId: "s",
        stream: "source",
        text: "hello",
        isFinal: true,
        segmentId: "seg1",
        speaker: "A",
        startMs: 1200,
      } as never),
    ).toEqual({ kind: "final", line: { id: "seg1", text: "hello", speaker: "A", atMs: 1200 } });
    // audio levels are ignored (translation stream is handled separately, below)
    expect(
      sidecarToLiveCaptionEvent({ type: "audio.level", sessionId: "s", input: "system" } as never),
    ).toBeNull();
    expect(
      sidecarToLiveCaptionEvent({
        type: "error",
        code: "live_caption.receive_failed",
        message: "stream dropped",
      } as never),
    ).toEqual({ kind: "error", message: "stream dropped" });
    expect(
      sidecarToLiveCaptionEvent({
        type: "error",
        code: "record.capture_failed",
        message: "recording failed",
      } as never),
    ).toBeNull();
    // live_caption.status from the helper's reconnect loop maps straight through…
    expect(
      sidecarToLiveCaptionEvent({
        type: "live_caption.status",
        sessionId: "s",
        status: "reconnecting",
      } as never),
    ).toEqual({ kind: "status", status: "reconnecting" });
    expect(
      sidecarToLiveCaptionEvent({
        type: "live_caption.status",
        sessionId: "s",
        status: "live",
      } as never),
    ).toEqual({ kind: "status", status: "live" });
    // …except "error", which routes through the error event so the reason survives
    expect(
      sidecarToLiveCaptionEvent({
        type: "live_caption.status",
        sessionId: "s",
        status: "error",
        message: "claim failed",
      } as never),
    ).toEqual({ kind: "error", message: "claim failed" });
    expect(
      sidecarToLiveCaptionEvent({
        type: "live_caption.status",
        sessionId: "s",
        status: "error",
      } as never),
    ).toEqual({ kind: "error", message: "Live captions error" });
  });
  it("reconnecting status surfaces in the hero caption tail", () => {
    // helper drops → reconnecting should render the "Reconnecting…" label, then
    // recover to live on resume.
    let state = initialLiveCaptionsState();
    for (const ev of [
      { type: "live_caption.status", sessionId: "s", status: "live" },
      { type: "live_caption.status", sessionId: "s", status: "reconnecting" },
    ] as const) {
      const mapped = sidecarToLiveCaptionEvent(ev as never);
      if (mapped) state = liveCaptionReducer(state, mapped);
    }
    expect(state.status).toBe("reconnecting");
    const { lastFrame } = render(
      <RecordingHeroScreen
        telemetry={{
          status: "recording",
          startedAtMs: 0,
          sourceLabel: "System audio",
          micEnabled: false,
        }}
        captions={state}
        now={() => 1000}
      />,
    );
    expect(lastFrame()).toContain("Reconnecting…");
  });
  it("keeps live-caption sidecar errors out of recording telemetry", () => {
    const telemetry = {
      status: "recording" as const,
      startedAtMs: 0,
      sourceLabel: "System audio",
      micEnabled: true,
    };
    expect(
      applyRecordingEventToTelemetry(telemetry, {
        type: "error",
        code: "live_caption.connect_failed",
        message: "Live captions claim failed (HTTP 429): too many claims",
      } as never),
    ).toEqual(telemetry);
    expect(
      applyRecordingEventToTelemetry(telemetry, {
        type: "error",
        code: "record.capture_failed",
        message: "No audio was captured.",
      } as never),
    ).toMatchObject({ status: "error", error: "No audio was captured." });
  });
  it("handles bilingual captions: translation pairs onto its source line", () => {
    // adapter maps the translation stream
    expect(
      sidecarToLiveCaptionEvent({
        type: "live_caption.delta",
        sessionId: "s",
        stream: "translation",
        text: "你好",
      } as never),
    ).toEqual({ kind: "translationPartial", text: "你好" });
    expect(
      sidecarToLiveCaptionEvent({
        type: "live_caption.delta",
        sessionId: "s",
        stream: "translation",
        text: "你好世界",
        isFinal: true,
        segmentId: "seg1",
      } as never),
    ).toEqual({ kind: "translationFinal", segmentId: "seg1", text: "你好世界" });
    // reducer pairs translationFinal onto the matching source line
    let s = initialLiveCaptionsState();
    s = liveCaptionReducer(s, { kind: "final", line: { id: "seg1", text: "hello world" } });
    s = liveCaptionReducer(s, { kind: "translationFinal", segmentId: "seg1", text: "你好世界" });
    expect(s.lines[0]?.translation).toBe("你好世界");
    // view renders both source and translation
    const { lastFrame } = render(<LiveCaptionsView state={s} nowMs={0} />);
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("hello world");
    expect(frame).toContain("你好世界");
  });
  it("TranscriptView renders ms segment times correctly (not 7-hour timestamps)", () => {
    const { lastFrame } = render(
      <TranscriptView
        loading={false}
        data={{
          transcriptId: "t",
          recordingId: "r",
          jobId: "j",
          provider: "gemini",
          model: "g",
          createdAt: 1,
          durationMs: 73_300,
          text: "x",
          segments: [
            { startMs: 25_020, endMs: 27_000, speaker: "Speaker 1", text: "Hello there." },
          ],
          summary: { status: "skipped" },
        }}
      />,
    );
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("[00:25] Speaker 1: Hello there.");
    expect(frame).not.toContain("6:57:00");
  });

  it("JobDetailView shows inspector with timeline and open footer", () => {
    const { lastFrame } = render(
      <JobDetailView
        item={running({ startedAt: 100, enqueuedAt: 50 })}
        origin="https://o"
        spinnerFrame={0}
        nowMs={200}
      />,
    );
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("‹ Jobs / Design review");
    expect(frame).toContain("Timeline");
    expect(frame).toContain("o open");
    expect(frame).toContain("m mac app (soon)");
  });
});

describe("runDashboard", () => {
  it("renders interactive dashboards in the alternate screen", async () => {
    let renderOptions: unknown;
    const renderApp: NonNullable<RunDashboardDeps["renderApp"]> = vi.fn((_node, options) => {
      renderOptions = options;
      return { waitUntilExit: async () => {} };
    });
    const fetchJobs = vi.fn().mockResolvedValue({
      items: [],
      status: "active",
      limit: 20,
      origin: "https://recordmeet.ing",
    } satisfies JobListData);
    const fetchTranscript = vi.fn();

    await runDashboard({ fetchJobs, fetchTranscript, renderApp });

    expect(renderApp).toHaveBeenCalledTimes(1);
    expect(renderOptions).toEqual(DASHBOARD_RENDER_OPTIONS);
  });
});

describe("AppShell (interactive)", () => {
  const jobData: JobListData = {
    items: [running(), done()],
    status: "active",
    limit: 20,
    origin: "https://recordmeet.ing",
  };
  const transcript: TranscriptData = {
    transcriptId: "tr_2",
    recordingId: "rec_2",
    jobId: "job_2",
    provider: "gemini",
    model: "g",
    createdAt: 1,
    text: "hello",
    segments: [{ startMs: 0, endMs: 1000, speaker: "Peng", text: "hello" }],
    summary: { status: "succeeded", tldr: "a chat" },
  };

  const recData: RecordingListData = {
    items: [rec(), rec({ recordingId: "rec_2", title: "Weekly sync", activeTranscriptId: "tr_1" })],
    limit: 20,
    origin: "https://recordmeet.ing",
  };

  const accountStatus: AccountStatusData = {
    origin: "https://recordmeet.ing",
    loggedIn: true,
    email: "agent@example.com",
    userId: "user_123",
    localStore: {
      path: "/tmp/recappi/store.sqlite3",
      accountScopedArtifacts: 2,
      unattributedArtifacts: 1,
    },
    billing: {
      origin: "https://recordmeet.ing",
      tier: "pro",
      periodStart: 1710000000000,
      periodEnd: 1810000000000,
      storageBytes: 1024,
      storageCapBytes: 4096,
      minutesUsed: 42,
      batchMinutesUsed: 40,
      realtimeMinutesUsed: 2,
      minutesCap: 120,
      isOverStorage: false,
      isOverMinutes: false,
    },
  };

  const setup = (props: Partial<AppShellProps> = {}) => {
    const fetchJobs = vi.fn().mockResolvedValue(jobData);
    const fetchTranscript = vi.fn().mockResolvedValue(transcript);
    const fetchRecordings = vi.fn().mockResolvedValue(recData);
    const openUrl = vi.fn();
    const copyText = vi.fn();
    const r = render(
      <AppShell
        fetchJobs={fetchJobs}
        fetchTranscript={fetchTranscript}
        fetchRecordings={fetchRecordings}
        openUrl={openUrl}
        copyText={copyText}
        now={() => 1000}
        pollMs={10_000}
        spinnerMs={10_000}
        {...props}
      />,
    );
    return { ...r, fetchJobs, fetchTranscript, fetchRecordings, openUrl, copyText };
  };

  it("defaults to Overview with recent recordings + stats", async () => {
    const { lastFrame, fetchJobs, fetchRecordings, unmount } = setup();
    await flush();
    expect(fetchJobs).toHaveBeenCalled();
    expect(fetchRecordings).toHaveBeenCalledWith({ limit: 50 });
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("Recappi");
    expect(frame).toContain("recordings"); // stats bar (headline count + label)
    expect(frame).toContain("Design review"); // recordings list on the Overview
    expect(frame).toContain("n record");
    expect(frame).not.toContain("4 Record");
    unmount();
  });

  it("switches to Account with key 3 and renders account usage", async () => {
    const fetchAccountStatus = vi.fn().mockResolvedValue(accountStatus);
    const { lastFrame, stdin, unmount } = setup({ fetchAccountStatus });
    await flush();
    stdin.write("3");
    await flush();
    const frame = noAnsi(lastFrame());
    expect(fetchAccountStatus).toHaveBeenCalled();
    expect(frame).toContain("‹ Account");
    expect(frame).toContain("agent@example.com");
    expect(frame).toContain("Plan");
    expect(frame).toContain("pro");
    expect(frame).toContain("Period 20949d left");
    expect(frame).not.toContain("3 account");
    unmount();
  });

  it("jumps to the first and last rows with g/G in Overview and Jobs", async () => {
    const { lastFrame, stdin, unmount } = setup();
    await flush();

    stdin.write("G");
    await flush();
    stdin.write(ENTER);
    await flush();
    expect(noAnsi(lastFrame())).toContain("Weekly sync");

    stdin.write("1");
    await flush();
    stdin.write(DOWN);
    await flush();
    stdin.write("g");
    await flush();
    stdin.write(ENTER);
    await flush();
    expect(noAnsi(lastFrame())).toContain("Design review");

    stdin.write("2");
    await flush();
    stdin.write("G");
    await flush();
    stdin.write(ENTER);
    await flush();
    expect(noAnsi(lastFrame())).toContain("Product call");

    stdin.write("2");
    await flush();
    stdin.write(DOWN);
    await flush();
    stdin.write("g");
    await flush();
    stdin.write(ENTER);
    await flush();
    expect(noAnsi(lastFrame())).toContain("Design review");
    unmount();
  });

  it("starts and stops a local record session from the new-record setup flow", async () => {
    const stop = vi.fn().mockResolvedValue({
      origin: "https://api.recappi.com",
      userId: "u_1",
      live: false,
      sessionId: "session_1",
      state: "completed",
      artifacts: [
        {
          kind: "recording_session",
          localPath: "/tmp/recappi/session",
          metadata: { audioPath: "/tmp/recappi/session/recording.m4a" },
        },
      ],
    });
    const startLiveRecord = vi.fn().mockResolvedValue({
      source: { onEvent: () => () => {} },
      stop,
    });
    let finishTranscribe: ((value: {
      filePath: string;
      recordingId: string;
      jobId: string;
      status: string;
      origin: string;
    }) => void) | undefined;
    const transcribeRecordingArtifact = vi.fn().mockImplementation((_artifact, onEvent) => {
      onEvent?.({
        type: "progress",
        command: "upload",
        status: "uploading",
        percent: 64,
      });
      return new Promise((resolve) => {
        finishTranscribe = resolve as typeof finishTranscribe;
      });
    });
    const { lastFrame, stdin, unmount } = setup({
      startLiveRecord,
      transcribeRecordingArtifact,
    });
    await flush();
    stdin.write("n");
    await flush();
    expect(noAnsi(lastFrame())).toContain("New recording");
    stdin.write("\r");
    await flush();
    await waitFor(() => {
      expect(startLiveRecord).toHaveBeenCalledTimes(1);
      expect(startLiveRecord).toHaveBeenCalledWith(
        expect.objectContaining({
          sourceId: "system",
          includeMicrophone: true,
          sceneId: "default",
        }),
        expect.arrayContaining([expect.objectContaining({ id: "system" })]),
      );
      const frame = noAnsi(lastFrame());
      expect(frame).toContain("REC");
      expect(frame).not.toContain("Waiting for captions");
    });
    stdin.write("q");
    await flush();
    await waitFor(() => {
      expect(stop).toHaveBeenCalledTimes(1);
      expect(transcribeRecordingArtifact).toHaveBeenCalledWith(
        expect.objectContaining({ audioPath: "/tmp/recappi/session/recording.m4a" }),
        expect.any(Function),
      );
      expect(noAnsi(lastFrame())).toContain("64%");
    });
    finishTranscribe?.({
      filePath: "/tmp/recappi/session/recording.m4a",
      recordingId: "rec_new",
      jobId: "job_new",
      status: "queued",
      origin: "https://recordmeet.ing",
    });
    await flush();
    await waitFor(() => {
      expect(noAnsi(lastFrame())).toContain("Transcription queued");
    });
    unmount();
  });

  it("does not treat n as stop while a recording is active", async () => {
    const stop = vi.fn().mockResolvedValue({
      origin: "https://api.recappi.com",
      userId: "u_1",
      live: false,
      sessionId: "session_1",
      state: "completed",
      artifacts: [],
    });
    const startLiveRecord = vi.fn().mockResolvedValue({
      source: { onEvent: () => () => {} },
      stop,
    });
    const { lastFrame, stdin, unmount } = setup({ startLiveRecord });
    await flush();
    stdin.write("n");
    await flush();
    stdin.write("\r");
    await waitFor(() => {
      expect(noAnsi(lastFrame())).toContain("REC");
    });

    stdin.write("n");
    await flush();
    expect(stop).not.toHaveBeenCalled();
    expect(noAnsi(lastFrame())).toContain("REC");

    stdin.write("q");
    await waitFor(() => {
      expect(stop).toHaveBeenCalledTimes(1);
    });
    unmount();
  });

  it("does not revive a canceled starting record session", async () => {
    let resolveStart:
      | ((session: { source: { onEvent: () => () => void }; stop: () => Promise<unknown> }) => void)
      | undefined;
    const stop = vi.fn().mockResolvedValue({
      origin: "https://api.recappi.com",
      userId: "u_1",
      live: false,
      sessionId: "session_1",
      state: "completed",
      artifacts: [],
    });
    const startLiveRecord = vi.fn().mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveStart = resolve as typeof resolveStart;
        }),
    );
    const { lastFrame, stdin, unmount } = setup({ startLiveRecord });
    await flush();
    stdin.write("n");
    await flush();
    stdin.write("\r");
    await waitFor(() => {
      expect(startLiveRecord).toHaveBeenCalledTimes(1);
    });

    stdin.write("q");
    await flush();
    expect(noAnsi(lastFrame())).toContain("Design review");

    resolveStart?.({ source: { onEvent: () => () => {} }, stop });
    await flush();
    expect(noAnsi(lastFrame())).toContain("Design review");
    expect(noAnsi(lastFrame())).not.toContain("REC");
    expect(stop).not.toHaveBeenCalled();
    unmount();
  });

  it("does not revive a canceled stopping record session", async () => {
    let resolveStop: ((value: {
      origin: string;
      userId: string;
      live: boolean;
      sessionId: string;
      state: string;
      artifacts: unknown[];
    }) => void) | undefined;
    const stop = vi.fn().mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveStop = resolve as typeof resolveStop;
        }),
    );
    const startLiveRecord = vi.fn().mockResolvedValue({
      source: { onEvent: () => () => {} },
      stop,
    });
    const { lastFrame, stdin, unmount } = setup({ startLiveRecord });
    await flush();
    stdin.write("n");
    await flush();
    stdin.write("\r");
    await waitFor(() => {
      expect(noAnsi(lastFrame())).toContain("REC");
    });

    stdin.write("q");
    await waitFor(() => {
      expect(stop).toHaveBeenCalledTimes(1);
    });
    stdin.write("q");
    await flush();
    expect(noAnsi(lastFrame())).toContain("Design review");

    resolveStop?.({
      origin: "https://api.recappi.com",
      userId: "u_1",
      live: false,
      sessionId: "session_1",
      state: "completed",
      artifacts: [],
    });
    await flush();
    expect(noAnsi(lastFrame())).toContain("Design review");
    expect(noAnsi(lastFrame())).not.toContain("Saved to your Mac");
    unmount();
  });

  it("renders live caption tail in the recording hero when the session streams captions", async () => {
    let emit: ((event: unknown) => void) | undefined;
    const stop = vi.fn().mockResolvedValue({
      origin: "https://api.recappi.com",
      userId: "u_1",
      live: true,
      sessionId: "session_1",
      state: "completed",
      artifacts: [],
    });
    const startLiveRecord = vi.fn().mockResolvedValue({
      captionStreamEnabled: true,
      source: {
        onEvent: (listener: (event: never) => void) => {
          emit = (event: unknown) => listener(event as never);
          return () => {
            emit = undefined;
          };
        },
      },
      stop,
    });
    const { lastFrame, stdin, unmount } = setup({ startLiveRecord });
    await flush();
    stdin.write("n");
    await flush();
    stdin.write("\r");
    await flush();
    await waitFor(() => {
      expect(noAnsi(lastFrame())).toContain("REC");
      expect(emit).toBeDefined();
    });

    emit?.({
      type: "recording.state",
      sessionId: "session_1",
      state: "recording",
    });
    emit?.({
      type: "live_caption.delta",
      sessionId: "session_1",
      stream: "source",
      text: "hello wor",
    });
    await waitFor(() => {
      expect(noAnsi(lastFrame())).toContain("hello wor");
    });

    emit?.({
      type: "live_caption.delta",
      sessionId: "session_1",
      stream: "source",
      text: "hello world",
      isFinal: true,
      segmentId: "seg1",
      speaker: "A",
    });
    emit?.({
      type: "live_caption.delta",
      sessionId: "session_1",
      stream: "translation",
      text: "你好世界",
      isFinal: true,
      segmentId: "seg1",
    });
    await waitFor(() => {
      const frame = noAnsi(lastFrame());
      // Default "both" mode shows source + translation as labeled side-by-side
      // columns (no ↳ pairing — the streams aren't synced 1:1).
      expect(frame).toContain("A: hello world");
      expect(frame).toContain("你好世界");
      expect(frame).toContain("TRANSLATION");
    });
    unmount();
  });

  it("sanitizes stopped-record transcribe failures before rendering them", async () => {
    const stop = vi.fn().mockResolvedValue({
      origin: "https://api.recappi.com",
      userId: "u_1",
      live: false,
      sessionId: "session_1",
      state: "completed",
      artifacts: [
        {
          kind: "recording_session",
          localPath: "/tmp/recappi/session",
          metadata: { audioPath: "/tmp/recappi/session/recording.m4a" },
        },
      ],
    });
    const startLiveRecord = vi.fn().mockResolvedValue({
      source: { onEvent: () => () => {} },
      stop,
    });
    const transcribeRecordingArtifact = vi
      .fn()
      .mockRejectedValue(
        new Error("uploadPathBatch failed at /Users/private/recording.m4a\nstack: internal"),
      );
    const { lastFrame, stdin, unmount } = setup({
      startLiveRecord,
      transcribeRecordingArtifact,
    });
    await flush();
    stdin.write("n");
    await flush();
    stdin.write("\r");
    await flush();
    stdin.write("q");
    await flush();
    await waitFor(() => {
      expect(noAnsi(lastFrame())).toContain("Saved to your Mac");
    });
    stdin.write("\r");
    await flush();
    await waitFor(() => {
      const frame = noAnsi(lastFrame());
      expect(frame).toContain("Transcription failed · ⏎ retry");
      expect(frame).toContain("Could not start transcription. Please try again.");
      expect(frame).not.toContain("/Users/private");
      expect(frame).not.toContain("uploadPathBatch");
      expect(frame).not.toContain("stack");
    });
    unmount();
  });

  it("uses helper-listed app sources and microphone devices in record setup", async () => {
    const stop = vi.fn().mockResolvedValue({
      origin: "https://api.recappi.com",
      userId: "u_1",
      live: false,
      sessionId: "session_1",
      state: "completed",
      artifacts: [],
    });
    const startLiveRecord = vi.fn().mockResolvedValue({
      source: { onEvent: () => () => {} },
      stop,
    });
    const fetchRecordSetup = vi.fn().mockResolvedValue({
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
      microphones: [
        { id: "mic_default", label: "MacBook Pro Microphone", isDefault: true },
        { id: "mic_usb", label: "USB Mic" },
      ],
    });

    const { lastFrame, stdin, unmount } = setup({ fetchRecordSetup, startLiveRecord });
    await flush();
    stdin.write("n");
    await waitFor(() => {
      expect(fetchRecordSetup).toHaveBeenCalled();
      expect(noAnsi(lastFrame())).toContain("Safari");
    });
    stdin.write(DOWN); // down: Safari
    await flush();
    stdin.write("m"); // USB Mic
    await flush();
    stdin.write("\r");
    await flush();

    await waitFor(() => {
      expect(startLiveRecord).toHaveBeenCalledWith(
        expect.objectContaining({
          sourceId: "app:com.apple.Safari",
          includeMicrophone: true,
          microphoneDeviceId: "mic_usb",
        }),
        expect.arrayContaining([
          expect.objectContaining({ bundleId: "com.apple.Safari", label: "Safari" }),
        ]),
      );
    });
    unmount();
  });

  it("streams setup preview levels for the selected source and microphone", async () => {
    const fetchRecordSetup = vi.fn().mockResolvedValue({
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
      microphones: [{ id: "mic_default", label: "MacBook Pro Microphone", isDefault: true }],
    });
    const previewSubscriptions: Array<{ sourceId: string; listener: (event: SidecarEvent) => void }> =
      [];
    const stopPreview = vi.fn();
    const startRecordSetupPreview = vi
      .fn()
      .mockImplementation(async (selection: { sourceId?: string }) => ({
        source: {
          onEvent: (listener: (event: SidecarEvent) => void) => {
            previewSubscriptions.push({ sourceId: selection.sourceId ?? "", listener });
            return () => {};
          },
        },
        stop: stopPreview,
      }));
    const waitForPreviewListener = async (sourceId: string) => {
      await waitFor(() => {
        expect(previewSubscriptions.some((subscription) => subscription.sourceId === sourceId)).toBe(
          true,
        );
      });
      for (let index = previewSubscriptions.length - 1; index >= 0; index -= 1) {
        const subscription = previewSubscriptions[index]!;
        if (subscription.sourceId === sourceId) return subscription.listener;
      }
      throw new Error(`missing preview listener for ${sourceId}`);
    };

    const { lastFrame, stdin, unmount } = setup({ fetchRecordSetup, startRecordSetupPreview });
    await flush();
    stdin.write("n");
    await waitFor(() => {
      expect(noAnsi(lastFrame())).toContain("Safari");
      expect(startRecordSetupPreview).toHaveBeenCalledWith(
        expect.objectContaining({
          sourceId: "system",
          includeMicrophone: true,
          microphoneDeviceId: "mic_default",
        }),
        expect.arrayContaining([expect.objectContaining({ bundleId: "com.apple.Safari" })]),
      );
    });

    const systemPreview = await waitForPreviewListener("system");
    systemPreview({
      type: "audio.level",
      previewId: "preview_1",
      input: "system",
      sourceId: "system",
      rmsDb: -18,
      atMs: 120,
    });
    systemPreview({
      type: "audio.level",
      previewId: "preview_1",
      input: "microphone",
      rmsDb: -60,
      atMs: 120,
    });
    await waitFor(() => {
      const frame = noAnsi(lastFrame());
      expect(frame).toContain("-18 dB");
      expect(frame).toContain("silent");
    });

    stdin.write(DOWN);
    await waitFor(() => {
      expect(startRecordSetupPreview).toHaveBeenCalledWith(
        expect.objectContaining({ sourceId: "app:com.apple.Safari" }),
        expect.arrayContaining([expect.objectContaining({ bundleId: "com.apple.Safari" })]),
      );
    });
    const safariPreview = await waitForPreviewListener("app:com.apple.Safari");
    safariPreview({
      type: "audio.level",
      previewId: "preview_2",
      input: "system",
      sourceId: "app:com.apple.Safari",
      rmsDb: -12,
      atMs: 180,
    });
    await waitFor(() => {
      expect(noAnsi(lastFrame())).toContain("-12 dB");
    });
    unmount();
  });

  it("fetches the next recordings page when Overview scrolls near the loaded end", async () => {
    const pageOne: RecordingListData = {
      items: Array.from({ length: 20 }, (_, index) =>
        rec({
          recordingId: `rec_${index + 1}`,
          title: `Recording ${index + 1}`,
          activeTranscriptId: null,
        }),
      ),
      limit: 50,
      nextCursor: "cursor_2",
      totalCount: 21,
      origin: "https://recordmeet.ing",
    };
    const pageTwo: RecordingListData = {
      items: [rec({ recordingId: "rec_21", title: "Recording 21", activeTranscriptId: null })],
      limit: 50,
      nextCursor: null,
      totalCount: 21,
      origin: "https://recordmeet.ing",
    };
    const fetchJobs = vi.fn().mockResolvedValue(jobData);
    const fetchTranscript = vi.fn().mockResolvedValue(transcript);
    const fetchRecordings = vi.fn().mockResolvedValueOnce(pageOne).mockResolvedValueOnce(pageTwo);
    const r = render(
      <AppShell
        fetchJobs={fetchJobs}
        fetchTranscript={fetchTranscript}
        fetchRecordings={fetchRecordings}
        now={() => 1000}
        pollMs={10_000}
        spinnerMs={10_000}
      />,
    );
    await flush();
    expect(fetchRecordings).toHaveBeenCalledTimes(1);
    expect(fetchRecordings).toHaveBeenCalledWith({ limit: 50 });

    for (let i = 0; i < 12; i += 1) r.stdin.write(DOWN);
    await flush();

    await waitFor(() => {
      expect(fetchRecordings).toHaveBeenCalledTimes(2);
      expect(fetchRecordings).toHaveBeenLastCalledWith({ limit: 50, cursor: "cursor_2" });
    });
    r.unmount();
  });

  it("drills into a recording detail from the Overview list", async () => {
    const { lastFrame, stdin, unmount } = setup();
    await flush();
    expect(noAnsi(lastFrame())).toContain("Design review"); // recordings list on Overview
    stdin.write(ENTER); // first recording -> detail
    await flush();
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("‹ Recordings");
    expect(frame).toContain("o open");
    unmount();
  });

  it("switches to Jobs with key 2 and drills into a job with enter", async () => {
    const { lastFrame, stdin, unmount } = setup();
    await flush();
    stdin.write("2");
    await flush();
    expect(noAnsi(lastFrame())).toContain("Design review");
    stdin.write(ENTER); // first job selected -> detail
    await flush();
    expect(noAnsi(lastFrame())).toContain("‹ Jobs /");
    unmount();
  });

  it("opens transcript and the web link from job detail", async () => {
    const { lastFrame, stdin, openUrl, fetchTranscript, unmount } = setup();
    await flush();
    stdin.write("2"); // jobs
    await flush();
    stdin.write(DOWN); // select Product call (has transcriptId)
    await flush();
    stdin.write(ENTER); // job detail
    await flush();
    stdin.write("o"); // open web
    expect(openUrl).toHaveBeenCalledWith("https://recordmeet.ing/recordings/rec_2?job=job_2");
    stdin.write("t"); // open transcript
    await flush();
    expect(fetchTranscript).toHaveBeenCalledWith("tr_2");
    expect(noAnsi(lastFrame())).toContain("Peng:");
    unmount();
  });

  it("handles q without throwing", async () => {
    const { stdin, unmount } = setup();
    await flush();
    expect(() => stdin.write("q")).not.toThrow();
    await flush();
    unmount();
  });
});
