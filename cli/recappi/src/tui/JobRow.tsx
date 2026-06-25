import React from "react";
import { Box, Text } from "ink";
import type { JobListItem } from "../../../packages/contracts/src/index";
import { jobDetail, padCell, statusGlyph, statusStyle } from "./format";

// One job row, shared by the Jobs list and the Overview "active" section so the
// two surfaces look identical.
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
      <Text color="cyan">{selected ? "▸ " : "  "}</Text>
      <Text color={style.color}>{`${glyph} ${padCell(style.label, 13)}`}</Text>
      <Text bold={selected}>{padCell(title, 24)}</Text>
      <Text dimColor={!selected}>{jobDetail(item)}</Text>
    </Box>
  );
}
