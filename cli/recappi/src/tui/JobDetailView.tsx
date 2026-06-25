import React from "react";
import { Box, Text } from "ink";
import type { JobListItem } from "../../../packages/contracts/src/index";
import {
  formatAge,
  formatClockMs,
  progressBar,
  resolveJobLinks,
  statusStyle,
  transcribeFraction,
} from "./format";

// Inspector / action panel for a single job: a status card, a timeline, the
// recording it belongs to, and an open/links footer. Richer than a metadata
// dump so the dashboard feels like an inspector, not a DB browser.
export function JobDetailView({
  item,
  origin,
  spinnerFrame,
  nowMs,
}: {
  item: JobListItem;
  origin: string;
  spinnerFrame: number;
  nowMs: number;
}): React.ReactElement {
  const style = statusStyle(item.status);
  const links = resolveJobLinks(item, origin);
  const title = item.recording?.title ?? item.recordingId;

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text dimColor>‹ Jobs / {title}</Text>

      <Box
        marginTop={1}
        borderStyle="round"
        borderColor={style.color}
        paddingX={1}
        flexDirection="column"
      >
        <Text color={style.color} bold>
          {style.label}
          {item.provider ? <Text dimColor>{`   ${item.provider}`}</Text> : null}
        </Text>
        <StatusLine item={item} spinnerFrame={spinnerFrame} nowMs={nowMs} />
      </Box>

      <Box marginTop={1} flexDirection="column">
        <Text bold>Timeline</Text>
        <TimelineRow
          label="Enqueued"
          done={item.enqueuedAt != null}
          at={item.enqueuedAt}
          nowMs={nowMs}
        />
        <TimelineRow
          label="Started"
          done={item.startedAt != null}
          at={item.startedAt}
          nowMs={nowMs}
        />
        <TimelineRow
          label={
            item.status === "failed"
              ? "Failed"
              : item.status === "running"
                ? "Transcribing"
                : "Finished"
          }
          done={item.finishedAt != null}
          failed={item.status === "failed"}
          running={item.status === "running"}
          at={item.finishedAt}
          nowMs={nowMs}
        />
      </Box>

      <Box marginTop={1}>
        <Text>
          <Text dimColor>Recording </Text>
          {title}
          {item.recording?.durationMs ? (
            <Text dimColor>{`  ·  ${formatClockMs(item.recording.durationMs)}`}</Text>
          ) : null}
        </Text>
      </Box>

      <Box marginTop={1} borderStyle="round" borderColor="gray" paddingX={1}>
        <Text>
          <Text color={links.webUrl ? "cyan" : "gray"}>o open</Text>
          <Text dimColor> · </Text>
          <Text color={links.webUrl ? "cyan" : "gray"}>w web</Text>
          <Text dimColor> · </Text>
          <Text dimColor>m mac app (soon)</Text>
          <Text dimColor> · </Text>
          <Text color={links.webUrl ? "cyan" : "gray"}>c copy</Text>
        </Text>
      </Box>

      <Box marginTop={1}>
        <Text dimColor>
          esc back · t transcript{item.transcriptId ? "" : " (when ready)"} · q quit
        </Text>
      </Box>
    </Box>
  );
}

function StatusLine({
  item,
  spinnerFrame,
  nowMs,
}: {
  item: JobListItem;
  spinnerFrame: number;
  nowMs: number;
}): React.ReactElement {
  if (item.status === "running") {
    const fraction = transcribeFraction(item);
    const elapsed = item.startedAt ? `  ·  ${formatClockMs(nowMs - item.startedAt)} elapsed` : "";
    if (fraction != null) {
      const pct = Math.round(fraction * 100);
      return (
        <Text>
          {`${progressBar(fraction)} ${pct}%  ${formatClockMs(item.processedDurationMs)} / ${formatClockMs(
            item.recording?.durationMs,
          )}`}
          <Text dimColor>{elapsed}</Text>
        </Text>
      );
    }
    const spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"][spinnerFrame % 10];
    return (
      <Text>
        {`${spinner} transcribing…`}
        <Text dimColor>{elapsed}</Text>
      </Text>
    );
  }
  if (item.status === "succeeded")
    return <Text>{item.transcriptId ? "transcript ready" : "done"}</Text>;
  if (item.status === "queued") return <Text dimColor>waiting to start…</Text>;
  if (item.status === "failed") return <Text color="red">transcription failed</Text>;
  return <Text dimColor>{item.status}</Text>;
}

function TimelineRow({
  label,
  done,
  failed,
  running,
  at,
  nowMs,
}: {
  label: string;
  done: boolean;
  failed?: boolean;
  running?: boolean;
  at?: number | null;
  nowMs: number;
}): React.ReactElement {
  const glyph = failed ? "✗" : done ? "✓" : running ? "⠋" : "○";
  const color = failed ? "red" : done ? "green" : running ? "cyan" : "gray";
  const age = at ? formatAge(at, nowMs) : running ? "now" : "";
  return (
    <Box>
      <Text color={color}>{`  ${glyph} `}</Text>
      <Text dimColor={!done && !running}>{label}</Text>
      {age ? <Text dimColor>{`   ${age}`}</Text> : null}
    </Box>
  );
}
