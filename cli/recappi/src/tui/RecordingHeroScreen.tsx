import React, { useEffect, useState } from "react";
import { Box, Text } from "ink";
import type { RecordingTelemetry as CoreRecordingTelemetry } from "../recordingCore";
import { formatBytes, formatClockMs } from "./format";
import { useTerminalSize } from "./terminal";

export type RecordingTelemetry = CoreRecordingTelemetry;

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
  canPause = false,
  now = () => Date.now(),
}: {
  telemetry: RecordingTelemetry;
  canPause?: boolean;
  now?: () => number;
}): React.ReactElement {
  const size = useTerminalSize();
  const [tick, setTick] = useState(() => now());
  const [wave, setWave] = useState<number[]>([]);

  // Append the loudest of system/mic to the rolling waveform buffer on each update.
  useEffect(() => {
    const lvl = Math.max(telemetry.level?.system ?? 0, telemetry.level?.mic ?? 0);
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
        <Box marginTop={1}>
          <Text dimColor>Transcribe now?  ⏎ yes · n not now · esc back</Text>
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
          <Text color={paused ? "gray" : "red"}>{waveform(wave, innerWidth)}</Text>
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
