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
  previewLevel?: number; // 0..1 live input level of the focused source
}

function levelBar(level: number | undefined, width = 8): string {
  const v = Math.max(0, Math.min(1, level ?? 0));
  const n = Math.round(v * width);
  return "▇".repeat(n) + "▁".repeat(width - n);
}

// Record setup: choose what to capture (system audio / a running app / mic-only),
// whether to also include the mic, and a scene — mirrors the macOS app. Responsive:
// wide shows a live input-level preview beside the source list. ⏎ starts, esc cancels.
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
  // The mic toggle only applies to system/app sources; a mic-only source IS the mic.
  const micApplicable = selected?.canIncludeMicrophone ?? selected?.kind !== "microphone";
  const wide = size.columns >= 100;

  useInput((input, key) => {
    if (key.upArrow || input === "k") setSrcIdx((i) => Math.max(0, i - 1));
    else if (key.downArrow || input === "j") setSrcIdx((i) => Math.min(sources.length - 1, i + 1));
    else if (input === " " && micApplicable) setIncludeMic((m) => !m);
    else if (input === "s" && model.scenes.length > 1) setSceneIdx((i) => (i + 1) % model.scenes.length);
    else if (key.return && selected) {
      onStart({
        sourceId: selected.id,
        includeMicrophone: micApplicable ? includeMic : false,
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
    </Box>
  );

  const preview = (
    <Box flexDirection="column">
      <Text dimColor>INPUT PREVIEW</Text>
      <Text color="green">{levelBar(model.previewLevel, 10)}</Text>
      <Text dimColor>live level of selection</Text>
    </Box>
  );

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text bold color="magenta">
        New recording
      </Text>

      <Box marginTop={1} flexDirection={wide ? "row" : "column"}>
        <Box flexGrow={1} flexDirection="column">
          {sourceList}
        </Box>
        {wide ? <Box marginLeft={4}>{preview}</Box> : null}
      </Box>

      <Box marginTop={1} flexDirection="column">
        {micApplicable ? (
          <Text>
            <Text dimColor>Microphone  </Text>
            <Text color={includeMic ? "green" : "gray"}>{includeMic ? "[x] include mic" : "[ ] include mic"}</Text>
            <Text dimColor>  (space)</Text>
          </Text>
        ) : (
          <Text dimColor>Microphone is the source</Text>
        )}
        {model.scenes.length > 0 ? (
          <Text>
            <Text dimColor>Scene       </Text>
            <Text>{model.scenes[sceneIdx]?.label ?? "Default"}</Text>
            {model.scenes.length > 1 ? <Text dimColor>  (s to change)</Text> : null}
          </Text>
        ) : null}
      </Box>

      <Box marginTop={1}>
        <Text dimColor>↑↓ source · space mic · ⏎ start recording · esc cancel</Text>
      </Box>
    </Box>
  );
}
