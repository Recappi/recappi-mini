import React, { useEffect, useState } from "react";
import { Box, Text } from "ink";
import type {
  RecordingArtifact,
  RecordingTelemetry,
} from "../recordingCore";
import { formatBytes, formatClockMs } from "./format";
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

// Full-screen recording "hero": recappi brand + big elapsed + full-width live
// waveform + source line. Responsive — the waveform fills the width; narrow
// terminals truncate gracefully. Used while mode=local recording.
export function RecordingHeroScreen({
  telemetry,
  artifact,
  canTranscribe = false,
  canPause = false,
  now = () => Date.now(),
}: {
  telemetry: RecordingTelemetry;
  artifact?: RecordingArtifact;
  canTranscribe?: boolean;
  canPause?: boolean;
  now?: () => number;
}): React.ReactElement {
  const size = useTerminalSize();
  const [tick, setTick] = useState(() => now());
  const [wave, setWave] = useState<number[]>([]);

  // Append the loudest of system/mic to the rolling waveform buffer on each
  // update — only once real level telemetry has arrived. Appending zeros before
  // the helper emits audio.level would draw a flat meter that reads as silence.
  useEffect(() => {
    if (telemetry.level == null) return;
    const lvl = Math.max(telemetry.level.system ?? 0, telemetry.level.mic ?? 0);
    setWave((w) => [...w.slice(-512), lvl]);
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
    const meta = [
      telemetry.durationMs != null ? formatClockMs(telemetry.durationMs) : null,
      formatBytes(telemetry.sizeBytes) || null,
    ]
      .filter(Boolean)
      .join(" · ");
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text dimColor>recappi · Recording</Text>
        <Box marginTop={1} flexDirection="column">
          <Text color="green">✓ Saved to your Mac</Text>
          {meta ? <Text dimColor>{meta}</Text> : null}
          {telemetry.savedPath ? <Text dimColor wrap="truncate-middle">{telemetry.savedPath}</Text> : null}
        </Box>
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

  return (
    <Box flexDirection="column" paddingX={1} height={size.rows}>
      <Text>
        <Text bold color="magenta">recappi</Text>
        <Text dimColor> · Recording</Text>
      </Text>

      <Box flexGrow={1} flexDirection="column" justifyContent="center" alignItems="center">
        <Text bold color={paused ? "yellow" : "red"}>{badge}</Text>
        <Text bold>{elapsed}</Text>
        <Box marginTop={1}>
          {telemetry.level == null ? (
            // No level telemetry yet — show honest activity, not a flat meter that
            // looks like silence (the elapsed timer above proves it's live).
            <Text dimColor>{paused ? "Paused" : `Capturing audio${".".repeat((Math.floor(tick / 1000) % 3) + 1)}`}</Text>
          ) : (
            <Text color={paused ? "gray" : "red"}>{waveform(wave, innerWidth)}</Text>
          )}
        </Box>
        <Box marginTop={1}>
          <Text dimColor>
            {telemetry.sourceLabel}
            {telemetry.micEnabled ? "  +  Microphone" : ""}
          </Text>
        </Box>
      </Box>

      <Box>
        <Text dimColor>
          q stop & save{canPause ? ` · p ${paused ? "resume" : "pause"}` : ""}
        </Text>
      </Box>
    </Box>
  );
}

function stoppedHandoffCopy(
  artifact: RecordingArtifact | undefined,
  canTranscribe: boolean,
): { text: string; tone: "dim" | "green" | "red" | "normal" } {
  if (artifact?.uploadStatus === "uploading") {
    return { text: "Uploading…", tone: "normal" };
  }
  if (artifact?.transcriptionStatus === "processing") {
    return { text: "Transcribing…", tone: "normal" };
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
