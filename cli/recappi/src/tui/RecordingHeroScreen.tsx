import React, { useEffect, useState } from "react";
import { Box, Text } from "ink";
import type {
  RecordingArtifact,
  RecordingTelemetry,
} from "../recordingCore";
import { formatBytes, formatClockMs } from "./format";
import { type LiveCaptionsState, liveCaptionStatusLabel } from "./liveCaptions";
import { useTerminalSize } from "./terminal";

const BLOCKS = " ▁▂▃▄▅▆▇█";

// Render recent levels as a full-width sparkline waveform (one block per column,
// height ∝ that sample's loudness).
function waveform(samples: number[], width: number): string {
  if (width <= 0) return "";
  const tail = samples.slice(-width);
  const pad = width - tail.length;
  const cells = tail.map((v) => {
    const i = Math.max(0, Math.min(BLOCKS.length - 1, Math.round(Math.max(0, Math.min(1, v)) * (BLOCKS.length - 1))));
    return BLOCKS[i];
  });
  return "▁".repeat(Math.max(0, pad)) + cells.join("");
}

// The helper sends rms loudness as dB then normalizes to 0..1 via (dB+60)/60
// (see levelFromRmsDb). That inverse is exact, so we can show the real dB the
// helper measured — not a fabricated number. Near-zero reads "silent" so a dead
// source (e.g. the Arc-silent capture bug) is obvious rather than a quiet "-58".
function levelDb(level: number): string {
  if (level <= 0.03) return "silent";
  return `${Math.round(level * 60 - 60)} dB`;
}

// One labeled per-source meter row: System / Mic + its rolling sparkline + dB.
function MeterRow({
  label,
  samples,
  level,
  paused,
  width,
}: {
  label: string;
  samples: number[];
  level: number;
  paused: boolean;
  width: number;
}): React.ReactElement {
  const silent = level <= 0.03;
  return (
    <Box>
      <Box width={9}>
        <Text dimColor>{label}</Text>
      </Box>
      <Box width={width}>
        <Text color={paused ? "gray" : silent ? "yellow" : "red"}>{waveform(samples, width)}</Text>
      </Box>
      <Text dimColor>{`  ${paused ? "paused" : levelDb(level)}`}</Text>
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

// Full-screen recording "hero": recappi brand + big elapsed + full-width live
// waveform + source line. Responsive — the waveform fills the width; narrow
// terminals truncate gracefully. Used while mode=local recording.
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

  // Keep separate rolling buffers for system and mic so each gets its own meter
  // — you can tell at a glance whether the mic is actually picking up, instead of
  // one merged bar. Only append once real level telemetry has arrived; appending
  // zeros before the helper emits audio.level would draw a flat meter that reads
  // as silence.
  useEffect(() => {
    if (telemetry.level == null) return;
    setWaveSys((w) => [...w.slice(-256), telemetry.level!.system ?? 0]);
    setWaveMic((w) => [...w.slice(-256), telemetry.level!.mic ?? 0]);
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
            upload→transcribe progression is legible instead of vanishing. */}
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
  const meterW = Math.max(10, Math.min(48, innerWidth - 22));
  const sizeStr = telemetry.sizeBytes ? formatBytes(telemetry.sizeBytes) : "";
  const context = [telemetry.sourceLabel, telemetry.micEnabled ? "Microphone" : null, sizeStr || null]
    .filter(Boolean)
    .join("  ·  ");

  // Active recording: dense, left-aligned, information-rich — REC + elapsed, a
  // per-source meter for system and mic (so a dead source is visible), the
  // capture context, and the live-caption tail under a section label.
  return (
    <Box flexDirection="column" paddingX={1} height={size.rows}>
      <Text>
        <Text bold color="green">recappi</Text>
        <Text dimColor> · Recording</Text>
      </Text>

      <Box marginTop={1} paddingX={1} flexGrow={1} flexDirection="column">
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
              <MeterRow label="System" samples={waveSys} level={telemetry.level.system ?? 0} paused={paused} width={meterW} />
              {telemetry.micEnabled ? (
                <MeterRow label="Mic" samples={waveMic} level={telemetry.level.mic ?? 0} paused={paused} width={meterW} />
              ) : null}
            </>
          )}
        </Box>

        <Box marginTop={1}>
          <Text dimColor>{context}</Text>
        </Box>

        {captions ? (
          <Box marginTop={1} flexDirection="column">
            <Text dimColor>LIVE CAPTIONS</Text>
            <HeroCaptions state={captions} />
          </Box>
        ) : null}
      </Box>

      <Box>
        <Text dimColor>
          q stop & save{canPause ? ` · p ${paused ? "resume" : "pause"}` : ""}
        </Text>
      </Box>
    </Box>
  );
}

// Compact, auto-following live-caption tail — mirrors the macOS app's floating
// panel (recent source line(s) + a dimmer translation row + the in-flight
// partial), not the full-screen scroller (that's LiveCaptionsView). Rendered in
// the hero only when captions are streaming; degrades to a "listening" hint
// before any speech arrives.
function HeroCaptions({ state }: { state: LiveCaptionsState }): React.ReactElement {
  const MAX_LINES = 3;
  const recent = state.lines.slice(-MAX_LINES);
  const hasPartial = Boolean(state.partial && state.partial.length > 0);
  const captionError =
    state.status === "error"
      ? `Captions unavailable: ${state.error ?? "Live captions unavailable."}`
      : null;
  if (recent.length === 0 && !hasPartial) {
    // Surface the real caption error (the WS status/reason the helper exposes) in
    // yellow (captions degraded, recording continues) rather than a bare label.
    return (
      <Text color={captionError ? "yellow" : undefined} dimColor={!captionError} wrap="truncate-end">
        {captionError ??
          (state.status === "live"
            ? "Listening for speech…"
            : liveCaptionStatusLabel(state.status))}
      </Text>
    );
  }
  return (
    <>
      {recent.map((line) => (
        <Box key={line.id} flexDirection="column">
          <Text wrap="truncate-end">
            {line.speaker ? `${line.speaker}: ` : ""}
            {line.text}
          </Text>
          {line.translation ? (
            <Text dimColor wrap="truncate-end">{`↳ ${line.translation}`}</Text>
          ) : null}
        </Box>
      ))}
      {hasPartial ? (
        <Text dimColor wrap="truncate-end">
          {state.partial}
        </Text>
      ) : null}
      {state.translationPartial ? (
        <Text dimColor wrap="truncate-end">{`↳ ${state.translationPartial}`}</Text>
      ) : null}
      {captionError ? (
        <Text color="yellow" wrap="truncate-end">
          {captionError}
        </Text>
      ) : null}
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
