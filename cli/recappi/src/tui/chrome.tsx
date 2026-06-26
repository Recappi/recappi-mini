import React from "react";
import { Box, Text } from "ink";

export type TabKey = "overview" | "jobs" | "account" | "record";

// Top bar: brand + numbered tabs. Overview is the recordings workbench; Jobs is
// the transcription queue. Record is an action (`n`), not a tab.
// Palette: green = recappi brand, cyan = interactive (active tab / keys),
// dim = inactive/secondary.
export function Header({ active }: { active: TabKey }): React.ReactElement {
  return (
    <Box>
      <Text bold color="green">
        ● Recappi{"   "}
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
  // Active tab: inverse cyan pill. Inactive: dimmed so the active one pops, with
  // the number kept cyan as a scannable accent.
  if (active) {
    return (
      <Text bold inverse color="cyan">
        {` ${num} ${label} `}
      </Text>
    );
  }
  return (
    <Text dimColor>
      {" "}
      <Text color="cyan">{num}</Text>
      {` ${label} `}
    </Text>
  );
}

// Bottom key hints. Callers pass a " · "-separated keys string; we accent each
// key token (cyan) and dim its description so the actionable letters stand out.
export function Footer({ keys }: { keys: string }): React.ReactElement {
  const segments = keys.split(" · ");
  return (
    <Box marginTop={1}>
      <Text>
        {segments.map((segment, i) => {
          const space = segment.indexOf(" ");
          const key = space === -1 ? segment : segment.slice(0, space);
          const desc = space === -1 ? "" : segment.slice(space);
          return (
            <Text key={`${segment}-${i}`}>
              {i > 0 ? <Text dimColor>{" · "}</Text> : null}
              <Text color="cyan">{key}</Text>
              <Text dimColor>{desc}</Text>
            </Text>
          );
        })}
      </Text>
    </Box>
  );
}
