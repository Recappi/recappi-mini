import React from "react";
import { Box, Text } from "ink";
import type { JobListItem } from "../../../packages/contracts/src/index";
import { jobDetail, statusGlyph, statusStyle } from "./format";

// One job row, shared by the Jobs list and the Overview "active" section so the
// two surfaces look identical. Fixed-width Box columns (marker · glyph · status ·
// title · detail) keep it aligned at every width and matched to RecordingRow.
export function JobRow({
  item,
  selected,
  spinnerFrame,
}: {
  item: JobListItem;
  selected: boolean;
  spinnerFrame: number;
}): React.ReactElement {
  const style = statusStyle(item.status);
  const glyph = statusGlyph(item.status, spinnerFrame);
  const title = item.recording?.title ?? item.recordingId;
  return (
    <Box>
      <Box width={3}><Text color="cyan">{selected ? "▸" : ""}</Text></Box>
      <Box width={2}><Text color={style.color}>{glyph}</Text></Box>
      <Box width={13}><Text color={style.color}>{style.label}</Text></Box>
      <Box width={26}><Text bold={selected} wrap="truncate-end">{title}</Text></Box>
      <Text dimColor={!selected}>{jobDetail(item)}</Text>
    </Box>
  );
}
