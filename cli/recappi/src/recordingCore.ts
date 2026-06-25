import type {
  RecordCommandData,
  SidecarEvent,
  SidecarRecordingState,
} from "../../packages/contracts/src/index";

export type RecordingSourceKind = "system" | "app" | "microphone";
export type RecordingSessionStatus =
  | "starting"
  | "recording"
  | "paused"
  | "stopping"
  | "stopped"
  | "error";

export interface RecordingSource {
  id: string;
  kind: RecordingSourceKind;
  label: string;
  appName?: string;
  bundleId?: string;
  canIncludeMicrophone?: boolean;
}

export interface RecordingScene {
  id: string;
  label: string;
}

export interface RecordingMicrophoneDevice {
  id: string;
  label: string;
  isDefault?: boolean;
}

export interface RecordingInputSelection {
  sourceId: string;
  includeMicrophone: boolean;
  microphoneDeviceId?: string;
  sceneId?: string;
  prompt?: string;
}

export interface RecordingPermission {
  name: "screen_recording" | "microphone";
  status: "granted" | "denied" | "unknown";
  hint?: string;
}

export interface RecordingPreflight {
  permissions: RecordingPermission[];
  ready: boolean;
  restartRequired?: boolean;
}

export interface RecordingTelemetry {
  status: RecordingSessionStatus;
  startedAtMs?: number;
  elapsedMs?: number;
  sourceLabel: string;
  micEnabled: boolean;
  level?: { system?: number; mic?: number };
  error?: string;
  savedPath?: string;
  durationMs?: number;
  sizeBytes?: number;
}

export interface RecordingArtifact {
  sessionId: string;
  audioPath?: string;
  durationMs?: number;
  sizeBytes?: number;
  recordingId?: string;
  jobId?: string;
  transcriptId?: string;
  error?: string;
  uploadStatus?: "local_only" | "queued" | "uploading" | "uploaded" | "failed";
  transcriptionStatus?: "not_started" | "queued" | "processing" | "ready" | "failed";
}

export interface RecordingCaptureMapping {
  source: RecordingSource;
  includeSystemAudio: boolean;
  includeMicrophone: boolean;
  targetBundleId?: string;
  microphoneDeviceId?: string;
  sourceLabel: string;
  micEnabled: boolean;
}

export const DEFAULT_RECORDING_SOURCES: RecordingSource[] = [
  {
    id: "system",
    kind: "system",
    label: "System audio · all apps",
    canIncludeMicrophone: true,
  },
];

export const DEFAULT_RECORDING_SCENES: RecordingScene[] = [{ id: "default", label: "Default" }];

export const DEFAULT_RECORDING_SELECTION: RecordingInputSelection = {
  sourceId: DEFAULT_RECORDING_SOURCES[0]!.id,
  includeMicrophone: true,
  sceneId: DEFAULT_RECORDING_SCENES[0]!.id,
};

export function recordingCaptureMappingFromSelection(
  selection: RecordingInputSelection = DEFAULT_RECORDING_SELECTION,
  sources: RecordingSource[] = DEFAULT_RECORDING_SOURCES,
): RecordingCaptureMapping {
  const source = sources.find((candidate) => candidate.id === selection.sourceId) ?? sources[0];
  if (!source) {
    throw new Error("No recording sources are available.");
  }

  if (source.kind === "microphone") {
    return {
      source,
      includeSystemAudio: false,
      includeMicrophone: true,
      ...(selection.microphoneDeviceId ? { microphoneDeviceId: selection.microphoneDeviceId } : {}),
      sourceLabel: source.label,
      micEnabled: true,
    };
  }

  const microphoneDeviceId =
    selection.includeMicrophone && selection.microphoneDeviceId
      ? selection.microphoneDeviceId
      : undefined;
  return {
    source,
    includeSystemAudio: true,
    includeMicrophone: selection.includeMicrophone,
    ...(source.kind === "app" && source.bundleId ? { targetBundleId: source.bundleId } : {}),
    ...(microphoneDeviceId ? { microphoneDeviceId } : {}),
    sourceLabel: source.label,
    micEnabled: selection.includeMicrophone,
  };
}

export function recordingStatusFromSidecarState(
  state: SidecarRecordingState,
): RecordingSessionStatus {
  switch (state) {
    case "recording":
      return "recording";
    case "stopping":
    case "finalizing":
    case "uploading":
      return "stopping";
    case "completed":
    case "cancelled":
      return "stopped";
    case "failed":
      return "error";
    case "idle":
    case "starting":
    default:
      return "starting";
  }
}

export function levelFromRmsDb(rmsDb: number | undefined): number {
  if (typeof rmsDb !== "number" || Number.isNaN(rmsDb)) return 0;
  return Math.max(0, Math.min(1, (rmsDb + 60) / 60));
}

export function applyRecordingEventToTelemetry(
  telemetry: RecordingTelemetry,
  event: SidecarEvent,
): RecordingTelemetry {
  if (event.type === "recording.state") {
    return {
      ...telemetry,
      status: recordingStatusFromSidecarState(event.state),
      ...(event.message && event.state === "failed" ? { error: event.message } : {}),
    };
  }

  if (event.type === "audio.level") {
    const level = levelFromRmsDb(event.rmsDb);
    if (event.input === "microphone") {
      return { ...telemetry, level: { ...telemetry.level, mic: level } };
    }
    return { ...telemetry, level: { ...telemetry.level, system: level } };
  }

  if (event.type === "error") {
    return { ...telemetry, status: "error", error: event.message };
  }

  return telemetry;
}

export function recordingArtifactFromRecordData(data: RecordCommandData): RecordingArtifact {
  const artifact = data.artifacts.find((item) => item.kind === "recording_session") ?? data.artifacts[0];
  const metadata = isRecord(artifact?.metadata) ? artifact.metadata : {};
  const audioPath =
    typeof metadata.audioPath === "string"
      ? metadata.audioPath
      : typeof artifact?.localPath === "string"
        ? artifact.localPath
        : undefined;
  const durationMs =
    typeof metadata.durationMs === "number" && Number.isFinite(metadata.durationMs)
      ? metadata.durationMs
      : undefined;
  const sizeBytes =
    typeof metadata.sizeBytes === "number" && Number.isFinite(metadata.sizeBytes)
      ? metadata.sizeBytes
      : undefined;

  return {
    sessionId: data.sessionId,
    ...(audioPath ? { audioPath } : {}),
    ...(durationMs != null ? { durationMs } : {}),
    ...(sizeBytes != null ? { sizeBytes } : {}),
    uploadStatus: "local_only",
    transcriptionStatus: "not_started",
  };
}

export function artifactTelemetryPatch(artifact: RecordingArtifact): Partial<RecordingTelemetry> {
  return {
    savedPath: artifact.audioPath,
    durationMs: artifact.durationMs,
    sizeBytes: artifact.sizeBytes,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
