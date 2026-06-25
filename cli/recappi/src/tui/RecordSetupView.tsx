import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import type {
  RecordingInputSelection as CoreRecordingInputSelection,
  RecordingScene,
  RecordingSource,
} from "../recordingCore";
import { useTerminalSize } from "./terminal";

export type RecordSource = RecordingSource;
export type RecordScene = RecordingScene;
export type RecordInputSelection = CoreRecordingInputSelection;

export interface RecordSetupModel {
  sources: RecordSource[];
  scenes: RecordScene[];
}

// Record setup mirrors the macOS app: source selects the system/app audio target,
// while microphone capture is an additive option rather than a source.
export function RecordSetupView({
  model,
  onStart,
  onCancel,
}: {
  model: RecordSetupModel;
  onStart: (selection: RecordInputSelection) => void;
  onCancel: () => void;
}): React.ReactElement {
  const size = useTerminalSize();
  const [srcIdx, setSrcIdx] = useState(0);
  const [includeMic, setIncludeMic] = useState(true);
  const [sceneIdx, setSceneIdx] = useState(0);

  const sources = model.sources;
  const selected = sources[Math.min(srcIdx, Math.max(0, sources.length - 1))];
  const wide = size.columns >= 100;
  const hasAppSource = sources.some((source) => source.kind === "app");
  const hasMultipleSources = sources.length > 1;

  useInput((input, key) => {
    if (key.upArrow || input === "k") setSrcIdx((i) => Math.max(0, i - 1));
    else if (key.downArrow || input === "j") setSrcIdx((i) => Math.min(sources.length - 1, i + 1));
    else if (input === " ") setIncludeMic((m) => !m);
    else if (input === "s" && model.scenes.length > 1) setSceneIdx((i) => (i + 1) % model.scenes.length);
    else if (key.return && selected) {
      onStart({
        sourceId: selected.id,
        includeMicrophone: includeMic,
        sceneId: model.scenes[sceneIdx]?.id,
      });
    } else if (key.escape) onCancel();
  });

  const sourceList = (
    <Box flexDirection="column">
      <Text dimColor>SOURCE</Text>
      {sources.map((s, i) => {
        const on = i === srcIdx;
        return (
          <Text key={s.id} color={on ? "cyan" : undefined} wrap="truncate-end">
            {on ? "▸ ● " : "  ○ "}
            {s.label}
          </Text>
        );
      })}
      {!hasAppSource ? <Text dimColor>App-specific capture coming soon</Text> : null}
    </Box>
  );

  const capturePlan = (
    <Box flexDirection="column">
      <Text dimColor>CAPTURE PLAN</Text>
      <Text>{includeMic ? `${selected?.label ?? "System audio"} + microphone` : `${selected?.label ?? "System audio"} only`}</Text>
      <Text dimColor>{includeMic ? "Mic is mixed into the recording" : "Mic stays muted"}</Text>
    </Box>
  );
  const shortcuts = [
    hasMultipleSources ? "↑↓ source" : undefined,
    "space mic",
    model.scenes.length > 1 ? "s scene" : undefined,
    "⏎ start recording",
    "esc cancel",
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text bold color="magenta">
        New recording
      </Text>

      <Box marginTop={1} flexDirection={wide ? "row" : "column"}>
        <Box flexGrow={1} flexDirection="column">
          {sourceList}
        </Box>
        {wide ? <Box marginLeft={4}>{capturePlan}</Box> : null}
      </Box>

      <Box marginTop={1} flexDirection="column">
        <Text>
          <Text dimColor>Microphone  </Text>
          <Text color={includeMic ? "green" : "gray"}>{includeMic ? "[x] include mic" : "[ ] include mic"}</Text>
          <Text dimColor>  (space)</Text>
        </Text>
        {model.scenes.length > 0 ? (
          <Text>
            <Text dimColor>Scene       </Text>
            <Text>{model.scenes[sceneIdx]?.label ?? "Default"}</Text>
            {model.scenes.length > 1 ? <Text dimColor>  (s to change)</Text> : null}
          </Text>
        ) : null}
      </Box>

      <Box marginTop={1}>
        <Text dimColor>{shortcuts}</Text>
      </Box>
    </Box>
  );
}
