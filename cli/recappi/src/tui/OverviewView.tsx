import React from "react";
import { Box, Text } from "ink";
import type {
  DashboardStatsData,
  JobListItem,
  RecordingData,
} from "../../../packages/contracts/src/index";
import { RecordingsView } from "./RecordingsView";
import { RecordingPeek } from "./RecordingPeek";
import type { PeekSummary } from "./AppShell";
import { countJobs, formatClockMs } from "./format";

// Overview is the recordings workbench: a compact stats bar on top, then the
// full (windowed) date-grouped recordings list as the main body.
export function OverviewView({
  recordings,
  jobs,
  stats,
  selectedIndex,
  spinnerFrame,
  nowMs,
  columns,
  jobStatusByRecording,
  downloadedRecordingIds,
  peekItem,
  peekSummary,
  showPeek = false,
  peekWidth = 0,
}: {
  recordings: RecordingData[];
  jobs: JobListItem[];
  stats?: DashboardStatsData;
  selectedIndex: number;
  spinnerFrame: number;
  nowMs: number;
  columns: number;
  jobStatusByRecording?: Map<string, string>;
  downloadedRecordingIds?: Set<string>;
  peekItem?: RecordingData;
  peekSummary?: PeekSummary;
  showPeek?: boolean;
  peekWidth?: number;
}): React.ReactElement {
  const jobCounts = countJobs(jobs);
  const running = stats?.jobs.running ?? jobCounts.running;
  const queued = stats?.jobs.queued ?? jobCounts.queued;

  return (
    <Box flexDirection="column">
      {/* Compact status bar — headline count leads, each stat carries its own
          semantic color (green ready · cyan transcribing · yellow queued),
          secondary totals stay dim. Doesn't take list space. */}
      <Box>
        <Text bold>{stats?.recordings.total ?? recordings.length}</Text>
        <Text dimColor> recordings</Text>
        {stats?.recordings.ready != null ? (
          <>
            <Text dimColor>{"  ·  "}</Text>
            <Text color="green">{`${stats.recordings.ready} ready`}</Text>
          </>
        ) : null}
        {running > 0 ? (
          <>
            <Text dimColor>{"  ·  "}</Text>
            <Text color="cyan">{`${running} transcribing`}</Text>
          </>
        ) : null}
        {queued > 0 ? (
          <>
            <Text dimColor>{"  ·  "}</Text>
            <Text color="yellow">{`${queued} queued`}</Text>
          </>
        ) : null}
        {stats?.recordings.totalDurationMs != null ? (
          <Text dimColor>{`  ·  ${formatClockMs(stats.recordings.totalDurationMs)} transcribed`}</Text>
        ) : null}
      </Box>

      <Box flexDirection="row" alignItems="flex-start">
        <Box flexGrow={1} flexDirection="column">
          <RecordingsView
            items={recordings}
            selectedIndex={selectedIndex}
            nowMs={nowMs}
            // When the peek panel is shown it eats width on the right; budget the
            // list columns against the space that actually remains (peek width +
            // its left margin) so rows don't overflow and wrap the WHEN column.
            columns={showPeek ? Math.max(20, columns - peekWidth - 1) : columns}
            jobStatusByRecording={jobStatusByRecording}
            downloadedRecordingIds={downloadedRecordingIds}
            spinnerFrame={spinnerFrame}
          />
        </Box>
        {showPeek ? (
          <Box marginLeft={1} marginTop={1}>
            <RecordingPeek item={peekItem} summary={peekSummary} nowMs={nowMs} width={peekWidth} />
          </Box>
        ) : null}
      </Box>
    </Box>
  );
}
