import React from "react";
import { render, type Instance, type RenderOptions } from "ink";
import { spawn } from "node:child_process";
import type { RecordingAudioRuntime } from "../audio";
import type { LocalArtifact } from "../store";
import type {
  AccountStatusData,
  DashboardStatsData,
  JobListData,
  OperationEvent,
  RecordCommandData,
  RecordingListData,
  RecordingTranscribeData,
  TranscriptData,
  UploadSuccess,
} from "../../../packages/contracts/src/index";
import {
  AppShell,
  type DashboardRecordingsPageOptions,
  type DashboardRetranscribeOptions,
} from "./AppShell";
import type { LiveCaptionEventSource } from "./LiveCaptionsScreen";
import type {
  RecordingArtifact,
  RecordingInputSelection,
  RecordingMicrophoneDevice,
  RecordingSource,
} from "../recordingCore";
import type { TabKey } from "./chrome";

export { AppShell } from "./AppShell";
export { JobsView } from "./JobsView";
export { OverviewView } from "./OverviewView";
export { JobDetailView } from "./JobDetailView";
export { useTerminalSize } from "./terminal";
export type { TerminalSize } from "./terminal";

export interface RunDashboardDeps {
  fetchJobs: () => Promise<JobListData>;
  fetchRecordings?: (options?: DashboardRecordingsPageOptions) => Promise<RecordingListData>;
  fetchDashboardStats?: () => Promise<DashboardStatsData>;
  fetchAccountStatus?: () => Promise<AccountStatusData>;
  fetchTranscript: (transcriptId: string) => Promise<TranscriptData>;
  recordingAudio?: RecordingAudioRuntime;
  listDownloadedRecordingIds?: () => Promise<Set<string>>;
  listDownloads?: () => Promise<LocalArtifact[]>;
  fetchRecordSetup?: () => Promise<DashboardRecordSetupModel>;
  startLiveRecord?: (
    selection: RecordingInputSelection,
    sources: RecordingSource[],
  ) => Promise<DashboardLiveRecordSession>;
  startRecordSetupPreview?: (
    selection: RecordingInputSelection,
    sources: RecordingSource[],
  ) => Promise<DashboardRecordSetupPreview>;
  transcribeRecordingArtifact?: (
    artifact: RecordingArtifact,
    onEvent?: (event: OperationEvent) => void,
  ) => Promise<UploadSuccess>;
  retranscribeRecording?: (
    recordingId: string,
    options?: DashboardRetranscribeOptions,
  ) => Promise<RecordingTranscribeData>;
  initialView?: TabKey;
  renderApp?: DashboardRenderer;
}

export interface DashboardLiveRecordSession {
  mode?: "local" | "live_captions";
  source: LiveCaptionEventSource;
  stop: () => Promise<RecordCommandData>;
}

export interface DashboardRecordSetupPreview {
  source: LiveCaptionEventSource;
  stop: () => Promise<void> | void;
}

export interface DashboardRecordSetupModel {
  sources: RecordingSource[];
  microphones?: RecordingMicrophoneDevice[];
}

type DashboardRenderer = (
  node: React.ReactNode,
  options?: RenderOptions,
) => Pick<Instance, "waitUntilExit">;

export const DASHBOARD_RENDER_OPTIONS = {
  alternateScreen: true,
  interactive: true,
} satisfies RenderOptions;

// Open a URL in the OS default handler. Best-effort; failures are swallowed so a
// missing opener never crashes the dashboard.
function openUrl(url: string): void {
  const cmd =
    process.platform === "darwin" ? "open" : process.platform === "win32" ? "start" : "xdg-open";
  try {
    spawn(cmd, [url], { stdio: "ignore", detached: true }).unref();
  } catch {
    /* ignore */
  }
}

function copyText(text: string): void {
  if (process.platform !== "darwin") return; // pbcopy is macOS; other platforms TODO
  try {
    const child = spawn("pbcopy", { stdio: ["pipe", "ignore", "ignore"] });
    child.stdin.end(text);
  } catch {
    /* ignore */
  }
}

// Entry point for the interactive dashboard. cli.ts wires bare `recappi`
// (initialView "overview") / `recappi jobs` (initialView "jobs") in a TTY to
// this; it MUST NOT be called for non-TTY, --json, or --jsonl. Resolves on quit.
export async function runDashboard(deps: RunDashboardDeps): Promise<void> {
  const renderApp = deps.renderApp ?? render;
  const app = renderApp(
    React.createElement(AppShell, {
      fetchJobs: deps.fetchJobs,
      fetchTranscript: deps.fetchTranscript,
      fetchRecordings: deps.fetchRecordings,
      fetchDashboardStats: deps.fetchDashboardStats,
      fetchAccountStatus: deps.fetchAccountStatus,
      recordingAudio: deps.recordingAudio,
      listDownloadedRecordingIds: deps.listDownloadedRecordingIds,
      fetchRecordSetup: deps.fetchRecordSetup,
      startLiveRecord: deps.startLiveRecord,
      startRecordSetupPreview: deps.startRecordSetupPreview,
      transcribeRecordingArtifact: deps.transcribeRecordingArtifact,
      onRetranscribe: deps.retranscribeRecording,
      initialView: deps.initialView ?? "overview",
      openUrl,
      copyText,
    }),
    DASHBOARD_RENDER_OPTIONS,
  );
  await app.waitUntilExit();
}
