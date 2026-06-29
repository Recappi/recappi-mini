import React, { useEffect, useRef, useState } from "react";
import { Box, Text, useInput } from "ink";
import type {
  RecordingInputSelection as CoreRecordingInputSelection,
  RecordingMicrophoneDevice,
  RecordingScene,
  RecordingSetupLevels,
  RecordingSource,
} from "../recordingCore";

export interface RecordSetupModel {
  sources: RecordingSource[];
  microphones?: RecordingMicrophoneDevice[];
  scenes: RecordingScene[];
}

// Live input levels (RecordingSetupLevels, keyed by source/microphone id) come
// from the runtime, which previews only the currently selected source + mic
// (multi-source preview is expensive) — so non-selected rows render "—" (not
// previewed) until selected. Values are 0..1, same scale as recording telemetry.

const METER_W = 12;

// dB recovered exactly from the 0..1 level (inverse of levelFromRmsDb) — the
// real value the helper measured. Near-zero reads "silent" so a dead source
// (e.g. the Arc-silent capture bug) is obvious before you commit to recording.
function levelDb(level: number): string {
  if (level <= 0.03) return "silent";
  return `${Math.round(level * 60 - 60)} dB`;
}

// Instantaneous fill bar for a live level (setup has no rolling history).
function meterBar(level: number, width: number): string {
  const f = Math.max(0, Math.min(1, level));
  const filled = Math.round(f * width);
  return "▇".repeat(filled) + "░".repeat(Math.max(0, width - filled));
}

// One input's live meter, or "—" when that input isn't being previewed yet.
function InputMeter({ level }: { level?: number }): React.ReactElement {
  if (level == null) return <Text dimColor>—</Text>;
  const silent = level <= 0.03;
  return (
    <Text>
      {/* cyan = live signal present; yellow = silent. Same scheme as the
          recording hero meters so setup and recording read as one app. */}
      <Text color={silent ? "yellow" : "cyan"}>{meterBar(level, METER_W)}</Text>
      <Text dimColor>{`  ${levelDb(level)}`}</Text>
    </Text>
  );
}

// Record setup mirrors the macOS app: source selects the system/app audio target,
// while microphone capture is an additive option rather than a source. Each input
// shows a live level so you can see which source actually has signal (and catch a
// silent one) before you start recording.
export function RecordSetupView({
  model,
  levels,
  onStart,
  onCancel,
  onSelectionChange,
}: {
  model: RecordSetupModel;
  levels?: RecordingSetupLevels;
  onStart: (selection: CoreRecordingInputSelection) => void;
  onCancel: () => void;
  // Fired whenever the previewed selection changes so the runtime can (re)start
  // the level preview for the selected source + mic.
  onSelectionChange?: (selection: CoreRecordingInputSelection) => void;
}): React.ReactElement {
  const [srcIdx, setSrcIdx] = useState(0);
  const [includeMic, setIncludeMic] = useState(true);
  const [micIdx, setMicIdx] = useState(() =>
    Math.max(0, model.microphones?.findIndex((device) => device.isDefault) ?? 0),
  );
  const [sceneIdx, setSceneIdx] = useState(0);
  // The mic list arrives async; once it does, snap to the system default — but
  // never override a mic the user has already cycled to with `m`.
  const userPickedMic = useRef(false);

  const sources = model.sources;
  const microphones = model.microphones ?? [];
  const selected = sources[Math.min(srcIdx, Math.max(0, sources.length - 1))];
  const selectedMic = microphones[Math.min(micIdx, Math.max(0, microphones.length - 1))];
  const hasAppSource = sources.some((source) => source.kind === "app");
  const hasMultipleSources = sources.length > 1;
  const hasMultipleMicrophones = microphones.length > 1;

  const selection: CoreRecordingInputSelection = {
    sourceId: selected?.id ?? "system",
    includeMicrophone: includeMic,
    ...(includeMic && selectedMic ? { microphoneDeviceId: selectedMic.id } : {}),
    sceneId: model.scenes[sceneIdx]?.id,
  };

  // Tell the runtime which source/mic to preview whenever the selection changes.
  useEffect(() => {
    onSelectionChange?.(selection);
  }, [
    includeMic,
    onSelectionChange,
    selection.includeMicrophone,
    selection.microphoneDeviceId,
    selection.sceneId,
    selection.sourceId,
    srcIdx,
    micIdx,
  ]);

  // When the async mic list first populates, select the system default (the
  // useState initializer ran while the list was empty). Skipped once the user
  // has manually changed the device.
  useEffect(() => {
    if (userPickedMic.current || microphones.length === 0) return;
    const di = microphones.findIndex((device) => device.isDefault);
    if (di > 0) setMicIdx(di);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [microphones.length]);

  useInput((input, key) => {
    if (key.upArrow || input === "k") setSrcIdx((i) => Math.max(0, i - 1));
    else if (key.downArrow || input === "j") setSrcIdx((i) => Math.min(sources.length - 1, i + 1));
    else if (input === " ") setIncludeMic((m) => !m);
    else if (input === "m" && includeMic && hasMultipleMicrophones) {
      userPickedMic.current = true;
      setMicIdx((i) => (i + 1) % microphones.length);
    }
    else if (input === "s" && model.scenes.length > 1) setSceneIdx((i) => (i + 1) % model.scenes.length);
    else if (key.return && selected) onStart(selection);
    else if (key.escape) onCancel();
  });

  const sourceList = (
    <Box flexDirection="column">
      <Box>
        <Box width={36}><Text dimColor>SOURCE</Text></Box>
        <Text dimColor>INPUT</Text>
      </Box>
      {sources.map((s, i) => {
        const on = i === srcIdx;
        return (
          <Box key={s.id}>
            <Box width={36}>
              <Text color={on ? "cyan" : undefined} wrap="truncate-end">
                {on ? "▸ ● " : "  ○ "}
                {s.label}
              </Text>
            </Box>
            <InputMeter level={levels?.bySourceId?.[s.id]} />
          </Box>
        );
      })}
      {!hasAppSource ? <Text dimColor>No app-specific sources available right now</Text> : null}
    </Box>
  );

  const capturePlan = (
    <Text>
      <Text dimColor>Capture  </Text>
      <Text>{includeMic ? `${selected?.label ?? "System audio"} + microphone` : `${selected?.label ?? "System audio"} only`}</Text>
    </Text>
  );
  const shortcuts = [
    hasMultipleSources ? "↑↓ source" : undefined,
    "space mic",
    includeMic && hasMultipleMicrophones ? "m mic device" : undefined,
    model.scenes.length > 1 ? "s scene" : undefined,
    "⏎ start recording",
    "esc cancel",
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text bold color="green">
        New recording
      </Text>

      <Box marginTop={1} flexDirection="column">
        {sourceList}
        <Box marginTop={1}>{capturePlan}</Box>
      </Box>

      <Box marginTop={1} flexDirection="column">
        <Text>
          <Text dimColor>Microphone  </Text>
          <Text color={includeMic ? "green" : "gray"}>{includeMic ? "[x] include mic" : "[ ] include mic"}</Text>
          <Text dimColor>  (space)</Text>
        </Text>
        {selectedMic ? (
          <Box>
            <Box width={36}>
              <Text dimColor={!includeMic} wrap="truncate-end">
                <Text dimColor>Mic device  </Text>
                {selectedMic.label}
              </Text>
            </Box>
            {includeMic ? <InputMeter level={levels?.byMicrophoneId?.[selectedMic.id]} /> : null}
          </Box>
        ) : null}
        {includeMic && hasMultipleMicrophones ? <Text dimColor>  (m to change device)</Text> : null}
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
