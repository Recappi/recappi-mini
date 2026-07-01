import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import type { RecordingArtifact, RecordingTelemetry } from "../recordingCore";
import type { RecordingData } from "../../../packages/contracts/src/index";
import { displayWidth, formatBytes, formatClockMs } from "./format";
import { type LiveCaptionsState } from "./liveCaptions";
import { recordingProcessingState, recordingTitle } from "./RecordingRow";
import { useTerminalSize } from "./terminal";

// Which caption panes to show; cycled with `c`. Original / translation are shown
// as independent, scrollable columns — no 1:1 pairing is implied.
export type CaptionMode = "both" | "source" | "translation";

const trimLead = (s: string): string => s.replace(/^\s+/, "");
const wrappedRows = (text: string, width: number): number =>
  Math.max(1, Math.ceil(displayWidth(text) / Math.max(1, width)));

// Honest dB recovered from the normalized level (inverse of levelFromRmsDb).
function levelDb(level: number): string {
  if (level <= 0.03) return "silent";
  return `${Math.round(level * 60 - 60)} dB`;
}

// Compact single-row level bar (the frame keeps meters small so captions get the
// room). cyan = signal, yellow = silent.
function CompactMeter({ label, level }: { label: string; level: number }): React.ReactElement {
  const width = 12;
  const filled = Math.max(0, Math.min(width, Math.round(Math.max(0, Math.min(1, level)) * width)));
  const silent = level <= 0.03;
  return (
    <Text>
      <Text dimColor>{label} </Text>
      <Text color={silent ? "yellow" : "cyan"}>{"●".repeat(filled)}</Text>
      <Text dimColor>{"·".repeat(width - filled)}</Text>
      <Text dimColor>{`  ${levelDb(level)}`}</Text>
    </Text>
  );
}

// Tail-following column of caption lines, wrapped to `width`, filling `rows`.
function CaptionColumn({
  lines,
  width,
  rows,
  dim,
}: {
  lines: string[];
  width: number;
  rows: number;
  dim?: boolean;
}): React.ReactElement {
  const chosen: string[] = [];
  let used = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    const h = wrappedRows(lines[i]!, width);
    if (used + h > rows && chosen.length > 0) break;
    chosen.unshift(lines[i]!);
    used += h;
  }
  return (
    <Box width={width} flexDirection="column">
      {chosen.length === 0 ? (
        <Text dimColor>Listening for speech…</Text>
      ) : (
        chosen.map((l, i) => (
          <Text key={i} dimColor={dim} wrap="wrap">{l}</Text>
        ))
      )}
    </Box>
  );
}

// Compact outcome / next-action line for the right pane's footer of the detail.
function outcomeLine(telemetry: RecordingTelemetry, artifact?: RecordingArtifact): string {
  if (telemetry.status === "recording" || telemetry.status === "starting") {
    return "Recording… stop to auto-save + transcribe + summarize";
  }
  const up = artifact?.uploadStatus;
  const tr = artifact?.transcriptionStatus;
  if (up === "uploading") return `Uploading to Recappi Cloud… ${pct(artifact?.uploadProgress)}`;
  if (tr === "processing") return `Transcribing… ${pct(artifact?.transcriptionProgress)}`;
  if (tr === "ready") return "Transcript ready · ⏎ open · T re-transcribe";
  if (up === "failed" || tr === "failed") return "Cloud handoff failed · T retry";
  return "Saved · ⏎ open";
}
function pct(f?: number): string {
  return f == null ? "" : `${Math.round(Math.max(0, Math.min(1, f)) * 100)}%`;
}

// Framed record/session view: a status header, a left recordings list, a right
// detail pane (source + compact meters + a scrollable ORIGINAL|TRANSLATION
// caption split + outcome), and a fixed shortcut footer. Replaces the
// full-screen hero so the record page reads as a structured TUI app.
export function RecordFrame({
  telemetry,
  captions,
  artifact,
  recordings = [],
  selectedIndex = 0,
  title = "New recording",
  recordingId,
  jobId,
  nowMs = Date.now(),
  spinnerFrame = 0,
}: {
  telemetry: RecordingTelemetry;
  captions?: LiveCaptionsState;
  artifact?: RecordingArtifact;
  recordings?: RecordingData[];
  selectedIndex?: number;
  title?: string;
  recordingId?: string;
  jobId?: string;
  nowMs?: number;
  spinnerFrame?: number;
}): React.ReactElement {
  const size = useTerminalSize();
  const [captionMode, setCaptionMode] = useState<CaptionMode>("both");
  useInput((input) => {
    if (input === "c") {
      setCaptionMode((m) => (m === "both" ? "source" : m === "source" ? "translation" : "both"));
    }
  });

  const elapsed = telemetry.startedAtMs != null ? formatClockMs(Math.max(0, nowMs - telemetry.startedAtMs)) : "00:00";
  const recording = telemetry.status === "recording" || telemetry.status === "starting";
  const stateLabel = recording ? "⏺ REC" : telemetry.status === "paused" ? "⏸ PAUSED" : telemetry.status === "stopped" ? "■ STOPPED" : "…";
  const ids = [recordingId, jobId].filter(Boolean).join(" · ");

  const innerWidth = Math.max(20, size.columns - 2);
  const listWidth = Math.min(20, Math.max(14, Math.floor(innerWidth * 0.22)));
  const rightWidth = Math.max(20, innerWidth - listWidth - 3);
  const captionRows = Math.max(3, size.rows - 10);

  // Derive independent source/translation streams from the caption state.
  const sourceLines = captions
    ? [
        ...captions.lines.map((l) => `${l.speaker ? `${l.speaker}: ` : ""}${trimLead(l.text)}`),
        ...(captions.partial ? [trimLead(captions.partial)] : []),
      ]
    : [];
  const translationLines = captions
    ? [
        ...captions.lines.filter((l) => l.translation).map((l) => trimLead(l.translation!)),
        ...(captions.translationPartial ? [trimLead(captions.translationPartial)] : []),
      ]
    : [];

  const status = telemetry.sizeBytes ? formatBytes(telemetry.sizeBytes) : "";
  const sourceLine = [telemetry.sourceLabel, telemetry.micEnabled ? "Microphone" : null, status || null]
    .filter(Boolean)
    .join(" · ");

  return (
    <Box flexDirection="column" paddingX={1} height={size.rows}>
      {/* Status header */}
      <Box justifyContent="space-between">
        <Text>
          <Text bold color="green">recappi</Text>
          <Text dimColor> · Recording</Text>
        </Text>
        <Text>
          <Text bold color={recording ? "red" : "gray"}>{stateLabel}</Text>
          <Text dimColor>{`  ${elapsed}${ids ? ` · ${ids}` : ""}`}</Text>
        </Text>
      </Box>
      <Text dimColor>{"─".repeat(innerWidth)}</Text>

      {/* Two panes */}
      <Box flexGrow={1}>
        {/* Left: recordings list */}
        <Box width={listWidth} flexDirection="column">
          <Text dimColor>{`RECORDINGS · ${recordings.length}`}</Text>
          <Box marginTop={1} flexDirection="column">
            {recordings.slice(0, Math.max(1, size.rows - 8)).map((rec, i) => {
              const st = recordingProcessingState(rec, undefined, spinnerFrame);
              const sel = i === selectedIndex;
              return (
                <Box key={rec.recordingId}>
                  <Box width={2}><Text color="cyan">{sel ? "▸" : ""}</Text></Box>
                  <Box width={2}><Text color={st.color}>{st.glyph}</Text></Box>
                  <Box width={listWidth - 4}><Text bold={sel} wrap="truncate-end">{recordingTitle(rec)}</Text></Box>
                </Box>
              );
            })}
          </Box>
        </Box>

        {/* Divider */}
        <Box width={3} flexDirection="column" alignItems="center">
          {Array.from({ length: Math.max(1, size.rows - 6) }, (_, i) => (
            <Text key={i} dimColor>│</Text>
          ))}
        </Box>

        {/* Right: session detail */}
        <Box width={rightWidth} flexDirection="column">
          <Text bold wrap="truncate-end">{title}</Text>
          <Text dimColor wrap="truncate-end">{sourceLine}</Text>
          {telemetry.level ? (
            <Box>
              <CompactMeter label="System" level={telemetry.level.system ?? 0} />
              {telemetry.micEnabled ? <Text dimColor>{"    "}</Text> : null}
              {telemetry.micEnabled ? <CompactMeter label="Mic" level={telemetry.level.mic ?? 0} /> : null}
            </Box>
          ) : (
            <Text dimColor>Capturing audio…</Text>
          )}

          {/* Caption split */}
          <Box marginTop={1} flexDirection="column" flexGrow={1}>
            <Box>
              {captionMode !== "translation" ? <Box width={captionMode === "both" ? Math.floor((rightWidth - 3) / 2) : rightWidth}><Text bold dimColor>ORIGINAL</Text></Box> : null}
              {captionMode === "both" ? <Box width={3} /> : null}
              {captionMode !== "source" ? <Text bold dimColor>TRANSLATION</Text> : null}
            </Box>
            <Box>
              {captionMode !== "translation" ? (
                <CaptionColumn
                  lines={sourceLines}
                  width={captionMode === "both" ? Math.floor((rightWidth - 3) / 2) : rightWidth}
                  rows={captionRows}
                />
              ) : null}
              {captionMode === "both" ? (
                <Box width={3} flexDirection="column">{Array.from({ length: Math.min(captionRows, 12) }, (_, i) => <Text key={i} dimColor>│</Text>)}</Box>
              ) : null}
              {captionMode !== "source" ? (
                <CaptionColumn
                  lines={translationLines}
                  width={captionMode === "both" ? Math.floor((rightWidth - 3) / 2) : rightWidth}
                  rows={captionRows}
                  dim
                />
              ) : null}
            </Box>
          </Box>

          {/* Outcome / next action */}
          <Box marginTop={1}>
            <Text bold dimColor>OUTCOME </Text>
            <Text dimColor>{outcomeLine(telemetry, artifact)}</Text>
          </Box>
        </Box>
      </Box>

      {/* Footer */}
      <Text dimColor>{"─".repeat(innerWidth)}</Text>
      <Text dimColor>{`q stop & save · c captions (${captionMode}) · ↑↓ select · ⏎ open · 1 overview 2 jobs 3 account`}</Text>
    </Box>
  );
}
