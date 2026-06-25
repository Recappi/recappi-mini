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
      {/* Compact status bar — doesn't take list space. */}
      <Box>
        <Text dimColor>Recordings </Text>
        <Text bold>{stats?.recordings.total ?? recordings.length}</Text>
        {stats?.recordings.ready != null ? (
          <Text dimColor>{`  ·  ${stats.recordings.ready} ready`}</Text>
        ) : null}
        {stats?.recordings.totalDurationMs != null ? (
          <Text dimColor>{`  ·  ${formatClockMs(stats.recordings.totalDurationMs)} transcribed`}</Text>
        ) : null}
        {running > 0 ? <Text color="cyan">{`  ·  ${running} transcribing`}</Text> : null}
        {queued > 0 ? <Text color="yellow">{`  ·  ${queued} queued`}</Text> : null}
      </Box>

      <Box flexDirection="row" alignItems="flex-start">
        <Box flexGrow={1} flexDirection="column">
          <RecordingsView
            items={recordings}
            selectedIndex={selectedIndex}
            nowMs={nowMs}
            columns={columns}
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
