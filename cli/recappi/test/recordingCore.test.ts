import { describe, expect, it } from "vitest";
import {
  levelFromRmsDb,
  recordingArtifactFromRecordData,
  recordingCaptureMappingFromSelection,
  recordingStatusFromSidecarState,
  type RecordingSource,
} from "../src/recordingCore";

const sources: RecordingSource[] = [
  { id: "system", kind: "system", label: "System audio", canIncludeMicrophone: true },
  {
    id: "meet",
    kind: "app",
    label: "Google Meet - Arc",
    appName: "Arc",
    bundleId: "company.thebrowser.Browser",
    canIncludeMicrophone: true,
  },
  { id: "mic", kind: "microphone", label: "Microphone only", canIncludeMicrophone: false },
];

describe("recording core", () => {
  it("maps setup selection to helper capture options", () => {
    expect(
      recordingCaptureMappingFromSelection(
        { sourceId: "system", includeMicrophone: false },
        sources,
      ),
    ).toMatchObject({
      includeSystemAudio: true,
      includeMicrophone: false,
      sourceLabel: "System audio",
      micEnabled: false,
    });

    expect(
      recordingCaptureMappingFromSelection({ sourceId: "meet", includeMicrophone: true }, sources),
    ).toMatchObject({
      includeSystemAudio: true,
      includeMicrophone: true,
      sourceLabel: "Google Meet - Arc",
      micEnabled: true,
    });

    expect(
      recordingCaptureMappingFromSelection({ sourceId: "mic", includeMicrophone: false }, sources),
    ).toMatchObject({
      includeSystemAudio: false,
      includeMicrophone: true,
      sourceLabel: "Microphone only",
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
