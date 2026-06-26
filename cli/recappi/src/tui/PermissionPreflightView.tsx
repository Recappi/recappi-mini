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
      <Text>
        <Text dimColor>‹ </Text>
        <Text bold color="cyan">Recording permissions</Text>
      </Text>

      <Box marginTop={1} flexDirection="column">
        {items.length === 0 ? (
          <Text dimColor>Checking permissions…</Text>
        ) : (
          items.map((item) => {
            const status = statusGlyph(item.status);
            // A granted permission that still needs a process restart isn't ready
            // yet → color it "attention" (yellow), not "done" (green).
            const restart = item.requiresProcessRestart === true;
            const color = restart ? "yellow" : status.color;
            const hint = restart
              ? item.hint ?? `${item.name} enabled. Run recappi record again to start.`
              : item.status === "granted"
                ? undefined
                : item.hint ?? DEFAULT_HINTS[item.name];
            return (
              <Box key={item.name} flexDirection="column">
                <Text>
                  <Text bold color={color}>{status.glyph}</Text>
                  <Text bold>{` ${item.name}`}</Text>
                  <Text color={color}>{`  ${status.label}`}</Text>
                </Text>
                {hint ? <Text dimColor>{`   ${hint}`}</Text> : null}
              </Box>
            );
          })
        )}
      </Box>

      <Box marginTop={1}>
        {allGranted ? (
          <Text bold color="green">✓ All set — ready to record.</Text>
        ) : hasRestartRequired ? (
          <Text>
            <Text dimColor>Run recappi record again to start, or press </Text>
            <Text bold color="cyan">r</Text>
            <Text dimColor> to retry.</Text>
          </Text>
        ) : (
          <Text>
            <Text dimColor>Grant the permissions above, then press </Text>
            <Text bold color="cyan">r</Text>
            <Text dimColor> to recheck.</Text>
          </Text>
        )}
      </Box>

      <Box marginTop={1}>
        <Text>
          <Text color="cyan">r</Text>
          <Text dimColor> recheck · </Text>
          <Text color="cyan">o</Text>
          <Text dimColor> open System Settings · </Text>
          <Text color="cyan">esc</Text>
          <Text dimColor> back</Text>
        </Text>
      </Box>
    </Box>
  );
}
