import React from "react";
import { Box, Text } from "ink";
import type { RecordingData } from "../../../packages/contracts/src/index";
import type { PeekSummary } from "./AppShell";
import { formatAge, formatBytes, formatClockMs, recordingStatusStyle } from "./format";
import { recordingTitle } from "./RecordingRow";

// A summary "peek" panel for the selected recording: metadata + the lazily
// loaded transcript summary (tldr + key points). Sizes to its content (the
// parent row aligns to flex-start) so it doesn't stretch to full height.
export function RecordingPeek({
  item,
  summary,
  nowMs,
  width,
}: {
  item?: RecordingData;
  summary?: PeekSummary;
  nowMs: number;
  width: number;
}): React.ReactElement {
  return (
    <Box width={width} borderStyle="round" borderColor="gray" paddingX={1} flexDirection="column">
      {!item ? (
        <Text dimColor>No selection</Text>
      ) : (
        <PeekBody item={item} summary={summary} nowMs={nowMs} />
      )}
    </Box>
  );
}

function PeekBody({
  item,
  summary,
  nowMs,
}: {
  item: RecordingData;
  summary?: PeekSummary;
  nowMs: number;
}): React.ReactElement {
  const style = recordingStatusStyle(item.status);
  const meta = [
    item.durationMs ? formatClockMs(item.durationMs) : null,
    formatBytes(item.sizeBytes) || null,
    formatAge(item.createdAt, nowMs),
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <>
      <Text bold wrap="truncate-end">
        {recordingTitle(item)}
      </Text>
      {/* Status keeps its meaning-color; duration · size · age ride alongside, dim. */}
      <Box>
        <Text color={style.color}>{`${style.glyph} ${style.label}`}</Text>
        {meta ? <Text dimColor>{`  ${meta}`}</Text> : null}
      </Box>

      <Box marginTop={1} flexDirection="column">
        <SummarySection item={item} summary={summary} />
      </Box>

      <Box marginTop={1}>
        <Text dimColor>⏎ open · t transcript · o web</Text>
      </Box>
    </>
  );
}

function SummarySection({
  item,
  summary,
}: {
  item: RecordingData;
  summary?: PeekSummary;
}): React.ReactElement {
  if (!item.activeTranscriptId) return <Text dimColor>No transcript yet</Text>;
  if (summary === "loading" || summary === undefined) return <Text dimColor>Loading summary…</Text>;
  if (summary === "error") return <Text dimColor>(summary unavailable)</Text>;
  if (summary.status !== "succeeded" || !summary.tldr) {
    return <Text dimColor>{`Summary ${summary.status}`}</Text>;
  }
  const points = (summary.keyPoints ?? []).slice(0, 3);
  return (
    <>
      <Text dimColor>SUMMARY</Text>
      <Text>{summary.tldr}</Text>
      {points.length > 0 ? (
        <Box marginTop={1} flexDirection="column">
          {points.map((point, i) => (
            <Text key={i} dimColor wrap="truncate-end">
              {`• ${point}`}
            </Text>
          ))}
        </Box>
      ) : null}
    </>
  );
}
