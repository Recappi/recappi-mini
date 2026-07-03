import React, { useCallback, useRef, useState } from "react";
import { Box, Text, useInput } from "ink";
import type { AskCitation, AskRecordingOptions, AskStreamEvent } from "../api";
import {
  askCitationInlineLabel,
  renderAskInline,
  strippedAskAnswer,
} from "./askInline";

type AskPhase = "input" | "asking" | "done" | "error";

const SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";

// Interactive "Ask this recording" screen. Owns its own input/streaming state so
// AppShell's global key handler stays out of the way while it's open. The answer
// renders with inline ⟨mm:ss⟩ citations (via askInline, mirroring the app) plus a
// Sources list.
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
  const [phase, setPhase] = useState<AskPhase>("input");
  const [question, setQuestion] = useState("");
  const [asked, setAsked] = useState("");
  const [content, setContent] = useState("");
  const [citations, setCitations] = useState<AskCitation[]>([]);
  const [error, setError] = useState<string | undefined>(undefined);
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
  };

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
    if (phase === "done" || phase === "error") {
      if (input === "a") return reset();
      if (input === "t" && onOpenTranscript) return onOpenTranscript();
    }
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
            <AnswerBody phase={phase} content={content} citations={citations} error={error} spinnerFrame={spinnerFrame} />
          </Box>
          {phase === "done" ? <Sources citations={citations} /> : null}
          <Box marginTop={1}>
            <Text dimColor>
              {phase === "asking" ? "esc cancel" : "a ask again"}
              {(phase === "done" || phase === "error") && onOpenTranscript ? " · t transcript" : ""}
              {phase !== "asking" ? " · esc back" : ""}
            </Text>
          </Box>
        </Box>
      )}
    </Box>
  );
}

function AnswerBody({
  phase,
  content,
  citations,
  error,
  spinnerFrame,
}: {
  phase: AskPhase;
  content: string;
  citations: AskCitation[];
  error?: string;
  spinnerFrame: number;
}): React.ReactElement {
  if (phase === "error") {
    return <Text color="red">{error ? `Ask failed: ${error}` : "Ask failed"}</Text>;
  }
  if (phase === "asking" && !content) {
    return <Text color="cyan">{`${SPINNER[spinnerFrame % SPINNER.length]} Thinking…`}</Text>;
  }
  if (phase === "asking") {
    // Live typewriter: strip markers until we can place them on `done`.
    return <Text>{strippedAskAnswer(content)}</Text>;
  }
  // done: inline citations placed next to their sentence.
  const segments = renderAskInline(content, citations);
  return (
    <Text>
      {segments.map((segment, i) =>
        segment.kind === "text" ? (
          <Text key={i}>{segment.text}</Text>
        ) : (
          <Text key={i} color="cyan">{`⟨${segment.label}⟩`}</Text>
        ),
      )}
    </Text>
  );
}

function Sources({ citations }: { citations: AskCitation[] }): React.ReactElement | null {
  const seen = new Set<string>();
  const unique: AskCitation[] = [];
  for (const citation of citations) {
    const key = citation.segmentId ?? askCitationInlineLabel(citation);
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(citation);
  }
  if (unique.length === 0) return null;
  return (
    <Box marginTop={1} flexDirection="column">
      <Text dimColor>Sources</Text>
      {unique.map((citation, i) => {
        const meta = [citation.speaker?.trim(), citation.snippet?.trim()].filter(Boolean).join(" · ");
        return (
          <Text key={i} wrap="truncate-end">
            <Text color="cyan">{`⟨${askCitationInlineLabel(citation)}⟩`}</Text>
            {meta ? <Text dimColor>{` ${meta}`}</Text> : null}
          </Text>
        );
      })}
    </Box>
  );
}
