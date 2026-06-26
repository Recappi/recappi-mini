import React from "react";
import { Box, Text } from "ink";

// Runtime permission checks live in the recorder/doctor path; this view only
// renders their user-facing status and next step.
export type PermissionStatus = "granted" | "denied" | "unknown";

export interface PermissionItem {
  name: string;
  status: PermissionStatus;
  hint?: string;
  requiresProcessRestart?: boolean;
}

const DEFAULT_HINTS: Record<string, string> = {
  "Screen Recording":
    "Open System Settings › Privacy & Security › Screen Recording, enable Recappi Recorder, then run recappi record again.",
  Microphone:
    "Open System Settings › Privacy & Security › Microphone, enable Recappi Recorder, then run recappi record again.",
};

function statusGlyph(status: PermissionStatus): { glyph: string; color: string; label: string } {
  switch (status) {
    case "granted":
      return { glyph: "✓", color: "green", label: "granted" };
    case "denied":
      return { glyph: "✗", color: "red", label: "not allowed" };
    case "unknown":
      return { glyph: "○", color: "yellow", label: "not requested yet" };
  }
}

export function PermissionPreflightView({
  items,
}: {
  items: PermissionItem[];
}): React.ReactElement {
  const allGranted =
    items.length > 0 &&
    items.every((item) => item.status === "granted" && !item.requiresProcessRestart);
  const hasRestartRequired = items.some((item) => item.requiresProcessRestart);
  return (
    <Box flexDirection="column" paddingX={1}>
      <Text dimColor>‹ Recording permissions</Text>

      <Box marginTop={1} flexDirection="column">
        {items.length === 0 ? (
          <Text dimColor>Checking permissions…</Text>
        ) : (
          items.map((item) => {
            const status = statusGlyph(item.status);
            const hint = item.requiresProcessRestart
              ? item.hint ?? `${item.name} enabled. Run recappi record again to start.`
              : item.status === "granted"
                ? undefined
                : item.hint ?? DEFAULT_HINTS[item.name];
            return (
              <Box key={item.name} flexDirection="column">
                <Text>
                  <Text color={status.color}>{status.glyph}</Text>
                  <Text bold>{` ${item.name}`}</Text>
                  <Text dimColor>{`  ${status.label}`}</Text>
                </Text>
                {hint ? <Text dimColor>{`   ${hint}`}</Text> : null}
              </Box>
            );
          })
        )}
      </Box>

      <Box marginTop={1}>
        {allGranted ? (
          <Text color="green">All set — ready to record.</Text>
        ) : hasRestartRequired ? (
          <Text dimColor>Run recappi record again to start, or press r to retry.</Text>
        ) : (
          <Text dimColor>Grant the permissions above, then press r to recheck.</Text>
        )}
      </Box>

      <Box marginTop={1}>
        <Text dimColor>r recheck · o open System Settings · esc back</Text>
      </Box>
    </Box>
  );
}
