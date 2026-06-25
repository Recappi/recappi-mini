import React from "react";
import { Box, Text } from "ink";
import type { RecordingData } from "../../../packages/contracts/src/index";
import { formatAge, formatClockMs, padDisplay, spinnerChar } from "./format";

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
  if (jobStatus === "running") return { glyph: spinnerChar(spinnerFrame), color: "cyan" };
  if (jobStatus === "queued") return { glyph: "○", color: "yellow" };
  if (item.status === "aborted") return { glyph: "•", color: "gray" };
  if (item.activeTranscriptId) return { glyph: "✓", color: "green" };
  return { glyph: "·", color: "gray" }; // ready, no transcript yet
}

const MARKER_W = 2;
const GLYPH_W = 2;
const LENGTH_W = 9;
const WHEN_W = 9;

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
    usable - MARKER_W - GLYPH_W - LENGTH_W - (showWhen ? WHEN_W : 0),
  );
  return { title, showWhen };
}

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
      <Text color="cyan">{selected ? "▸ " : "  "}</Text>
      <Text color={color}>{`${glyph} `}</Text>
      <Text bold={selected}>{padDisplay(recordingTitle(item), title)}</Text>
      <Text dimColor>{padDisplay(duration, LENGTH_W)}</Text>
      {showWhen ? <Text dimColor>{padDisplay(formatAge(item.createdAt, nowMs), WHEN_W)}</Text> : null}
      {/* Offline-available marker; constant width keeps columns aligned. */}
      <Text color="green">{downloaded ? " ⤓" : "  "}</Text>
    </Box>
  );
}

// Column header row, rendered above recording lists. Same layout as the rows.
export function RecordingHeader({ columns }: { columns: number }): React.ReactElement {
  const { title, showWhen } = recordingLayout(columns);
  return (
    <Box>
      <Text dimColor>{padDisplay("", MARKER_W + GLYPH_W)}</Text>
      <Text dimColor>{padDisplay("TITLE", title)}</Text>
      <Text dimColor>{padDisplay("LENGTH", LENGTH_W)}</Text>
      {showWhen ? <Text dimColor>WHEN</Text> : null}
    </Box>
  );
}
