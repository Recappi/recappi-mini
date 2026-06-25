import React, { useEffect, useState } from "react";
import type { SidecarEvent } from "../../../packages/contracts/src/index";
import { LiveCaptionsView } from "./LiveCaptionsView";
import {
  initialLiveCaptionsState,
  liveCaptionReducer,
  sidecarToLiveCaptionEvent,
} from "./liveCaptions";

// Anything that can push sidecar events — matches MiniSidecarClient.onEvent, so
// `recappi record --live` (#254) just passes the client here. Kept structural so
// the screen has no dependency on the sidecar client implementation.
export interface LiveCaptionEventSource {
  onEvent(listener: (event: SidecarEvent) => void): () => void;
}

// The thin TUI driver for #255: subscribes to the sidecar event stream, folds
// each event through the adapter + reducer, and renders the live captions view.
// All caption rendering/scrolling lives in LiveCaptionsView; this only wires the
// stream to state and ticks the clock for the elapsed display.
export function LiveCaptionsScreen({
  source,
  now = () => Date.now(),
}: {
  source: LiveCaptionEventSource;
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return <LiveCaptionsView state={state} nowMs={tick} />;
}
