import React from "react";
import { Box, Text } from "ink";
import type { JobListItem } from "../../../packages/contracts/src/index";
import { JobRow } from "./JobRow";

// Jobs tab body: the full job list. Selection + key handling live in the shell.
export function JobsView({
  items,
  selectedIndex,
  spinnerFrame,
  nowMs,
}: {
  items: JobListItem[];
  selectedIndex: number;
  spinnerFrame: number;
  nowMs?: number;
}): React.ReactElement {
  if (items.length === 0) {
    return (
      <Box marginTop={1}>
        <Text dimColor>
          No transcription jobs yet — run: recappi upload &lt;file&gt; --transcribe
        </Text>
      </Box>
    );
  }
  return (
    <Box marginTop={1} flexDirection="column">
      {items.map((item, index) => (
        <JobRow
          key={item.jobId}
          item={item}
          selected={index === selectedIndex}
          spinnerFrame={spinnerFrame}
          nowMs={nowMs}
        />
      ))}
    </Box>
  );
}
