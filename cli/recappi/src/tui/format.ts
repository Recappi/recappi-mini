import type { JobListItem } from "../../../packages/contracts/src/index";

// Pure presentation helpers for the Ink dashboard, kept separate from the
// React components so they can be unit-tested without rendering.

// milliseconds -> mm:ss, widening to h:mm:ss past the hour. "--:--" when unknown.
export function formatClockMs(ms: number | null | undefined): string {
  if (ms == null || !Number.isFinite(ms) || ms < 0) return "--:--";
  const total = Math.floor(ms / 1000);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  const mm = String(minutes).padStart(2, "0");
  const ss = String(secs).padStart(2, "0");
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
}

export function progressBar(fraction: number, width = 10): string {
  const clamped = Math.max(0, Math.min(1, fraction));
  const filled = Math.round(clamped * width);
  return `[${"█".repeat(filled)}${"░".repeat(width - filled)}]`;
}

// Real transcription progress = processed audio / total audio. Returns null when
// we lack a total duration — callers must NOT fake a percentage in that case,
// they fall back to a spinner + elapsed.
export function transcribeFraction(item: JobListItem): number | null {
  const total = item.recording?.durationMs;
  const done = item.processedDurationMs;
  if (!total || total <= 0 || done == null) return null;
  return Math.max(0, Math.min(1, done / total));
}

// A running job whose worker lease has expired is dead, not progressing — its
// heartbeat stopped. We surface that as "stalled" so the UI stops implying live
// progress (an endless spinner) and points the user at a retry.
export function isJobStalled(item: JobListItem, nowMs: number): boolean {
  return (
    item.status === "running" &&
    typeof item.claimExpiresAt === "number" &&
    item.claimExpiresAt < nowMs
  );
}

export function effectiveJobStatus(item: JobListItem, nowMs: number): string {
  return isJobStalled(item, nowMs) ? "stalled" : item.status;
}

export interface StatusStyle {
  label: string;
  color: string;
}

export function statusStyle(status: string): StatusStyle {
  switch (status) {
    case "running":
      return { label: "Transcribing", color: "cyan" };
    case "queued":
      return { label: "Queued", color: "yellow" };
    case "succeeded":
      return { label: "Ready", color: "green" };
    case "failed":
      return { label: "Failed", color: "red" };
    case "stalled":
      return { label: "Stalled", color: "yellow" };
    default:
      return { label: status, color: "gray" };
  }
}

const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

export function spinnerChar(frame: number): string {
  return SPINNER_FRAMES[frame % SPINNER_FRAMES.length]!;
}

// Calendar-day bucket for grouping recordings, like the macOS app's sections.
export function dateBucket(epochMs: number | null | undefined, nowMs: number): string {
  if (!epochMs) return "Earlier";
  const startOfDay = (ms: number) => {
    const d = new Date(ms);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  };
  const days = Math.floor((startOfDay(nowMs) - startOfDay(epochMs)) / 86_400_000);
  if (days <= 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 7) return "Previous 7 days";
  if (days < 30) return "Previous 30 days";
  return "Earlier";
}

// Status glyph. Running animates via the spinner frame; everything else is a
// stable symbol so the row doesn't flicker.
export function statusGlyph(status: string, spinnerFrame: number): string {
  switch (status) {
    case "running":
      return SPINNER_FRAMES[spinnerFrame % SPINNER_FRAMES.length]!;
    case "queued":
      // Single-width glyph — wide emoji (⏳) misaligns the status column.
      return "○";
    case "succeeded":
      return "✓";
    case "failed":
      return "✗";
    case "stalled":
      // Single-width, non-emoji so the status column stays aligned.
      return "!";
    default:
      return "•";
  }
}

// The right-hand detail column: a real progress bar for running jobs (when we
// have a duration), otherwise a short status word. Pass nowMs so a running job
// whose lease expired reads as stalled (retryable) instead of "transcribing…".
export function jobDetail(item: JobListItem, nowMs?: number): string {
  if (nowMs != null && isJobStalled(item, nowMs)) return "stalled — worker lost · T retry";
  if (item.status === "running") {
    const fraction = transcribeFraction(item);
    if (fraction != null) {
      const pct = Math.round(fraction * 100);
      return `${progressBar(fraction)} ${String(pct).padStart(3)}%  ${formatClockMs(
        item.processedDurationMs,
      )} / ${formatClockMs(item.recording?.durationMs)}`;
    }
    return "transcribing…";
  }
  if (item.status === "succeeded") return item.transcriptId ? "transcript ready" : "done";
  if (item.status === "queued") return "queued";
  if (item.status === "failed") return "failed";
  return "";
}

export function padCell(text: string, width: number): string {
  if (text.length > width) return `${text.slice(0, Math.max(0, width - 1))}…`;
  return text.padEnd(width);
}

// Display width of a single code point: CJK / fullwidth / emoji count as 2
// terminal cells, everything else as 1. Covers the common wide ranges — enough
// for recording titles (Chinese/Japanese/Korean + emoji).
function charWidth(code: number): number {
  if (
    (code >= 0x1100 && code <= 0x115f) || // Hangul Jamo
    code === 0x2329 ||
    code === 0x232a ||
    (code >= 0x2e80 && code <= 0x303e) || // CJK radicals … Kangxi
    (code >= 0x3041 && code <= 0x33ff) || // Hiragana … CJK symbols
    (code >= 0x3400 && code <= 0x4dbf) || // CJK ext A
    (code >= 0x4e00 && code <= 0x9fff) || // CJK unified
    (code >= 0xa000 && code <= 0xa4cf) || // Yi
    (code >= 0xac00 && code <= 0xd7a3) || // Hangul syllables
    (code >= 0xf900 && code <= 0xfaff) || // CJK compat
    (code >= 0xfe30 && code <= 0xfe4f) || // CJK compat forms
    (code >= 0xff00 && code <= 0xff60) || // Fullwidth forms
    (code >= 0xffe0 && code <= 0xffe6) ||
    (code >= 0x1f300 && code <= 0x1faff) || // emoji
    (code >= 0x20000 && code <= 0x3fffd) // CJK ext B+
  ) {
    return 2;
  }
  return 1;
}

export function displayWidth(text: string): number {
  let width = 0;
  for (const ch of text) width += charWidth(ch.codePointAt(0) ?? 0);
  return width;
}

// Pad/truncate to an exact DISPLAY width (terminal cells), so columns line up
// even with double-width CJK/emoji — Ink's <Box width> truncation does not.
export function padDisplay(text: string, width: number): string {
  const w = displayWidth(text);
  if (w === width) return text;
  if (w < width) return text + " ".repeat(width - w);
  // Too wide: truncate to width-1 cells, then append an ellipsis.
  let out = "";
  let acc = 0;
  for (const ch of text) {
    const cw = charWidth(ch.codePointAt(0) ?? 0);
    if (acc + cw > width - 1) break;
    out += ch;
    acc += cw;
  }
  out += "…";
  acc += 1;
  if (acc < width) out += " ".repeat(width - acc);
  return out;
}

export interface JobCounts {
  total: number;
  active: number;
  queued: number;
  running: number;
  succeeded: number;
  failed: number;
}

export function countJobs(items: JobListItem[]): JobCounts {
  const counts: JobCounts = {
    total: items.length,
    active: 0,
    queued: 0,
    running: 0,
    succeeded: 0,
    failed: 0,
  };
  for (const item of items) {
    if (item.status === "queued") counts.queued += 1;
    else if (item.status === "running") counts.running += 1;
    else if (item.status === "succeeded") counts.succeeded += 1;
    else if (item.status === "failed") counts.failed += 1;
  }
  counts.active = counts.running + counts.queued;
  return counts;
}

// Coarse relative time for list/overview columns. nowMs is injected so it's
// deterministic in tests.
export function formatAge(epochMs: number | null | undefined, nowMs: number): string {
  if (!epochMs) return "";
  const diff = Math.max(0, nowMs - epochMs);
  const days = Math.floor(diff / 86_400_000);
  const hours = Math.floor(diff / 3_600_000);
  const minutes = Math.floor(diff / 60_000);
  if (days > 0) return `${days}d ago`;
  if (hours > 0) return `${hours}h ago`;
  if (minutes > 0) return `${minutes}m ago`;
  return "just now";
}

export interface ResolvedLinks {
  webUrl?: string;
  macosDeeplink?: string;
}

// Prefer links from the contract (Mini's lane). v1 fallback: build the web URL
// from origin + ids using the agreed shape, so open/copy works before the
// contract carries `links`. Once the API provides links, that wins.
export function resolveJobLinks(item: JobListItem, origin: string): ResolvedLinks {
  const provided = (item as { links?: ResolvedLinks }).links;
  if (provided?.webUrl) return provided;
  if (item.recordingId) {
    return { webUrl: `${origin}/recordings/${item.recordingId}?job=${item.jobId}` };
  }
  return {};
}

export function resolveRecordingLinks(recordingId: string, origin: string): ResolvedLinks {
  if (!recordingId) return {};
  return { webUrl: `${origin}/recordings/${recordingId}` };
}

// Recording status styling. Mirrors job styling so the two surfaces feel like
// one app.
export function recordingStatusStyle(status: string): {
  label: string;
  color: string;
  glyph: string;
} {
  switch (status) {
    case "ready":
      return { label: "Ready", color: "green", glyph: "✓" };
    case "uploading":
      return { label: "Uploading", color: "cyan", glyph: "↑" };
    case "failed":
      return { label: "Failed", color: "red", glyph: "✗" };
    case "aborted":
      return { label: "Aborted", color: "gray", glyph: "•" };
    default:
      return { label: status, color: "gray", glyph: "•" };
  }
}

// Window a list to the visible viewport, keeping the selected row in view.
// Returns the [start, end) slice bounds. Pure, so it's unit-testable.
export function listWindow(
  selected: number,
  total: number,
  size: number,
): { start: number; end: number } {
  if (size <= 0 || total <= 0) return { start: 0, end: 0 };
  if (total <= size) return { start: 0, end: total };
  let start = selected - Math.floor(size / 2);
  start = Math.max(0, Math.min(start, total - size));
  return { start, end: start + size };
}

// A scroll window over items of varying rendered height (e.g. transcript
// segments that wrap to multiple terminal lines). `heights[i]` is item i's row
// count; `scroll` is the desired top item index; `budget` is the visible rows.
// Returns the slice [start, end) that fits, clamping `scroll` to `maxScroll` (the
// top index that still shows the last item) so the tail is always reachable.
export function windowByHeights(
  heights: number[],
  scroll: number,
  budget: number,
): { start: number; end: number; maxScroll: number } {
  const n = heights.length;
  if (n === 0 || budget <= 0) return { start: 0, end: 0, maxScroll: 0 };

  // maxScroll: the smallest top index whose tail [top, n) still fits the budget.
  let acc = 0;
  let maxScroll = 0;
  for (let i = n - 1; i >= 0; i--) {
    acc += Math.max(1, heights[i]!);
    if (acc > budget) {
      maxScroll = i + 1;
      break;
    }
  }

  const start = Math.max(0, Math.min(scroll, maxScroll));
  let used = 0;
  let end = start;
  for (let i = start; i < n; i++) {
    const h = Math.max(1, heights[i]!);
    if (used + h > budget && end > start) break; // always show at least one
    used += h;
    end = i + 1;
  }
  return { start, end, maxScroll };
}

// Like listWindow, but accounts for the date-group headers (and the blank line
// before each non-leading group) that RecordingsView renders. `buckets[i]` is
// the date-group label for item i. `budget` is the number of terminal lines the
// list body may occupy. Returns the widest window around `selected` whose
// rendered height (rows + headers + inter-group spacing) fits the budget, so the
// frame never overflows the screen (which would scroll/ghost the alternate
// screen and make a group header look selected).
export function groupedListWindow(
  buckets: string[],
  selected: number,
  budget: number,
): { start: number; end: number } {
  const total = buckets.length;
  if (budget <= 0 || total <= 0) return { start: 0, end: 0 };
  const cost = (start: number, end: number): number => {
    if (end <= start) return 0;
    let boundaries = 0; // group changes strictly inside the slice
    for (let i = start + 1; i < end; i++) {
      if (buckets[i] !== buckets[i - 1]) boundaries += 1;
    }
    // rows + the leading group header + (header + blank) per inner group change
    return end - start + 1 + boundaries * 2;
  };
  for (let n = Math.min(total, budget); n >= 1; n--) {
    const win = listWindow(selected, total, n);
    if (cost(win.start, win.end) <= budget) return win;
  }
  return listWindow(selected, total, 1);
}

// Short, human file size. Empty string when unknown.
export function formatBytes(bytes: number | null | undefined): string {
  if (bytes == null || !Number.isFinite(bytes) || bytes < 0) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const rounded = value < 10 && unit > 0 ? value.toFixed(1) : String(Math.round(value));
  return `${rounded}${units[unit]}`;
}
