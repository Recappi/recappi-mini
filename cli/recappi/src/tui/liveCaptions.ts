// Presentation-side model for the live captions stream (#255). The recording
// sidecar (#252/#254) emits a transport event stream; an adapter folds those
// events into this view-model with `liveCaptionReducer`, and `LiveCaptionsView`
// renders it. Keeping the view-model transport-agnostic means the sidecar IPC
// contract can change without touching the TUI.
import type { SidecarEvent, SidecarRecordingState } from "../../../packages/contracts/src/index";

export type LiveCaptionStatus = "connecting" | "live" | "reconnecting" | "stopped" | "error";

export interface LiveCaptionLine {
  id: string;
  text: string;
  speaker?: string;
  atMs?: number;
  translation?: string; // paired translation (bilingual), when available
}

export interface LiveCaptionsState {
  status: LiveCaptionStatus;
  lines: LiveCaptionLine[]; // finalized lines, in arrival order
  partial?: string; // current in-flight source text
  translationPartial?: string; // current in-flight translation text
  error?: string;
  startedAtMs?: number;
}

// Events the sidecar adapter produces. Intentionally minimal; the adapter maps
// the real IPC frames (#252) onto these.
export type LiveCaptionEvent =
  | { kind: "status"; status: LiveCaptionStatus; atMs?: number }
  | { kind: "partial"; text: string }
  | { kind: "final"; line: LiveCaptionLine }
  | { kind: "translationPartial"; text: string }
  | { kind: "translationFinal"; segmentId?: string; text: string }
  | { kind: "error"; message: string };

export function initialLiveCaptionsState(): LiveCaptionsState {
  return { status: "connecting", lines: [] };
}

// Fold one event into the state. Pure — safe to unit test and to drive from any
// async source.
export function liveCaptionReducer(
  state: LiveCaptionsState,
  event: LiveCaptionEvent,
): LiveCaptionsState {
  switch (event.kind) {
    case "status": {
      const next: LiveCaptionsState = { ...state, status: event.status };
      if (event.status === "live" && state.startedAtMs == null) {
        next.startedAtMs = event.atMs ?? state.startedAtMs;
      }
      if (event.status !== "error") next.error = undefined;
      return next;
    }
    case "partial":
      return { ...state, partial: event.text };
    case "final": {
      // A finalized line supersedes the in-flight source partial.
      const lines = [...state.lines, event.line];
      return { ...state, lines, partial: undefined };
    }
    case "translationPartial":
      return { ...state, translationPartial: event.text };
    case "translationFinal": {
      // Pair onto the matching source line by id, else the most recent line.
      const lines = [...state.lines];
      let idx = event.segmentId ? lines.findIndex((l) => l.id === event.segmentId) : -1;
      if (idx < 0) idx = lines.length - 1;
      if (idx >= 0) lines[idx] = { ...lines[idx]!, translation: event.text };
      return { ...state, lines, translationPartial: undefined };
    }
    case "error":
      return { ...state, status: "error", error: event.message };
    default:
      return state;
  }
}

function recordingStateToStatus(state: SidecarRecordingState): LiveCaptionStatus {
  switch (state) {
    case "idle":
    case "starting":
      return "connecting";
    case "recording":
      return "live";
    case "stopping":
    case "finalizing":
    case "uploading":
    case "completed":
    case "cancelled":
      return "stopped";
    case "failed":
      return "error";
  }
}

// Map one sidecar IPC event (#252) onto a live-caption view-model event, or null
// for events the captions view ignores (audio levels, local artifacts, the
// translation stream). The thin seam that lets the sidecar contract evolve
// without touching the TUI.
export function sidecarToLiveCaptionEvent(event: SidecarEvent): LiveCaptionEvent | null {
  switch (event.type) {
    case "ready":
      return { kind: "status", status: "connecting" };
    case "recording.state":
      if (event.state === "failed") {
        return { kind: "error", message: event.message ?? "Recording failed" };
      }
      return { kind: "status", status: recordingStateToStatus(event.state) };
    case "live_caption.delta": {
      if (event.stream === "translation") {
        return event.isFinal
          ? { kind: "translationFinal", segmentId: event.segmentId, text: event.text }
          : { kind: "translationPartial", text: event.text };
      }
      if (event.isFinal) {
        return {
          kind: "final",
          line: {
            id: event.segmentId ?? `${event.startMs ?? event.atMs ?? 0}`,
            text: event.text,
            speaker: event.speaker,
            atMs: event.startMs ?? event.atMs,
          },
        };
      }
      return { kind: "partial", text: event.text };
    }
    case "error":
      return { kind: "error", message: event.message };
    case "audio.level":
    case "local_artifact.upserted":
      return null;
    default:
      return null;
  }
}

export function liveCaptionStatusLabel(status: LiveCaptionStatus): string {
  switch (status) {
    case "connecting":
      return "Connecting…";
    case "live":
      return "● LIVE";
    case "reconnecting":
      return "Reconnecting…";
    case "stopped":
      return "Stopped";
    case "error":
      return "Error";
  }
}
