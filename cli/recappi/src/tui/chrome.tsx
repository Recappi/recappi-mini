import React from "react";
import { Box, Text } from "ink";

export type TabKey = "overview" | "jobs" | "account" | "record";

// Top bar: brand + numbered tabs. Overview is the recordings workbench; Jobs is
// the transcription queue. Record is an action (`n`), not a tab.
export function Header({ active }: { active: TabKey }): React.ReactElement {
  return (
    <Box>
      <Text bold color="magenta">
        Recappi{"  "}
      </Text>
      <Tab num="1" label="Overview" active={active === "overview"} />
      <Tab num="2" label="Jobs" active={active === "jobs"} />
      <Tab num="3" label="Account" active={active === "account"} />
    </Box>
  );
}

function Tab({
  num,
  label,
  active,
}: {
  num: string;
  label: string;
  active: boolean;
}): React.ReactElement {
  const text = ` ${num} ${label} `;
  if (active) {
    return (
      <Text bold inverse color="cyan">
        {text}
      </Text>
    );
  }
  return <Text>{text}</Text>;
}

// Bottom key hints. Callers pass the context-specific keys.
export function Footer({ keys }: { keys: string }): React.ReactElement {
  return (
    <Box marginTop={1}>
      <Text dimColor>{keys}</Text>
    </Box>
  );
}
