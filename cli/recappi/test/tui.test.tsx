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
import { RecordingScreen } from "../src/tui/RecordingScreen";
import { RecordSetupView } from "../src/tui/RecordSetupView";
import { RecordingHeroScreen } from "../src/tui/RecordingHeroScreen";
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
  type AppShellProps,
} from "../src/tui/AppShell";
import { DASHBOARD_RENDER_OPTIONS, runDashboard, type RunDashboardDeps } from "../src/tui";
import type {
  AccountStatusData,
  JobListData,
  JobListItem,
  RecordingData,
  RecordingListData,
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
    expect(captureUnavailable.title).toContain("ready");
    expect(captureUnavailable.detail).toContain("Use the Recappi Mini app");
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
    expect(frame).toContain("Recordings"); // stats bar
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
  it("RecordSetupView lists sources, toggles mic, and starts with the selection", async () => {
    const onStart = vi.fn();
    const onCancel = vi.fn();
    const model = {
      sources: [
        { id: "sys", kind: "system" as const, label: "System audio" },
        { id: "app1", kind: "app" as const, label: "Google Meet — Arc", appName: "Arc" },
        { id: "mic", kind: "microphone" as const, label: "Microphone only" },
      ],
      scenes: [{ id: "default", label: "Default" }],
      previewLevel: 0.5,
    };
    const { lastFrame, stdin } = render(
      <RecordSetupView model={model} onStart={onStart} onCancel={onCancel} />,
    );
    await flush();
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("New recording");
    expect(frame).toContain("System audio");
    expect(frame).toContain("Google Meet — Arc");
    expect(frame).toContain("include mic"); // system source → mic toggle shown
    // move to mic-only source → mic toggle becomes "Microphone is the source"
    stdin.write("[B"); // down → app
    stdin.write("[B"); // down → microphone only
    await flush();
    expect(noAnsi(lastFrame())).toContain("Microphone is the source");
    // back up to system + start
    stdin.write("[A");
    stdin.write("[A");
    await flush();
    stdin.write("\r"); // start
    await flush();
    expect(onStart).toHaveBeenCalledWith(
      expect.objectContaining({ sourceId: "sys", sceneId: "default" }),
    );
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
    // Transcribe handoff isn't wired yet, so the stopped screen must not dangle a
    // "Transcribe now? ⏎ yes" that no-ops — honest "coming soon" copy instead.
    expect(sf).toContain("Transcription handoff coming soon");
    expect(sf).not.toContain("Transcribe now");
  });
  it("RecordingScreen shows local recording status, not captions waiting copy", async () => {
    let emit: (e: unknown) => void = () => {};
    const source = {
      onEvent(listener: (e: unknown) => void) {
        emit = listener;
        return () => {};
      },
    };
    const { lastFrame } = render(<RecordingScreen source={source as never} now={() => 0} />);
    await flush();
    expect(noAnsi(lastFrame())).toContain("Starting recording");
    emit({ type: "recording.state", sessionId: "s", state: "recording" });
    await flush();
    const frame = noAnsi(lastFrame());
    expect(frame).toContain("Recording");
    expect(frame).toContain("q to stop");
    expect(frame).not.toContain("Waiting for captions");
    emit({ type: "recording.state", sessionId: "s", state: "completed" });
    await flush();
    expect(noAnsi(lastFrame())).toContain("saved");
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
      sidecarToLiveCaptionEvent({ type: "error", code: "E", message: "stream dropped" } as never),
    ).toEqual({ kind: "error", message: "stream dropped" });
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
    expect(frame).toContain("Recordings"); // stats bar
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
    const { lastFrame, stdin, unmount } = setup({ startLiveRecord });
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
      );
      const frame = noAnsi(lastFrame());
      expect(frame).toContain("REC");
      expect(frame).not.toContain("Waiting for captions");
    });
    stdin.write("q");
    await flush();
    await waitFor(() => {
      expect(stop).toHaveBeenCalledTimes(1);
      expect(noAnsi(lastFrame())).toContain("Saved to your Mac");
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
