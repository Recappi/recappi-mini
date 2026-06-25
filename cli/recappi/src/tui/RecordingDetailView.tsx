import React, { useMemo, useState } from "react";
import { Box, Text, useInput } from "ink";
import type {
  RecordingData,
  TranscriptData,
  TranscriptSegment,
  TranscriptSummary,
} from "../../../packages/contracts/src/index";
import {
  displayWidth,
  formatAge,
  formatBytes,
  formatClockMs,
  listWindow,
  recordingStatusStyle,
  resolveRecordingLinks,
  windowByHeights,
} from "./format";
import { recordingTitle } from "./RecordingRow";
import { useTerminalSize } from "./terminal";

// View-model for the audio download/open action. The runtime (download + macOS
// `open`) maps its progress onto this; presentation owns the shape.
export interface AudioAction {
  status: "idle" | "downloading" | "ready" | "opening" | "error";
  localPath?: string;
  error?: string;
}

// The transcript may still be loading or have failed to load when the detail
// screen opens; mirror the peek's lazy-load states.
export type DetailTranscript = TranscriptData | "loading" | "error" | undefined;

type DetailTab = "summary" | "chapters" | "transcript";
const TAB_ORDER: DetailTab[] = ["summary", "chapters", "transcript"];
const TAB_LABEL: Record<DetailTab, string> = {
  summary: "Summary",
  chapters: "Chapters",
  transcript: "Transcript",
};

// Inspector for a single recording, styled after the macOS app's detail screen:
// a fixed title header + audio action, then switchable Summary / Chapters /
// Transcript tabs (Tab cycles; the Transcript tab scrolls inline).
export function RecordingDetailView({
  item,
  nowMs,
  transcript,
  audio,
}: {
  item: RecordingData;
  nowMs: number;
  transcript?: DetailTranscript;
  audio?: AudioAction;
}): React.ReactElement {
  const size = useTerminalSize();
  const [tab, setTab] = useState<DetailTab>("summary");
  const [scroll, setScroll] = useState(0);
  const [chapterSel, setChapterSel] = useState(0);

  const style = recordingStatusStyle(item.status);
  const links = resolveRecordingLinks(item.recordingId, item.origin);
  const title = recordingTitle(item);
  const meta = [
    item.durationMs ? formatClockMs(item.durationMs) : undefined,
    formatBytes(item.sizeBytes) || undefined,
    item.contentType || undefined,
  ]
    .filter(Boolean)
    .join("  ·  ");

  const ready = typeof transcript === "object";
  const summary = ready ? transcript.summary : undefined;
  const segments = ready ? transcript.segments : [];
  const chapters = summary?.timeline ?? [];

  // The scrollable pane is sized to the rows left after the fixed chrome.
  const innerWidth = Math.max(10, size.columns - 2);
  const paneBudget = Math.max(3, size.rows - 12);

  // Transcript pane: variable-height scroll window over segments.
  const segHeights = useMemo(
    () =>
      segments.map((seg) => {
        const prefix = `[${formatClockMs(seg.startMs)}] ${seg.speaker ? `${seg.speaker}: ` : ""}`;
        return Math.max(1, Math.ceil(displayWidth(prefix + seg.text) / innerWidth));
      }),
    [segments, innerWidth],
  );
  const segWin = windowByHeights(segHeights, scroll, paneBudget);
  // Chapters pane: one row each, a simple selection window that follows the cursor.
  const chapWin = listWindow(Math.min(chapterSel, Math.max(0, chapters.length - 1)), chapters.length, paneBudget);
  const page = Math.max(1, paneBudget - 1);
  const scrollable = tab === "transcript" ? segWin.maxScroll > 0 : false;

  // Jump from a chapter to the transcript at its start time.
  const jumpToChapter = (index: number) => {
    const chapter = chapters[index];
    if (!chapter) return;
    const found = segments.findIndex((s) => s.startMs >= chapter.startMs);
    setScroll(found < 0 ? Math.max(0, segments.length - 1) : found);
    setTab("transcript");
  };

  useInput((input, key) => {
    if (!item.activeTranscriptId || !ready) return;
    if (key.tab) {
      setTab((t) => TAB_ORDER[(TAB_ORDER.indexOf(t) + (key.shift ? TAB_ORDER.length - 1 : 1)) % TAB_ORDER.length]!);
      return;
    }
    if (tab === "summary") return;
    if (tab === "chapters") {
      if (key.downArrow || input === "j") setChapterSel((i) => Math.min(chapters.length - 1, i + 1));
      else if (key.upArrow || input === "k") setChapterSel((i) => Math.max(0, i - 1));
      else if (key.return || key.rightArrow) jumpToChapter(chapterSel);
      return;
    }
    // transcript pane scroll
    if (key.downArrow || input === "j") setScroll((s) => Math.min(segWin.maxScroll, s + 1));
    else if (key.upArrow || input === "k") setScroll((s) => Math.max(0, s - 1));
    else if (key.pageDown || input === " ") setScroll((s) => Math.min(segWin.maxScroll, s + page));
    else if (key.pageUp || input === "b") setScroll((s) => Math.max(0, s - page));
    else if (input === "g") setScroll(0);
    else if (input === "G") setScroll(segWin.maxScroll);
  });

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text dimColor>‹ Recordings</Text>

      {/* Title header */}
      <Box marginTop={1}>
        <Text bold color="magenta">
          {title}
        </Text>
      </Box>
      <Text>
        <Text color={style.color}>{`${style.glyph} ${style.label}`}</Text>
        <Text dimColor>{`   ${formatAge(item.createdAt, nowMs) || "—"}`}</Text>
      </Text>
      {meta ? <Text dimColor>{meta}</Text> : null}

      {/* Audio download / open */}
      <AudioActionRow item={item} audio={audio} />

      {/* Section content */}
      {!item.activeTranscriptId ? (
        <Box marginTop={1}>
          <Text dimColor>Transcript not available yet</Text>
        </Box>
      ) : transcript === "loading" || transcript === undefined ? (
        <Box marginTop={1}>
          <Text dimColor>Loading…</Text>
        </Box>
      ) : transcript === "error" ? (
        <Box marginTop={1}>
          <Text dimColor>(transcript unavailable)</Text>
        </Box>
      ) : (
        <>
          <TabBar active={tab} />
          <Box marginTop={1} flexDirection="column">
            {tab === "summary" ? (
              <SummaryPane summary={summary} budget={paneBudget} />
            ) : tab === "chapters" ? (
              <ChaptersPane chapters={chapters} win={chapWin} selectedIndex={chapterSel} />
            ) : (
              <TranscriptPane segments={segments} win={segWin} />
            )}
          </Box>
        </>
      )}

      <Box marginTop={1}>
        <Text dimColor>
          {ready ? "tab switch" : ""}
          {ready && tab === "chapters" ? " · ↑↓ select · ⏎ jump" : ""}
          {scrollable ? " · ↑↓ scroll" : ""}
          {ready ? " · " : ""}
          {`o open · d download · f finder`}
          {item.activeTranscriptId ? " · t full" : ""}
          {links.webUrl ? " · w web" : ""}
          {" · esc back"}
        </Text>
      </Box>
    </Box>
  );
}

function TabBar({ active }: { active: DetailTab }): React.ReactElement {
  return (
    <Box marginTop={1}>
      {TAB_ORDER.map((tab, i) => (
        <React.Fragment key={tab}>
          {i > 0 ? <Text dimColor>{"  "}</Text> : null}
          {tab === active ? (
            <Text inverse bold>{` ${TAB_LABEL[tab]} `}</Text>
          ) : (
            <Text dimColor>{` ${TAB_LABEL[tab]} `}</Text>
          )}
        </React.Fragment>
      ))}
    </Box>
  );
}

function AudioActionRow({
  item,
  audio,
}: {
  item: RecordingData;
  audio?: AudioAction;
}): React.ReactElement {
  const ready = item.status === "ready";
  const status = audio?.status ?? "idle";

  let line: React.ReactElement;
  if (!ready) {
    line = <Text dimColor>Audio available once the recording is ready</Text>;
  } else if (status === "downloading") {
    line = <Text color="cyan">Downloading audio…</Text>;
  } else if (status === "opening") {
    line = <Text color="cyan">Opening…</Text>;
  } else if (status === "error") {
    line = <Text color="red">{audio?.error ? `Audio failed: ${audio.error}` : "Audio failed"}</Text>;
  } else if (status === "ready" && audio?.localPath) {
    line = (
      <Text>
        <Text color="green">✓ Downloaded </Text>
        <Text dimColor wrap="truncate-middle">{audio.localPath}</Text>
      </Text>
    );
  } else {
    line = (
      <Text>
        <Text color="cyan">o</Text>
        <Text dimColor> open in player · </Text>
        <Text color="cyan">d</Text>
        <Text dimColor> download · </Text>
        <Text color="cyan">f</Text>
        <Text dimColor> reveal in Finder</Text>
      </Text>
    );
  }

  return (
    <Box marginTop={1} borderStyle="round" borderColor="gray" paddingX={1}>
      <Text color={ready ? "cyan" : "gray"}>{"♪ "}</Text>
      {line}
    </Box>
  );
}

function SummaryPane({
  summary,
  budget,
}: {
  summary?: TranscriptSummary;
  budget: number;
}): React.ReactElement {
  if (!summary || summary.status !== "succeeded" || !summary.tldr) {
    return <Text dimColor>{`Summary ${summary?.status ?? "unavailable"}`}</Text>;
  }
  const points = (summary.keyPoints ?? []).slice(0, Math.max(1, budget - 4));
  return (
    <>
      <Text>{summary.tldr}</Text>
      {points.length > 0 ? (
        <Box marginTop={1} flexDirection="column">
          {points.map((point, i) => (
            <Text key={i} dimColor>{`• ${point}`}</Text>
          ))}
        </Box>
      ) : null}
    </>
  );
}

function ChaptersPane({
  chapters,
  win,
  selectedIndex,
}: {
  chapters: NonNullable<TranscriptSummary["timeline"]>;
  win: { start: number; end: number };
  selectedIndex: number;
}): React.ReactElement {
  if (chapters.length === 0) return <Text dimColor>No chapters</Text>;
  return (
    <>
      {chapters.slice(win.start, win.end).map((chapter, i) => {
        const index = win.start + i;
        const selected = index === selectedIndex;
        return (
          <Text key={index} wrap="truncate-end">
            <Text color="cyan">{selected ? "▸ " : "  "}</Text>
            <Text color="blue">{`[${formatClockMs(chapter.startMs)}] `}</Text>
            <Text bold={selected}>{chapter.title}</Text>
          </Text>
        );
      })}
      {win.end < chapters.length || win.start > 0 ? (
        <Text dimColor>{`  ${selectedIndex + 1} / ${chapters.length}`}</Text>
      ) : null}
    </>
  );
}

function TranscriptPane({
  segments,
  win,
}: {
  segments: TranscriptSegment[];
  win: { start: number; end: number; maxScroll: number };
}): React.ReactElement {
  if (segments.length === 0) return <Text dimColor>(no segments)</Text>;
  return (
    <>
      {segments.slice(win.start, win.end).map((seg, i) => (
        <Text key={win.start + i}>
          <Text color="blue">{`[${formatClockMs(seg.startMs)}] `}</Text>
          {seg.speaker ? <Text dimColor>{`${seg.speaker}  `}</Text> : null}
          <Text>{seg.text}</Text>
        </Text>
      ))}
      {win.maxScroll > 0 ? (
        <Text dimColor>{`  ${win.start + 1}–${win.end} / ${segments.length}`}</Text>
      ) : null}
    </>
  );
}
