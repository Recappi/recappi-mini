import React, { useMemo, useState } from "react";
import { Box, Text, useInput } from "ink";
import { displayWidth, formatClockMs, windowByHeights } from "./format";
import { useTerminalSize } from "./terminal";
import {
  type LiveCaptionsState,
  liveCaptionStatusLabel,
} from "./liveCaptions";

// cyan = live/active stream; yellow = transitional; gray = stopped; red = error.
const STATUS_COLOR: Record<string, string> = {
  connecting: "yellow",
  live: "cyan",
  reconnecting: "yellow",
  stopped: "gray",
  error: "red",
};

// Full-screen live captions reader: a status header, the finalized caption lines
// (tail-following, windowed to the terminal height so it never overflows), and
// the current in-flight partial line. Scroll up to review; G to jump back to live.
export function LiveCaptionsView({
  state,
  nowMs,
}: {
  state: LiveCaptionsState;
  nowMs: number;
}): React.ReactElement {
  const size = useTerminalSize();
  const [scrollUp, setScrollUp] = useState(0);

  const innerWidth = Math.max(10, size.columns - 2);
  // Flatten to display rows: each finalized line, optionally followed by its
  // translation; then the in-flight source + translation partials at the tail.
  const items = useMemo(() => {
    const rows: { key: string; kind: "final" | "translation" | "partial"; speaker?: string; text: string }[] = [];
    for (const l of state.lines) {
      rows.push({ key: l.id, kind: "final", speaker: l.speaker, text: l.text });
      if (l.translation) rows.push({ key: `${l.id}__t`, kind: "translation", text: l.translation });
    }
    if (state.partial && state.partial.length > 0) {
      rows.push({ key: "__partial__", kind: "partial", text: state.partial });
    }
    if (state.translationPartial && state.translationPartial.length > 0) {
      rows.push({ key: "__tpartial__", kind: "translation", text: state.translationPartial });
    }
    return rows;
  }, [state.lines, state.partial, state.translationPartial]);

  const heights = useMemo(
    () =>
      items.map((it) => {
        const prefix = it.kind === "translation" ? "↳ " : it.speaker ? `${it.speaker}: ` : "";
        return Math.max(1, Math.ceil(displayWidth(prefix + it.text) / innerWidth));
      }),
    [items, innerWidth],
  );

  const budget = Math.max(3, size.rows - 3);
  const maxScroll = windowByHeights(heights, Number.MAX_SAFE_INTEGER, budget).maxScroll;
  const top = Math.max(0, maxScroll - scrollUp);
  const win = windowByHeights(heights, top, budget);
  const following = scrollUp === 0;
  const page = Math.max(1, budget - 1);

  useInput((input, key) => {
    if (key.upArrow || input === "k") setScrollUp((s) => Math.min(maxScroll, s + 1));
    else if (key.downArrow || input === "j") setScrollUp((s) => Math.max(0, s - 1));
    else if (key.pageUp || input === "b") setScrollUp((s) => Math.min(maxScroll, s + page));
    else if (key.pageDown || input === " ") setScrollUp((s) => Math.max(0, s - page));
    else if (input === "G") setScrollUp(0);
    else if (input === "g") setScrollUp(maxScroll);
  });

  const elapsed = state.startedAtMs != null ? formatClockMs(Math.max(0, nowMs - state.startedAtMs)) : null;
  const statusColor = STATUS_COLOR[state.status] ?? "white";

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text>
        <Text bold color={statusColor}>
          {liveCaptionStatusLabel(state.status)}
        </Text>
        {elapsed ? <Text dimColor>{`   ${elapsed}`}</Text> : null}
        {!following ? <Text dimColor>{"   ⏸ scrolled — G for live"}</Text> : null}
      </Text>

      <Box marginTop={1} flexDirection="column">
        {items.length === 0 ? (
          <Text dimColor>
            {state.status === "error"
              ? state.error
                ? `Error: ${state.error}`
                : "Live captions error"
              : "Waiting for captions…"}
          </Text>
        ) : (
          items.slice(win.start, win.end).map((it) =>
            it.kind === "translation" ? (
              <Text key={it.key} dimColor italic>
                {`↳ ${it.text}`}
              </Text>
            ) : (
              <Text key={it.key} dimColor={it.kind === "partial"} italic={it.kind === "partial"}>
                {it.speaker ? <Text color="cyan">{`${it.speaker}: `}</Text> : null}
                {it.text}
              </Text>
            ),
          )
        )}
      </Box>

      <Box marginTop={1}>
        <Text dimColor>
          {maxScroll > 0 ? "↑↓ scroll · G live · " : ""}q / esc / ← back
        </Text>
      </Box>
    </Box>
  );
}
