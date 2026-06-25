// Standalone demo of the live captions TUI (#255) driven by a fake event stream,
// so the rendering can be seen/reviewed before the real recording sidecar
// (#252/#254) exists. Run: npx tsx cli/recappi/scripts/captions-demo.tsx
// Quit with Ctrl-C.
import React, { useEffect, useState } from "react";
import { render } from "ink";
import { LiveCaptionsView } from "../src/tui/LiveCaptionsView";
import {
  initialLiveCaptionsState,
  liveCaptionReducer,
  type LiveCaptionEvent,
  type LiveCaptionsState,
} from "../src/tui/liveCaptions";

const SCRIPT = [
  "Welcome to the recappi live captions demo.",
  "This text streams in word by word, like a real transcription.",
  "Finalized lines stay above; the in-flight line shows dim at the bottom.",
  "When it gets long it follows the tail, and you can scroll up to review.",
  "Press G to jump back to live. Ctrl-C to quit.",
];

function Demo(): React.ReactElement {
  const [state, setState] = useState<LiveCaptionsState>(initialLiveCaptionsState());
  const [, setTick] = useState(0);

  useEffect(() => {
    const dispatch = (e: LiveCaptionEvent) => setState((s) => liveCaptionReducer(s, e));
    dispatch({ kind: "status", status: "live", atMs: Date.now() });

    let line = 0;
    let word = 0;
    const timer = setInterval(() => {
      const words = SCRIPT[line % SCRIPT.length]!.split(" ");
      word += 1;
      if (word >= words.length) {
        const id = `${line}`;
        dispatch({
          kind: "final",
          line: { id, text: words.join(" "), speaker: "Speaker 1", atMs: line * 4000 },
        });
        // Demo bilingual pairing: a fake translation line under each source line.
        dispatch({ kind: "translationFinal", segmentId: id, text: `（译）${words.join(" ")}` });
        line += 1;
        word = 0;
      } else {
        dispatch({ kind: "partial", text: words.slice(0, word).join(" ") });
      }
    }, 220);

    const clock = setInterval(() => setTick((t) => t + 1), 1000);
    return () => {
      clearInterval(timer);
      clearInterval(clock);
    };
  }, []);

  return <LiveCaptionsView state={state} nowMs={Date.now()} />;
}

render(<Demo />, { exitOnCtrlC: true });
