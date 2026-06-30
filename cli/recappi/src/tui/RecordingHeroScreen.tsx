import React, { useEffect, useRef, useState } from "react";
import { Box, Text } from "ink";
import type {
  RecordingArtifact,
  RecordingTelemetry,
} from "../recordingCore";
import { displayWidth, formatBytes, formatClockMs } from "./format";
import { type LiveCaptionsState, liveCaptionStatusLabel } from "./liveCaptions";
import { useTerminalSize } from "./terminal";

const WAVE_THROTTLE_MS = 220; // ~4.5 Hz; the helper emits levels several times faster, which scrolled too fast.

// Dot-matrix height in rows: the app uses 5, but on a short terminal that would
// crowd out the captions, so drop to 3 when there isn't much vertical room.
function waveRowsFor(terminalRows: number): number {
  return terminalRows >= 30 ? 5 : 3;
}

// How many of `rows` dots a level lights, mirroring the app's
// DotMatrixWaveformModel.litRowCounts: perceptual (pow 0.58) so quiet activity
// still shows, with a small floor below which the column reads as silent.
function litCount(level: number, rows: number): number {
  const amp = Math.max(0, Math.min(1, level));
  if (amp <= 0.028) return 0;
  return Math.max(1, Math.min(rows, Math.ceil(Math.pow(amp, 0.58) * rows)));
}

// Per-column lit-dot counts for the rolling window (newest on the right).
function litCounts(samples: number[], width: number, rows: number): number[] {
  if (width <= 0) return [];
  const tail = samples.slice(-width);
  return [...Array(Math.max(0, width - tail.length)).fill(0), ...tail].map((v) => litCount(v, rows));
}

// The helper sends rms loudness as dB then normalizes to 0..1 via (dB+60)/60
// (see levelFromRmsDb). That inverse is exact, so we can show the real dB the
// helper measured, not a fabricated number. Near-zero reads "silent" so a dead
// source (e.g. the Arc-silent capture bug) is obvious rather than a quiet "-58".
function levelDb(level: number): string {
  if (level <= 0.03) return "silent";
  return `${Math.round(level * 60 - 60)} dB`;
}

// One labeled per-source meter: System / Mic, a dot-matrix waveform, and the dB.
// Label + dB are vertically centered against the matrix.
function MeterRow({
  label,
  samples,
  level,
  paused,
  width,
  rows,
}: {
  label: string;
  samples: number[];
  level: number;
  paused: boolean;
  width: number;
  rows: number;
}): React.ReactElement {
  const silent = level <= 0.03;
  // cyan = live audio (active); gray = paused. The dB label flags a silent source
  // in yellow (the Arc-silent bug). Red is reserved for the REC badge / errors.
  // Unlit cells are a dim · grid (like the app's unlit dots) — also keeps every
  // row non-empty so Ink doesn't collapse blank rows and break alignment.
  const cols = litCounts(samples, width, rows);
  const litColor = paused ? "gray" : "cyan";
  // Label + dB on a header row, the dot matrix beneath — simpler and more robust
  // than vertically centering the label against a variable-height matrix.
  return (
    <Box flexDirection="column">
      <Box width={width + 9}>
        <Box width={9}><Text dimColor>{label}</Text></Box>
        <Box flexGrow={1} justifyContent="flex-end">
          {!paused && silent ? (
            <Text color="yellow">silent</Text>
          ) : (
            <Text dimColor>{paused ? "paused" : levelDb(level)}</Text>
          )}
        </Box>
      </Box>
      {Array.from({ length: rows }, (_, r) => {
        const fromBottom = rows - r;
        return (
          <Text key={r}>
            {cols.map((c, i) =>
              c >= fromBottom ? (
                <Text key={i} color={litColor}>{c === fromBottom ? "•" : "●"}</Text>
              ) : (
                <Text key={i} dimColor>·</Text>
              ),
            )}
          </Text>
        );
      })}
    </Box>
  );
}

// A determinate progress bar (filled cyan, remainder dim). Used for the post-stop
// upload/transcribe lifecycle once the runtime reports a 0..1 fraction.
function ProgressBar({ fraction, width = 12 }: { fraction: number; width?: number }): React.ReactElement {
  const f = Math.max(0, Math.min(1, fraction));
  const filled = Math.round(f * width);
  return (
    <Text color="cyan">
      {"▓".repeat(filled)}
      <Text dimColor>{"░".repeat(Math.max(0, width - filled))}</Text>
    </Text>
  );
}

// The active post-stop phase to surface with a bar, derived from the artifact's
// lifecycle. Transcription "queued" is intentionally left to the handoff line
// (it already reads "Transcription queued"); only in-flight phases get a bar.
function stoppedPhase(
  artifact: RecordingArtifact | undefined,
): { label: string; fraction?: number } | null {
  if (!artifact) return null;
  if (artifact.uploadStatus === "uploading") {
    return { label: "Uploading to Recappi Cloud", fraction: artifact.uploadProgress };
  }
  if (artifact.uploadStatus === "queued") return { label: "Queued to upload" };
  if (artifact.transcriptionStatus === "processing") {
    return { label: "Transcribing", fraction: artifact.transcriptionProgress };
  }
  return null;
}

// Full-screen recording "hero": brand + elapsed + per-source meters + a live
// caption area that grows to fill the screen. Responsive to terminal size.
export function RecordingHeroScreen({
  telemetry,
  artifact,
  captions,
  canTranscribe = false,
  canPause = false,
  now = () => Date.now(),
}: {
  telemetry: RecordingTelemetry;
  artifact?: RecordingArtifact;
  captions?: LiveCaptionsState;
  canTranscribe?: boolean;
  canPause?: boolean;
  now?: () => number;
}): React.ReactElement {
  const size = useTerminalSize();
  const [tick, setTick] = useState(() => now());
  const [waveSys, setWaveSys] = useState<number[]>([]);
  const [waveMic, setWaveMic] = useState<number[]>([]);
  const lastAppendRef = useRef(0);

  // Separate rolling buffers for system and mic, so each gets its own meter (you
  // can see whether the mic is actually picking up). Throttled to WAVE_THROTTLE_MS
  // so the waveform scrolls at a readable pace rather than racing the event rate.
  // Only append once real level telemetry has arrived; zeros before the first
  // audio.level would draw a flat meter that reads as silence.
  useEffect(() => {
    if (telemetry.level == null) return;
    const t = now();
    if (t - lastAppendRef.current < WAVE_THROTTLE_MS) return;
    lastAppendRef.current = t;
    setWaveSys((w) => [...w.slice(-512), telemetry.level!.system ?? 0]);
    setWaveMic((w) => [...w.slice(-512), telemetry.level!.mic ?? 0]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [telemetry.level]);

  useEffect(() => {
    const id = setInterval(() => setTick(now()), 1000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const elapsed = telemetry.startedAtMs != null ? formatClockMs(Math.max(0, tick - telemetry.startedAtMs)) : "00:00";
  const innerWidth = Math.max(10, size.columns - 4);

  if (telemetry.status === "stopped") {
    const handoff = stoppedHandoffCopy(artifact, canTranscribe);
    const phase = stoppedPhase(artifact);
    const meta = [
      telemetry.durationMs != null ? formatClockMs(telemetry.durationMs) : null,
      formatBytes(telemetry.sizeBytes) || null,
    ]
      .filter(Boolean)
      .join(" · ");
    // Destination-aware: only claim the cloud once the upload actually landed.
    const saved = artifact?.uploadStatus === "uploaded" ? "✓ Saved to Recappi Cloud" : "✓ Saved to your Mac";
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text dimColor>recappi · Recording</Text>
        <Box marginTop={1} flexDirection="column">
          <Text color="green">{saved}</Text>
          {meta ? <Text dimColor>{meta}</Text> : null}
          {telemetry.savedPath ? <Text dimColor wrap="truncate-middle">{telemetry.savedPath}</Text> : null}
        </Box>
        {/* Post-stop lifecycle: show the in-flight phase with a bar so the
            upload to transcribe progression is legible instead of vanishing. */}
        {phase ? (
          <Box marginTop={1}>
            <Text color="cyan">{`◐ ${phase.label}`}</Text>
            {phase.fraction != null ? (
              <>
                <Text>{"   "}</Text>
                <ProgressBar fraction={phase.fraction} />
                <Text dimColor>{` ${Math.round(phase.fraction * 100)}%`}</Text>
              </>
            ) : (
              <Text dimColor>…</Text>
            )}
          </Box>
        ) : null}
        <Box marginTop={1} flexDirection="column">
          <Text color={handoff.tone === "red" ? "red" : handoff.tone === "green" ? "green" : undefined} dimColor={handoff.tone === "dim"}>
            {handoff.text}
          </Text>
          {artifact?.error ? <Text color="red" wrap="truncate-end">{artifact.error}</Text> : null}
        </Box>
      </Box>
    );
  }

  if (telemetry.status === "error") {
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text dimColor>recappi · Recording</Text>
        <Box marginTop={1}>
          <Text color="red">{telemetry.error ? `Recording error: ${telemetry.error}` : "Recording error"}</Text>
        </Box>
        <Box marginTop={1}>
          <Text dimColor>esc back</Text>
        </Box>
      </Box>
    );
  }

  const paused = telemetry.status === "paused";
  const starting = telemetry.status === "starting" || telemetry.status === "stopping";
  const badge = paused ? "⏸ PAUSED" : starting ? "…" : "⏺ REC";
  const meterW = Math.max(10, Math.min(72, innerWidth - 20));
  const sizeStr = telemetry.sizeBytes ? formatBytes(telemetry.sizeBytes) : "";
  const context = [telemetry.sourceLabel, telemetry.micEnabled ? "Microphone" : null, sizeStr || null]
    .filter(Boolean)
    .join("  ·  ");

  // Waveform height adapts to the terminal so it doesn't crowd out captions.
  const waveRows = waveRowsFor(size.rows);
  // Rows consumed by the fixed chrome (brand, REC, meters, context, footer +
  // margins); the caption area gets whatever's left so it fills the screen.
  // Each meter is a header row + waveRows matrix rows; the mic meter adds a
  // top-margin row.
  const meterBlockRows = (telemetry.micEnabled ? 2 : 1) * (waveRows + 1) + (telemetry.micEnabled ? 1 : 0);
  const fixedRows = 8 + meterBlockRows;
  const captionRows = Math.max(2, size.rows - fixedRows);

  // Active recording: dense, left-aligned, information-rich — REC + elapsed,
  // per-source meters, capture context, and a live-caption area that grows to
  // fill the remaining height.
  return (
    <Box flexDirection="column" paddingX={1}>
      <Text>
        <Text bold color="green">recappi</Text>
        <Text dimColor> · Recording</Text>
      </Text>

      <Box marginTop={1} paddingX={1} flexDirection="column">
        <Text>
          <Text bold color={paused ? "yellow" : "red"}>{badge}</Text>
          <Text>   </Text>
          <Text bold>{elapsed}</Text>
        </Text>

        <Box marginTop={1} flexDirection="column">
          {telemetry.level == null ? (
            // No level telemetry yet — honest activity, not a flat meter that
            // reads as silence (the elapsed timer above proves it's live).
            <Text dimColor>{paused ? "Paused" : `Capturing audio${".".repeat((Math.floor(tick / 1000) % 3) + 1)}`}</Text>
          ) : (
            <>
              <MeterRow label="System" samples={waveSys} level={telemetry.level.system ?? 0} paused={paused} width={meterW} rows={waveRows} />
              {telemetry.micEnabled ? (
                <Box marginTop={1}>
                  <MeterRow label="Mic" samples={waveMic} level={telemetry.level.mic ?? 0} paused={paused} width={meterW} rows={waveRows} />
                </Box>
              ) : null}
            </>
          )}
        </Box>

        <Box marginTop={1}>
          <Text dimColor>{context}</Text>
        </Box>

        {captions ? (
          <Box marginTop={1} flexDirection="column">
            <Text bold dimColor>LIVE CAPTIONS</Text>
            <HeroCaptions state={captions} maxRows={captionRows} width={innerWidth} />
          </Box>
        ) : null}
      </Box>

      <Box marginTop={1}>
        <Text dimColor>
          q stop & save{canPause ? ` · p ${paused ? "resume" : "pause"}` : ""}
        </Text>
      </Box>
    </Box>
  );
}

// Strip the leading whitespace ASR streams prepend to continuation tokens — it
// rendered as a stray indent that flickered in on each new line.
const trimLead = (s: string): string => s.replace(/^\s+/, "");

// Estimate how many terminal rows a caption line takes once wrapped to `width`.
function wrappedRows(text: string, width: number): number {
  return Math.max(1, Math.ceil(displayWidth(text) / Math.max(1, width)));
}

// Auto-following live-caption area: the most recent source + translation
// (bilingual) lines, each WRAPPED (long sentences span multiple lines, never
// truncated), filling `maxRows` of vertical space. Tail-follows the live stream;
// degrades to a "listening" hint before any speech arrives.
function HeroCaptions({
  state,
  maxRows,
  width,
}: {
  state: LiveCaptionsState;
  maxRows: number;
  width: number;
}): React.ReactElement {
  const hasPartial = Boolean(state.partial && state.partial.length > 0);
  const captionError =
    state.status === "error"
      ? `Captions unavailable: ${state.error ?? "Live captions unavailable."}`
      : null;
  if (state.lines.length === 0 && !hasPartial) {
    return (
      <Text color={captionError ? "yellow" : undefined} dimColor={!captionError}>
        {captionError ??
          (state.status === "live"
            ? "Listening for speech…"
            : liveCaptionStatusLabel(state.status))}
      </Text>
    );
  }

  // Flatten to caption lines (source, then its translation), newest last.
  type Line = { key: string; text: string; dim: boolean };
  const lines: Line[] = [];
  for (const line of state.lines) {
    lines.push({
      key: `${line.id}-s`,
      text: `${line.speaker ? `${line.speaker}: ` : ""}${trimLead(line.text)}`,
      dim: false,
    });
    if (line.translation) {
      lines.push({ key: `${line.id}-t`, text: `  ↳ ${trimLead(line.translation)}`, dim: true });
    }
  }
  if (hasPartial) lines.push({ key: "partial", text: trimLead(state.partial!), dim: true });
  if (state.translationPartial) {
    lines.push({ key: "tpartial", text: `  ↳ ${trimLead(state.translationPartial)}`, dim: true });
  }

  // Tail-fill: from the newest line backward, keep adding until the wrapped
  // heights would exceed the budget, so the most recent captions stay visible.
  const budget = Math.max(1, maxRows);
  const chosen: Line[] = [];
  let used = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    const h = wrappedRows(lines[i]!.text, width);
    if (used + h > budget && chosen.length > 0) break;
    chosen.unshift(lines[i]!);
    used += h;
  }
  return (
    <>
      {chosen.map((l) => (
        <Text key={l.key} dimColor={l.dim} wrap="wrap">{l.text}</Text>
      ))}
      {captionError ? <Text color="yellow" wrap="wrap">{captionError}</Text> : null}
    </>
  );
}

function stoppedHandoffCopy(
  artifact: RecordingArtifact | undefined,
  canTranscribe: boolean,
): { text: string; tone: "dim" | "green" | "red" | "normal" } {
  // While uploading / transcribing, the phase line above already shows status +
  // a progress bar — the footer just offers to detach instead of repeating it.
  if (artifact?.uploadStatus === "uploading" || artifact?.transcriptionStatus === "processing") {
    return { text: "esc run in background", tone: "dim" };
  }
  if (artifact?.transcriptionStatus === "queued") {
    return { text: "Transcription queued · ⏎ open recording · n not now", tone: "green" };
  }
  if (artifact?.transcriptionStatus === "ready") {
    return { text: "Transcription ready · ⏎ open recording · n not now", tone: "green" };
  }
  if (artifact?.uploadStatus === "failed" || artifact?.transcriptionStatus === "failed") {
    return { text: "Transcription failed · ⏎ retry · n not now", tone: "red" };
  }
  if (!canTranscribe || !artifact?.audioPath) {
    return { text: "Saved locally · n back", tone: "dim" };
  }
  return { text: "Transcribe now? ⏎ yes · n not now", tone: "normal" };
}
