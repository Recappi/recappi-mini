import { describe, expect, it } from "vitest";
import {
  DEFAULT_RECORDING_SOURCES,
  levelFromRmsDb,
  recordingArtifactFromRecordData,
  recordingCaptureMappingFromSelection,
  recordingStatusFromSidecarState,
  type RecordingSource,
} from "../src/recordingCore";

const sources: RecordingSource[] = [
  { id: "system", kind: "system", label: "System audio · all apps", canIncludeMicrophone: true },
  {
    id: "meet",
    kind: "app",
    label: "Google Meet - Arc",
    appName: "Arc",
    bundleId: "company.thebrowser.Browser",
    canIncludeMicrophone: true,
  },
];

describe("recording core", () => {
  it("exposes macOS-style default sources without a microphone-only source", () => {
    expect(DEFAULT_RECORDING_SOURCES).toEqual([
      expect.objectContaining({
        id: "system",
        kind: "system",
        label: "System audio · all apps",
      }),
    ]);
    expect(DEFAULT_RECORDING_SOURCES.map((source) => source.kind)).toEqual(["system"]);
  });

  it("maps setup selection to helper capture options", () => {
    expect(
      recordingCaptureMappingFromSelection(
        { sourceId: "system", includeMicrophone: false },
        sources,
      ),
    ).toMatchObject({
      includeSystemAudio: true,
      includeMicrophone: false,
      sourceLabel: "System audio · all apps",
      micEnabled: false,
    });

    expect(
      recordingCaptureMappingFromSelection(
        {
          sourceId: "meet",
          includeMicrophone: true,
          microphoneDeviceId: "mic_default",
        },
        sources,
      ),
    ).toMatchObject({
      includeSystemAudio: true,
      includeMicrophone: true,
      targetBundleId: "company.thebrowser.Browser",
      microphoneDeviceId: "mic_default",
      sourceLabel: "Google Meet - Arc",
      micEnabled: true,
    });
  });

  it("normalizes sidecar state and audio level into UI-friendly values", () => {
    expect(recordingStatusFromSidecarState("recording")).toBe("recording");
    expect(recordingStatusFromSidecarState("finalizing")).toBe("stopping");
    expect(recordingStatusFromSidecarState("completed")).toBe("stopped");
    expect(recordingStatusFromSidecarState("failed")).toBe("error");
    expect(levelFromRmsDb(-60)).toBe(0);
    expect(levelFromRmsDb(0)).toBe(1);
    expect(levelFromRmsDb(-30)).toBeCloseTo(0.5);
  });

  it("derives stopped artifact metadata from record command data", () => {
    const artifact = recordingArtifactFromRecordData({
      origin: "https://api.recappi.com",
      userId: "u_1",
      live: false,
      sessionId: "session_1",
      state: "completed",
      artifacts: [
        {
          kind: "recording_session",
          localPath: "/tmp/session",
          metadata: {
            audioPath: "/tmp/session/recording.m4a",
            durationMs: 42_000,
            sizeBytes: 1_200_000,
          },
        },
      ],
    });

    expect(artifact).toEqual({
      sessionId: "session_1",
      audioPath: "/tmp/session/recording.m4a",
      durationMs: 42_000,
      sizeBytes: 1_200_000,
      uploadStatus: "local_only",
      transcriptionStatus: "not_started",
    });
  });
});
