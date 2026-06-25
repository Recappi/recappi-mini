import React, { useEffect, useState } from "react";
import { Box, Text } from "ink";
import { formatClockMs } from "./format";
import { type LiveCaptionEventSource } from "./LiveCaptionsScreen";
import {
  initialLiveCaptionsState,
  liveCaptionReducer,
  sidecarToLiveCaptionEvent,
} from "./liveCaptions";

// Local-recording stage: capture is active, but live captions are not streamed yet.
export function RecordingScreen({
  source,
  savedPath,
  now = () => Date.now(),
}: {
  source: LiveCaptionEventSource;
  savedPath?: string;
  now?: () => number;
}): React.ReactElement {
  const [state, setState] = useState(initialLiveCaptionsState);
  const [tick, setTick] = useState(() => now());

  useEffect(() => {
    const unsubscribe = source.onEvent((event) => {
      const mapped = sidecarToLiveCaptionEvent(event);
      if (mapped) setState((s) => liveCaptionReducer(s, mapped));
    });
    return unsubscribe;
  }, [source]);

  useEffect(() => {
    const id = setInterval(() => setTick(now()), 1000);
    return () => clearInterval(id);
  }, [now]);

  const elapsed =
    state.startedAtMs != null ? formatClockMs(Math.max(0, tick - state.startedAtMs)) : null;

  let body: React.ReactElement;
  switch (state.status) {
    case "live":
      body = (
        <>
          <Text>
            <Text bold color="red">
              ● Recording
            </Text>
            {elapsed ? <Text dimColor>{`   ${elapsed}`}</Text> : null}
          </Text>
          <Text dimColor>Recording to your Mac. Press q to stop and save.</Text>
        </>
      );
      break;
    case "stopped":
      body = (
        <>
          <Text color="green">✓ Recording saved to your Mac.</Text>
          {savedPath ? <Text dimColor wrap="truncate-middle">{savedPath}</Text> : null}
        </>
      );
      break;
    case "error":
      body = (
        <Text color="red">{state.error ? `Recording error: ${state.error}` : "Recording error"}</Text>
      );
      break;
    default:
      body = <Text dimColor>Starting recording…</Text>;
  }

  const footer = state.status === "stopped" ? "esc / ← back" : "q / esc / ← stop & save";

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text dimColor>‹ Record</Text>
      <Box marginTop={1} flexDirection="column">
        {body}
      </Box>
      <Box marginTop={1}>
        <Text dimColor>{footer}</Text>
      </Box>
    </Box>
  );
}
