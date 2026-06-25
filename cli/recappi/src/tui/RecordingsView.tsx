import React from "react";
import { Box, Text } from "ink";
import type { RecordingData } from "../../../packages/contracts/src/index";
import { RecordingHeader, RecordingRow } from "./RecordingRow";
import { dateBucket } from "./format";

// Recordings tab body: the full recording list, grouped by date (Today /
// Yesterday / Earlier) like the macOS app, with per-row processing status.
// Selection + windowing live in the shell.
export function RecordingsView({
  items,
  selectedIndex,
  nowMs,
  columns,
  jobStatusByRecording,
  downloadedRecordingIds,
  spinnerFrame = 0,
}: {
  items: RecordingData[];
  selectedIndex: number;
  nowMs: number;
  columns: number;
  jobStatusByRecording?: Map<string, string>;
  downloadedRecordingIds?: Set<string>;
  spinnerFrame?: number;
}): React.ReactElement {
  if (items.length === 0) {
    return (
      <Box marginTop={1}>
        <Text dimColor>No recordings yet — run: recappi upload &lt;file&gt;</Text>
      </Box>
    );
  }
  return (
    <Box marginTop={1} flexDirection="column">
      <RecordingHeader columns={columns} />
      {items.map((item, index) => {
        const bucket = dateBucket(item.createdAt, nowMs);
        const showHeader = index === 0 || bucket !== dateBucket(items[index - 1]!.createdAt, nowMs);
        return (
          <React.Fragment key={item.recordingId}>
            {showHeader ? (
              <Box marginTop={index === 0 ? 0 : 1}>
                <Text bold color="blue">
                  {bucket}
                </Text>
              </Box>
            ) : null}
            <RecordingRow
              item={item}
              selected={index === selectedIndex}
              nowMs={nowMs}
              columns={columns}
              jobStatus={jobStatusByRecording?.get(item.recordingId)}
              downloaded={downloadedRecordingIds?.has(item.recordingId) ?? false}
              spinnerFrame={spinnerFrame}
            />
          </React.Fragment>
        );
      })}
    </Box>
  );
}
