import React from "react";
import { Box, Text } from "ink";
import type { RecordingData } from "../../../packages/contracts/src/index";
import { formatAge, formatClockMs, spinnerChar } from "./format";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Friendly title: never show a raw UUID — untitled recordings read "Untitled".
export function recordingTitle(item: RecordingData): string {
  const named = (item.title || item.summaryTitle || "").trim();
  if (named && !UUID_RE.test(named)) return named;
  return "Untitled";
}

// Processing state glyph, derived from the recording status + its active job (a
// running/queued job means it's transcribing/queued). Ready rows stay low-noise
// (calm green ✓); anything in-flight or failed stands out with color/animation.
export function recordingProcessingState(
  item: RecordingData,
  jobStatus: string | undefined,
  spinnerFrame: number,
): { glyph: string; color: string } {
  if (item.status === "uploading") return { glyph: "↑", color: "cyan" };
  if (item.status === "failed" || jobStatus === "failed") return { glyph: "✗", color: "red" };
  if (jobStatus === "stalled") return { glyph: "!", color: "yellow" };
  if (jobStatus === "running") return { glyph: spinnerChar(spinnerFrame), color: "cyan" };
  if (jobStatus === "queued") return { glyph: "○", color: "yellow" };
  if (item.status === "aborted") return { glyph: "•", color: "gray" };
  if (item.activeTranscriptId) return { glyph: "✓", color: "green" };
  return { glyph: "·", color: "gray" }; // ready, no transcript yet
}

const MARKER_W = 3;
const GLYPH_W = 2;
const LENGTH_W = 8;
const WHEN_W = 9;
const DL_W = 3;

// Responsive column layout: fixed columns take their minimum, the title flexes
// to fill the rest, and WHEN is dropped on narrow terminals. Widths are display
// cells (CJK/emoji aware) so columns line up. `columns` is the terminal width.
export interface RecordingLayout {
  title: number;
  showWhen: boolean;
}
export function recordingLayout(columns: number): RecordingLayout {
  const usable = Math.max(20, columns - 2); // AppShell pads x by 1 on each side
  const showWhen = usable >= 54;
  const title = Math.max(
    10,
    usable - MARKER_W - GLYPH_W - LENGTH_W - (showWhen ? WHEN_W : 0) - DL_W,
  );
  return { title, showWhen };
}

// One recording row. Laid out with fixed-width Box columns (not string padding
// + trailing spaces in adjacent <Text>, which Ink collapses inconsistently at
// different widths) so the marker · glyph · title · length · when · download
// columns line up identically at every terminal size. Color is semantic:
// cyan marker = selection, status glyph carries its own meaning-color, the
// download mark is green (offline-available), everything else dim.
export function RecordingRow({
  item,
  selected,
  nowMs,
  columns,
  jobStatus,
  spinnerFrame = 0,
  downloaded = false,
}: {
  item: RecordingData;
  selected: boolean;
  nowMs: number;
  columns: number;
  jobStatus?: string;
  spinnerFrame?: number;
  downloaded?: boolean;
}): React.ReactElement {
  const { title, showWhen } = recordingLayout(columns);
  const { glyph, color } = recordingProcessingState(item, jobStatus, spinnerFrame);
  const duration = item.durationMs ? formatClockMs(item.durationMs) : "—";
  return (
    <Box>
      <Box width={MARKER_W}><Text color="cyan">{selected ? "▸" : ""}</Text></Box>
      <Box width={GLYPH_W}><Text color={color}>{glyph}</Text></Box>
      <Box width={title}><Text bold={selected} wrap="truncate-end">{recordingTitle(item)}</Text></Box>
      <Box width={LENGTH_W} justifyContent="flex-end"><Text dimColor>{duration}</Text></Box>
      {showWhen ? (
        <Box width={WHEN_W} justifyContent="flex-end"><Text dimColor>{formatAge(item.createdAt, nowMs)}</Text></Box>
      ) : null}
      {/* Offline-available marker; constant-width column keeps rows aligned. */}
      <Box width={DL_W} justifyContent="flex-end"><Text color="green">{downloaded ? "⤓" : ""}</Text></Box>
    </Box>
  );
}
