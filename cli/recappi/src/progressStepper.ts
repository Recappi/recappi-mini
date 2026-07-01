import type { OperationEvent } from "../../packages/contracts/src/index";

// Productized upload+transcribe progress: a 4-step pipeline (Check → Upload →
// Transcribe → Done) with a per-step progress bar / spinner, so the user always
// sees where the whole flow is AND how far the current step has gone — instead
// of a single opaque "Transcribing…" line. Pure state + formatting here; the
// terminal redraw (cursor moves, color) lives in render.ts and is TTY-only.

export type StepStatus = "pending" | "active" | "done" | "failed" | "skipped";

export interface StepperStep {
  key: string;
  label: string;
  status: StepStatus;
  detail: string;
  percent?: number;
}

export interface StepperModel {
  steps: StepperStep[];
  transcribeStartMs?: number;
  finished: boolean;
}

const STEP_DEFS: { key: string; label: string }[] = [
  { key: "check", label: "Check" },
  { key: "upload", label: "Upload" },
  { key: "transcribe", label: "Transcribe" },
  { key: "done", label: "Done" },
];

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const BAR_WIDTH = 16;
const LABEL_WIDTH = 11;

export function createStepperModel(): StepperModel {
  return {
    steps: STEP_DEFS.map((d) => ({ ...d, status: "pending", detail: "" })),
    finished: false,
  };
}

// Whether an upload event should drive the stepper (vs the legacy single line).
export function isStepperEvent(event: OperationEvent): boolean {
  if (event.command !== "upload") return false;
  if (event.type === "started") return true;
  return typeof event.status === "string";
}

function cloneModel(model: StepperModel): StepperModel {
  return {
    steps: model.steps.map((s) => ({ ...s })),
    ...(model.transcribeStartMs != null ? { transcribeStartMs: model.transcribeStartMs } : {}),
    finished: model.finished,
  };
}

// Fold one operation event into the stepper. Returns a new model; never mutates.
export function applyStepperEvent(
  model: StepperModel,
  event: OperationEvent,
  nowMs: number,
): StepperModel {
  const next = cloneModel(model);
  const step = (key: string): StepperStep => next.steps.find((s) => s.key === key)!;
  const markDone = (key: string): void => {
    const s = step(key);
    if (s.status !== "failed") {
      s.status = "done";
      s.percent = undefined;
    }
  };
  const startTranscribeClock = (): void => {
    if (next.transcribeStartMs == null) next.transcribeStartMs = nowMs;
  };

  switch (event.status) {
    case "checking_audio":
      step("check").status = "active";
      break;
    case "starting_upload": {
      markDone("check");
      const file = fileFromEvent(event);
      if (file) step("check").detail = file;
      step("upload").status = "active";
      step("upload").detail = "Starting…";
      break;
    }
    case "uploading":
      step("upload").status = "active";
      step("upload").detail = "";
      if (typeof event.percent === "number") step("upload").percent = event.percent;
      break;
    case "finishing_upload":
      step("upload").status = "active";
      step("upload").detail = "Finalizing";
      step("upload").percent = 100;
      break;
    case "uploaded":
      markDone("upload");
      step("upload").detail = recordingUrl(event) ?? "Uploaded";
      break;
    case "starting_transcription":
      step("transcribe").status = "active";
      step("transcribe").detail = "Starting…";
      startTranscribeClock();
      break;
    case "queued":
      step("transcribe").status = "active";
      step("transcribe").detail = "Queued";
      startTranscribeClock();
      break;
    case "running":
      step("transcribe").status = "active";
      startTranscribeClock();
      if (typeof event.percent === "number") {
        step("transcribe").percent = event.percent;
        step("transcribe").detail = "";
      } else {
        step("transcribe").percent = undefined;
        step("transcribe").detail = "Transcribing…";
      }
      break;
    case "succeeded":
      markDone("transcribe");
      markDone("done");
      if (event.transcriptId) {
        step("done").detail = `→ recappi transcript get ${event.transcriptId}`;
      }
      next.finished = true;
      break;
    case "failed":
      markActiveFailed(next, event.message);
      break;
    default:
      if (event.type === "started") step("check").status = "active";
      break;
  }
  return next;
}

// Mark the currently-running step as failed (used by both a failed event and the
// terminal renderFailure path, which carries the human error message).
export function markStepperFailed(model: StepperModel, message?: string): StepperModel {
  const next = cloneModel(model);
  markActiveFailed(next, message);
  return next;
}

// Finalize a successful run: any step still active/pending becomes done (an
// upload-only run never starts Transcribe, so it's marked skipped), and Done
// gets the next-command / recording pointer.
export function completeStepperModel(
  model: StepperModel,
  next?: { transcriptId?: string; recordingId?: string },
): StepperModel {
  const m = cloneModel(model);
  const transcribe = m.steps.find((s) => s.key === "transcribe")!;
  if (transcribe.status === "pending") {
    transcribe.status = "skipped";
    transcribe.detail = "no --transcribe";
  }
  for (const s of m.steps) {
    if (s.status === "active" || s.status === "pending") s.status = "done";
    s.percent = undefined;
  }
  const done = m.steps.find((s) => s.key === "done")!;
  if (next?.transcriptId) done.detail = `→ recappi transcript get ${next.transcriptId}`;
  else if (next?.recordingId) done.detail = `→ recappi recordings get ${next.recordingId}`;
  m.finished = true;
  return m;
}

function markActiveFailed(model: StepperModel, message?: string): void {
  const active = model.steps.find((s) => s.status === "active");
  const target = active ?? model.steps.find((s) => s.status === "pending");
  if (target) {
    target.status = "failed";
    if (message) target.detail = message;
  }
  model.finished = true;
}

// Render the stepper to display lines. `color` gates ANSI so tests can assert
// plain text; the terminal path passes color=true.
export function formatStepperLines(
  model: StepperModel,
  nowMs: number,
  spinnerFrame: number,
  color: boolean,
): string[] {
  return model.steps.map((s) => {
    const marker = markerFor(s, spinnerFrame);
    const label = s.label.padEnd(LABEL_WIDTH);
    let detail = s.detail;
    if (s.status === "active" && typeof s.percent === "number") {
      detail = `${progressBar(s.percent)}  ${clampPercent(s.percent)}%`;
    }
    if (s.key === "transcribe" && s.status === "active" && model.transcribeStartMs != null) {
      const elapsed = formatElapsed(Math.max(0, nowMs - model.transcribeStartMs));
      detail = detail ? `${detail} · ${elapsed}` : elapsed;
    }
    const body = `  ${marker}  ${label}${detail}`.trimEnd();
    return color ? colorize(s.status, marker, body) : body;
  });
}

function markerFor(step: StepperStep, spinnerFrame: number): string {
  switch (step.status) {
    case "done":
      return "✓";
    case "failed":
      return "✗";
    case "active":
      return SPINNER[spinnerFrame % SPINNER.length]!;
    case "skipped":
      return "·";
    default:
      return "○";
  }
}

// Color only the marker glyph, so the line text stays readable and copy-safe.
function colorize(status: StepStatus, marker: string, line: string): string {
  const code =
    status === "done"
      ? "32" // green
      : status === "failed"
        ? "31" // red
        : status === "active"
          ? "36" // cyan
          : "90"; // dim/grey
  const colored = `\x1b[${code}m${marker}\x1b[0m`;
  return line.replace(marker, colored);
}

function progressBar(percent: number): string {
  const p = clampPercent(percent);
  const filled = Math.round((p / 100) * BAR_WIDTH);
  return "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled);
}

function clampPercent(percent: number): number {
  return Math.max(0, Math.min(100, Math.round(percent)));
}

function fileFromEvent(event: OperationEvent): string | undefined {
  const data = event.data;
  if (!data || typeof data !== "object") return undefined;
  const file = (data as { file?: unknown }).file;
  if (!file || typeof file !== "object") return undefined;
  const f = file as { title?: unknown; sizeBytes?: unknown; durationMs?: unknown };
  const parts: string[] = [];
  if (typeof f.title === "string" && f.title) parts.push(f.title);
  if (typeof f.sizeBytes === "number") parts.push(formatBytes(f.sizeBytes));
  if (typeof f.durationMs === "number") parts.push(formatMediaDuration(f.durationMs));
  return parts.length ? parts.join(" · ") : undefined;
}

function recordingUrl(event: OperationEvent): string | undefined {
  if (typeof event.message === "string" && event.message.includes("/recordings/")) {
    // "Uploaded · <url>" — keep just the URL for the Upload step detail.
    const idx = event.message.indexOf("http");
    if (idx >= 0) return event.message.slice(idx);
  }
  if (event.origin && event.recordingId) {
    return `${event.origin.replace(/\/+$/, "")}/recordings/${event.recordingId}`;
  }
  return undefined;
}

function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${bytes} B`;
}

function formatMediaDuration(ms: number): string {
  const totalSec = Math.round(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${m}:${String(s).padStart(2, "0")}`;
}

function formatElapsed(ms: number): string {
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  const clock =
    h > 0
      ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
      : `${m}:${String(s).padStart(2, "0")}`;
  return `${clock} elapsed`;
}
