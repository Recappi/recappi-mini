import React, { useMemo, useState } from "react";
import { Box, Text, useInput } from "ink";
import type { TranscriptData } from "../../../packages/contracts/src/index";
import { displayWidth, formatClockMs, windowByHeights } from "./format";
import { useTerminalSize } from "./terminal";

export interface TranscriptViewProps {
  loading: boolean;
  data?: TranscriptData;
  error?: string;
}

// Full-screen, scrollable transcript reader: timestamped speaker lines windowed
// to the terminal height so a long transcript shows from the top and scrolls,
// rather than overflowing the alternate screen (which only revealed the tail).
export function TranscriptView({ loading, data, error }: TranscriptViewProps): React.ReactElement {
  const size = useTerminalSize();
  const [scroll, setScroll] = useState(0);

  const segments = data?.segments ?? [];
  const innerWidth = Math.max(10, size.columns - 2);
  const heights = useMemo(
    () =>
      segments.map((s) => {
        const prefix = `[${formatClockMs(s.startMs)}] ${s.speaker ? `${s.speaker}: ` : ""}`;
        return Math.max(1, Math.ceil(displayWidth(prefix + s.text) / innerWidth));
      }),
    [segments, innerWidth],
  );

  // title (1) + marginTop (1) + footer (1) reserved.
  const budget = Math.max(3, size.rows - 3);
  const win = windowByHeights(heights, scroll, budget);
  const page = Math.max(1, budget - 1);

  useInput((input, key) => {
    if (key.downArrow || input === "j") setScroll((s) => Math.min(win.maxScroll, s + 1));
    else if (key.upArrow || input === "k") setScroll((s) => Math.max(0, s - 1));
    else if (key.pageDown || input === " ") setScroll((s) => Math.min(win.maxScroll, s + page));
    else if (key.pageUp || input === "b") setScroll((s) => Math.max(0, s - page));
    else if (input === "g") setScroll(0);
    else if (input === "G") setScroll(win.maxScroll);
  });

  if (loading) {
    return (
      <Box paddingX={1}>
        <Text dimColor>Loading transcript…</Text>
      </Box>
    );
  }
  if (error) {
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text color="red">! {error}</Text>
        <Text dimColor>q / esc / ← back</Text>
      </Box>
    );
  }
  if (!data) {
    return (
      <Box paddingX={1}>
        <Text dimColor>No transcript.</Text>
      </Box>
    );
  }

  const title = data.summary?.title ?? "Transcript";
  const total = segments.length;
  const more = win.maxScroll > 0;
  const position = total === 0 ? "" : `${win.start + 1}–${win.end} / ${total}`;

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text bold color="magenta">
        {title}
        {more ? <Text dimColor>{`   ${position}`}</Text> : null}
      </Text>
      <Box marginTop={1} flexDirection="column">
        {total === 0 ? (
          <Text>{data.text}</Text>
        ) : (
          segments.slice(win.start, win.end).map((segment, index) => (
            <Text key={win.start + index}>
              <Text dimColor>[{formatClockMs(segment.startMs)}] </Text>
              {segment.speaker ? <Text color="cyan">{segment.speaker}: </Text> : null}
              {segment.text}
            </Text>
          ))
        )}
      </Box>
      <Box marginTop={1}>
        <Text dimColor>
          {more ? "↑↓ scroll · PgUp/PgDn · g/G top/bottom · " : ""}q / esc / ← back
        </Text>
      </Box>
    </Box>
  );
}
