import React, { useCallback, useRef, useState } from "react";
import { Box, Text, useInput } from "ink";
import type { AskCitation, AskRecordingOptions, AskStreamEvent } from "../api";
import { formatAskAnswerPlain, strippedAskAnswer } from "./askInline";
import { displayWidth } from "./format";
import { useTerminalSize } from "./terminal";

type AskPhase = "input" | "asking" | "done" | "error";

const SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";

// Interactive "Ask this recording" screen. Owns its own input/streaming state so
// AppShell's global key handler stays out of the way while it's open. The answer
// renders with inline ⟨mm:ss⟩ citations (via askInline, mirroring the app), keeps
// whatever streamed so far if the stream errors, and scrolls when it's long.
export function AskScreen({
  recordingId,
  title,
  askRecording,
  onBack,
  onOpenTranscript,
  spinnerFrame,
}: {
  recordingId: string;
  title?: string;
  askRecording: (options: AskRecordingOptions) => AsyncIterable<AskStreamEvent>;
  onBack: () => void;
  onOpenTranscript?: () => void;
  spinnerFrame: number;
}): React.ReactElement {
  const size = useTerminalSize();
  const [phase, setPhase] = useState<AskPhase>("input");
  const [question, setQuestion] = useState("");
  const [asked, setAsked] = useState("");
  const [content, setContent] = useState("");
  const [citations, setCitations] = useState<AskCitation[]>([]);
  const [error, setError] = useState<string | undefined>(undefined);
  const [scroll, setScroll] = useState(0);
  // Bumped whenever we start/abandon a request so late stream events from a
  // superseded ask are ignored.
  const runIdRef = useRef(0);

  const submit = useCallback(
    (raw: string) => {
      const query = raw.trim();
      if (!query) return;
      const runId = ++runIdRef.current;
      setAsked(query);
      setPhase("asking");
      setContent("");
      setCitations([]);
      setError(undefined);
      setScroll(0);
      void (async () => {
        try {
          let text = "";
          let cites: AskCitation[] = [];
          for await (const event of askRecording({ recordingId, question: query })) {
            if (runIdRef.current !== runId) return; // superseded or left the screen
            if (event.type === "answer_delta") {
              text += event.delta;
              setContent(text);
            } else if (event.type === "citation") {
              cites = [...cites, event.citation];
              setCitations(cites);
            } else if (event.type === "done") {
              if (typeof event.content === "string" && event.content) {
                text = event.content;
                setContent(text);
              }
              if (event.citations.length) {
                cites = event.citations;
                setCitations(cites);
              }
            }
          }
          if (runIdRef.current === runId) setPhase("done");
        } catch (err) {
          // Keep whatever streamed so far — the partial answer is still useful;
          // surface the error beneath it rather than wiping the output.
          if (runIdRef.current === runId) {
            setError(err instanceof Error ? err.message : String(err));
            setPhase("error");
          }
        }
      })();
    },
    [askRecording, recordingId],
  );

  const reset = () => {
    runIdRef.current++;
    setPhase("input");
    setQuestion("");
    setAsked("");
    setContent("");
    setCitations([]);
    setError(undefined);
    setScroll(0);
  };

  // The answer text for the current phase. On done we place inline ⟨mm:ss⟩
  // citations + a Sources list; while streaming/erroring we show the raw text
  // with markers stripped (citations only resolve at the end).
  const answerText =
    phase === "done"
      ? formatAskAnswerPlain(content, citations)
      : content
        ? strippedAskAnswer(content)
        : "";

  const innerWidth = Math.max(10, size.columns - 2);
  const lines = answerText ? wrapToLines(answerText, innerWidth) : [];
  // Rows left for the answer pane after the fixed chrome (header, question,
  // error line, indicator, footer, margins).
  const paneBudget = Math.max(3, size.rows - 9);
  const maxScroll = Math.max(0, lines.length - paneBudget);
  // Auto-follow the tail while streaming; let the reader control it afterwards.
  const effectiveScroll = phase === "asking" ? maxScroll : Math.min(scroll, maxScroll);
  const windowLines = lines.slice(effectiveScroll, effectiveScroll + paneBudget);
  const page = Math.max(1, paneBudget - 1);

  useInput((input, key) => {
    if (key.escape) {
      runIdRef.current++; // stop consuming the stream
      onBack();
      return;
    }
    if (phase === "input") {
      if (key.return) return submit(question);
      if (key.backspace || key.delete) return setQuestion((q) => q.slice(0, -1));
      if (input && !key.ctrl && !key.meta) setQuestion((q) => q + input);
      return;
    }
    // Scroll the answer (done / error / asking).
    if (key.downArrow || input === "j") setScroll((s) => Math.min(maxScroll, s + 1));
    else if (key.upArrow || input === "k") setScroll((s) => Math.max(0, s - 1));
    else if (key.pageDown || input === " ") setScroll((s) => Math.min(maxScroll, s + page));
    else if (key.pageUp || input === "b") setScroll((s) => Math.max(0, s - page));
    else if (input === "g") setScroll(0);
    else if (input === "G") setScroll(maxScroll);
    else if (input === "a") reset();
    else if (input === "t" && onOpenTranscript) onOpenTranscript();
  });

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text dimColor>‹ Ask{title ? ` · ${title}` : ""}</Text>

      {phase === "input" ? (
        <Box marginTop={1} flexDirection="column">
          <Text>
            <Text color="cyan">? </Text>
            <Text>{question}</Text>
            <Text color="cyan">▏</Text>
          </Text>
          <Box marginTop={1}>
            <Text dimColor>Type a question · ⏎ ask · esc back</Text>
          </Box>
        </Box>
      ) : (
        <Box marginTop={1} flexDirection="column">
          <Text dimColor wrap="truncate-end">{`? ${asked}`}</Text>
          <Box marginTop={1} flexDirection="column">
            {phase === "asking" && !content ? (
              <Text color="cyan">{`${SPINNER[spinnerFrame % SPINNER.length]} Thinking…`}</Text>
            ) : (
              windowLines.map((line, i) => <AnswerLine key={effectiveScroll + i} line={line} />)
            )}
          </Box>
          {maxScroll > 0 ? (
            <Text dimColor>{`  ${Math.min(effectiveScroll + paneBudget, lines.length)} / ${lines.length}${phase === "asking" ? " · streaming" : " · ↑↓ scroll"}`}</Text>
          ) : null}
          {phase === "error" ? (
            <Box marginTop={1}>
              <Text color="red">{error ? `Ask failed: ${error}` : "Ask failed"}</Text>
            </Box>
          ) : null}
          <Box marginTop={1}>
            <Text dimColor>
              {phase === "asking" ? "esc cancel" : "a ask again"}
              {(phase === "done" || phase === "error") && onOpenTranscript ? " · t transcript" : ""}
              {maxScroll > 0 ? " · ↑↓ scroll" : ""}
              {phase !== "asking" ? " · esc back" : ""}
            </Text>
          </Box>
        </Box>
      )}
    </Box>
  );
}

// Render one wrapped line, coloring any inline ⟨mm:ss⟩ citation markers.
function AnswerLine({ line }: { line: string }): React.ReactElement {
  if (line === "") return <Text> </Text>;
  const parts = line.split(/(⟨[^⟩]*⟩)/);
  return (
    <Text>
      {parts.map((part, i) =>
        part.startsWith("⟨") && part.endsWith("⟩") ? (
          <Text key={i} color="cyan">{part}</Text>
        ) : (
          <Text key={i}>{part}</Text>
        ),
      )}
    </Text>
  );
}

// Character-based wrap that respects display width (CJK counts as 2) and keeps
// explicit newlines, so we can window/scroll the answer by line.
function wrapToLines(text: string, width: number): string[] {
  const out: string[] = [];
  for (const paragraph of text.split("\n")) {
    if (paragraph === "") {
      out.push("");
      continue;
    }
    let current = "";
    let currentWidth = 0;
    for (const ch of paragraph) {
      const w = displayWidth(ch);
      if (current !== "" && currentWidth + w > width) {
        out.push(current);
        current = ch;
        currentWidth = w;
      } else {
        current += ch;
        currentWidth += w;
      }
    }
    out.push(current);
  }
  return out;
}
