import React, { useCallback, useEffect, useState } from "react";
import { Box, Text, useApp, useInput } from "ink";
import type { RecordingAudioRuntime } from "../audio";
import type {
  AccountStatusData,
  DashboardStatsData,
  JobListData,
  JobListItem,
  RecordCommandData,
  RecordingData,
  RecordingListData,
  SidecarEvent,
  TranscriptData,
  TranscriptSummary,
  UploadSuccess,
} from "../../../packages/contracts/src/index";

// Lazily-loaded summary state for the peek panel.
export type PeekSummary = TranscriptSummary | "loading" | "error";
import { AccountView, type AccountStatus } from "./AccountView";
import { Header, Footer, type TabKey } from "./chrome";
import { JobsView } from "./JobsView";
import { OverviewView } from "./OverviewView";
import { JobDetailView } from "./JobDetailView";
import { RecordingDetailView, type AudioAction, type DetailTranscript } from "./RecordingDetailView";
import { TranscriptView } from "./TranscriptView";
import { LiveCaptionsScreen, type LiveCaptionEventSource } from "./LiveCaptionsScreen";
import { PermissionPreflightView, type PermissionItem } from "./PermissionPreflightView";
import { RecordSetupView, type RecordSetupModel } from "./RecordSetupView";
import { RecordingHeroScreen } from "./RecordingHeroScreen";
import {
  DEFAULT_RECORDING_SCENES,
  DEFAULT_RECORDING_SELECTION,
  DEFAULT_RECORDING_SOURCES,
  type RecordingMicrophoneDevice,
  applyRecordingEventToTelemetry,
  artifactTelemetryPatch,
  recordingArtifactFromRecordData,
  recordingCaptureMappingFromSelection,
  type RecordingArtifact,
  type RecordingInputSelection,
  type RecordingSource,
  type RecordingTelemetry,
} from "../recordingCore";
import {
  resolveJobLinks,
  resolveRecordingLinks,
  listWindow,
  groupedListWindow,
  dateBucket,
} from "./format";
import { useTerminalSize } from "./terminal";

const RECORDINGS_PAGE_SIZE = 50;
const RECORDINGS_PREFETCH_REMAINING = 8;

export interface DashboardRecordingsPageOptions {
  limit?: number;
  cursor?: string;
}

export interface AppShellProps {
  fetchJobs: () => Promise<JobListData>;
  fetchTranscript: (transcriptId: string) => Promise<TranscriptData>;
  fetchRecordings?: (options?: DashboardRecordingsPageOptions) => Promise<RecordingListData>;
  fetchDashboardStats?: () => Promise<DashboardStatsData>;
  fetchAccountStatus?: () => Promise<AccountStatusData>;
  recordingAudio?: RecordingAudioRuntime;
  listDownloadedRecordingIds?: () => Promise<Set<string>>;
  fetchRecordSetup?: () => Promise<DashboardRecordSetupModel>;
  startLiveRecord?: (
    selection: RecordingInputSelection,
    sources: RecordingSource[],
  ) => Promise<DashboardLiveRecordSession>;
  transcribeRecordingArtifact?: (artifact: RecordingArtifact) => Promise<UploadSuccess>;
  initialView?: TabKey;
  // Side effects, injected so tests stay pure and the component has no Node deps.
  openUrl?: (url: string) => void;
  copyText?: (text: string) => void;
  now?: () => number;
  pollMs?: number;
  spinnerMs?: number;
}

export interface DashboardLiveRecordSession {
  mode?: "local" | "live_captions";
  source: LiveCaptionEventSource;
  stop: () => Promise<RecordCommandData>;
}

export interface DashboardRecordSetupModel {
  sources: RecordingSource[];
  microphones?: RecordingMicrophoneDevice[];
}

type Screen =
  | { kind: "overview" }
  | { kind: "jobs" }
  | { kind: "account" }
  | { kind: "recordSetup" }
  | { kind: "record" }
  | { kind: "jobDetail"; jobId: string }
  | { kind: "recordingDetail"; recordingId: string }
  | { kind: "transcript"; loading: boolean; data?: TranscriptData; error?: string };

type LiveRecordState =
  | { kind: "starting"; selection: RecordingInputSelection; telemetry: RecordingTelemetry }
  | {
      kind: "live";
      session: DashboardLiveRecordSession;
      telemetry: RecordingTelemetry;
      selection: RecordingInputSelection;
    }
  | {
      kind: "stopping";
      session: DashboardLiveRecordSession;
      telemetry: RecordingTelemetry;
      selection: RecordingInputSelection;
    }
  | {
      kind: "stopped";
      telemetry: RecordingTelemetry;
      artifact?: RecordingArtifact;
      selection: RecordingInputSelection;
    }
  | {
      kind: "error";
      message: string;
      code?: string;
      data?: unknown;
      selection?: RecordingInputSelection;
    };

// Map the record helper's stable error codes to friendly, platform-agnostic copy
// for the Record tab — never expose internal terms (sidecar / env var / paths).
export function recordErrorCopy(
  code: string | undefined,
  message: string,
): { title: string; detail?: string; tone: string } {
  switch (code) {
    case "record.helper_unavailable":
      return {
        title: "This CLI install is missing its local recorder.",
        detail: "Run npm install -g recappi@latest, or use npx -y recappi@latest.",
        tone: "yellow",
      };
    case "record.unsupported_platform":
      return {
        title: "CLI recording isn't supported on this platform yet.",
        detail: "Use Recappi Mini on macOS to record for now.",
        tone: "yellow",
      };
    case "record.capture_unavailable":
      return {
        title: "CLI recording isn't ready yet.",
        detail: "Use the Recappi Mini app to record for now; CLI recording is coming soon.",
        tone: "yellow",
      };
    case "record.permission_required":
      return {
        title: "Recording needs macOS permission first.",
        detail: "Open System Settings > Privacy & Security, allow recording access, then retry.",
        tone: "yellow",
      };
    case "record.capture_failed":
      return {
        title: "Couldn't start recording.",
        detail: "Recording failed to start — please try again.",
        tone: "red",
      };
    default:
      return { title: "Couldn't start recording.", detail: message, tone: "red" };
  }
}

export function recordErrorState(
  error: unknown,
  selection?: RecordingInputSelection,
): Extract<LiveRecordState, { kind: "error" }> {
  if (error instanceof Error) {
    const descriptor = isRecord(error) && isRecord(error.descriptor) ? error.descriptor : undefined;
    return {
      kind: "error",
      message: error.message,
      code:
        typeof descriptor?.code === "string"
          ? descriptor.code
          : "code" in error && typeof error.code === "string"
            ? error.code
            : undefined,
      data: isRecord(error) ? error.data : undefined,
      ...(selection ? { selection } : {}),
    };
  }
  return { kind: "error", message: String(error), ...(selection ? { selection } : {}) };
}

export function transcribeHandoffErrorCopy(error: unknown): string {
  const descriptor = error instanceof Error && isRecord(error) && isRecord(error.descriptor)
    ? error.descriptor
    : undefined;
  const code =
    typeof descriptor?.code === "string"
      ? descriptor.code
      : isRecord(error) && typeof error.code === "string"
        ? error.code
        : undefined;

  switch (code) {
    case "auth.not_logged_in":
      return "Sign in to Recappi before transcribing this recording.";
    case "auth.unauthorized":
      return "Your Recappi session needs attention. Sign in and retry.";
    case "input.not_found":
      return "The local recording file is no longer available.";
    case "input.not_file":
      return "The saved recording is not a readable audio file.";
    case "input.unsupported_audio":
      return "This recording format is not supported yet.";
    case "input.duration_unavailable":
      return "This recording could not be checked yet.";
    case "cloud.conflict.upload_in_progress":
      return "This recording is already being uploaded.";
    case "cloud.recording_not_ready":
      return "The recording is still being prepared. Try again shortly.";
    case "cloud.job_failed":
      return "Transcription failed on Recappi Cloud. Please try again.";
    case "cloud.job_timed_out":
      return "Transcription took too long. Please try again.";
    case "cloud.http_error":
    case "cloud.invalid_response":
      return "Recappi Cloud could not start transcription. Please try again.";
    default:
      return "Could not start transcription. Please try again.";
  }
}

export function permissionItemsFromRecordError(data: unknown): PermissionItem[] {
  const sidecarError = isRecord(data) ? data : undefined;
  const sidecarData = isRecord(sidecarError?.data) ? sidecarError.data : undefined;
  const permission = typeof sidecarData?.permission === "string" ? sidecarData.permission : "";
  const hint = typeof sidecarData?.recovery === "string" ? sidecarData.recovery : undefined;
  const item =
    permission === "microphone"
      ? "Microphone"
      : permission === "screen_recording"
        ? "Screen Recording"
        : "Recording";
  return [{ name: item, status: "denied", ...(hint ? { hint } : {}) }];
}

function settingsUrlFromRecordError(data: unknown): string {
  const sidecarError = isRecord(data) ? data : undefined;
  const sidecarData = isRecord(sidecarError?.data) ? sidecarError.data : undefined;
  const permission = typeof sidecarData?.permission === "string" ? sidecarData.permission : "";
  if (permission === "microphone") {
    return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone";
  }
  return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function AppShell({
  fetchJobs,
  fetchTranscript,
  fetchRecordings,
  fetchDashboardStats,
  fetchAccountStatus,
  recordingAudio,
  listDownloadedRecordingIds,
  fetchRecordSetup,
  startLiveRecord,
  transcribeRecordingArtifact,
  initialView = "overview",
  openUrl,
  copyText,
  now = () => Date.now(),
  pollMs = 3000,
  spinnerMs = 80,
}: AppShellProps): React.ReactElement {
  const { exit } = useApp();
  const size = useTerminalSize();
  const [jobs, setJobs] = useState<JobListItem[]>([]);
  const [recordings, setRecordings] = useState<RecordingData[]>([]);
  const [recordingsNextCursor, setRecordingsNextCursor] = useState<string | null>(null);
  const [recordingsTotalCount, setRecordingsTotalCount] = useState<number | undefined>(undefined);
  const [stats, setStats] = useState<DashboardStatsData | undefined>(undefined);
  const [accountStatus, setAccountStatus] = useState<AccountStatus>("loading");
  const [origin, setOrigin] = useState("");
  const [stack, setStack] = useState<Screen[]>([{ kind: initialView }]);
  const [selected, setSelected] = useState(0);
  const [spinnerFrame, setSpinnerFrame] = useState(0);
  const [loadingMoreRecordings, setLoadingMoreRecordings] = useState(false);
  const [loadError, setLoadError] = useState<string | undefined>(undefined);
  const [notice, setNotice] = useState<string | undefined>(undefined);
  const [summaryCache, setSummaryCache] = useState<Map<string, PeekSummary>>(() => new Map());
  const [transcriptCache, setTranscriptCache] = useState<Map<string, DetailTranscript>>(
    () => new Map(),
  );
  const [audioCache, setAudioCache] = useState<Map<string, AudioAction>>(() => new Map());
  const [downloadedIds, setDownloadedIds] = useState<Set<string>>(() => new Set());
  const [liveRecord, setLiveRecord] = useState<LiveRecordState | undefined>(undefined);
  const [recordSetupInputs, setRecordSetupInputs] = useState<DashboardRecordSetupModel>({
    sources: DEFAULT_RECORDING_SOURCES,
    microphones: [],
  });
  const recordSetupModel: RecordSetupModel = {
    sources: recordSetupInputs.sources.length > 0 ? recordSetupInputs.sources : DEFAULT_RECORDING_SOURCES,
    microphones: recordSetupInputs.microphones ?? [],
    scenes: DEFAULT_RECORDING_SCENES,
  };

  // Which recordings have a local download in the account-scoped store (#253),
  // so rows can show an offline-available marker. Refreshed on load + after a
  // download completes.
  const refreshDownloadedIds = useCallback(async () => {
    if (!listDownloadedRecordingIds) return;
    try {
      setDownloadedIds(await listDownloadedRecordingIds());
    } catch {
      /* non-fatal: the marker just won't show */
    }
  }, [listDownloadedRecordingIds]);
  useEffect(() => {
    void refreshDownloadedIds();
  }, [refreshDownloadedIds]);

  const screen = stack[stack.length - 1]!;

  const beginLiveRecord = useCallback(
    (selection: RecordingInputSelection = DEFAULT_RECORDING_SELECTION) => {
      const capture = recordingCaptureMappingFromSelection(selection, recordSetupModel.sources);
      const telemetry: RecordingTelemetry = {
        status: "starting",
        startedAtMs: now(),
        sourceLabel: capture.sourceLabel,
        micEnabled: capture.micEnabled,
      };
      setStack((current) => {
        const withoutSetup =
          current[current.length - 1]?.kind === "recordSetup" ? current.slice(0, -1) : current;
        return [...withoutSetup, { kind: "record" }];
      });

      if (!startLiveRecord) {
        setLiveRecord({
          kind: "error",
          code: "record.helper_unavailable",
          message: "Live recording is not available",
          selection,
        });
        return;
      }

      setLiveRecord({ kind: "starting", selection, telemetry });
      startLiveRecord(selection, recordSetupModel.sources)
        .then((session) => {
          setLiveRecord((current) => {
            if (current?.kind !== "starting") return current;
            return {
              kind: "live",
              session,
              selection,
              telemetry: { ...current.telemetry, status: "recording" },
            };
          });
        })
        .catch((error) => {
          setLiveRecord(recordErrorState(error, selection));
        });
    },
    [now, recordSetupModel.sources, startLiveRecord],
  );

  const stopLiveRecord = useCallback(async () => {
    const current = liveRecord;
    if (current?.kind === "live") {
      const stoppingTelemetry: RecordingTelemetry = { ...current.telemetry, status: "stopping" };
      setLiveRecord({
        kind: "stopping",
        session: current.session,
        selection: current.selection,
        telemetry: stoppingTelemetry,
      });
      try {
        const data = await current.session.stop();
        const artifact = recordingArtifactFromRecordData(data);
        const fallbackDuration =
          current.telemetry.startedAtMs != null
            ? Math.max(0, now() - current.telemetry.startedAtMs)
            : undefined;
        setLiveRecord({
          kind: "stopped",
          selection: current.selection,
          artifact,
          telemetry: {
            ...stoppingTelemetry,
            ...artifactTelemetryPatch(artifact),
            ...(artifact.durationMs == null && fallbackDuration != null
              ? { durationMs: fallbackDuration }
              : {}),
            status: "stopped",
          },
        });
        void refreshDownloadedIds();
      } catch (error) {
        setLiveRecord({
          kind: "error",
          message: error instanceof Error ? error.message : String(error),
        });
      }
      return;
    }
    if (current?.kind === "stopped" || current?.kind === "error") setLiveRecord(undefined);
    setStack([{ kind: "overview" }]);
  }, [liveRecord, now, refreshDownloadedIds]);

  const liveSession = liveRecord?.kind === "live" ? liveRecord.session : undefined;
  useEffect(() => {
    if (!liveSession) return;
    const session = liveSession;
    const unsubscribe = session.source.onEvent((event: SidecarEvent) => {
      setLiveRecord((current) => {
        if (current?.kind !== "live" || current.session !== session) return current;
        return {
          ...current,
          telemetry: applyRecordingEventToTelemetry(current.telemetry, event),
        };
      });
    });
    return unsubscribe;
  }, [liveSession]);

  // Lazily fetch the selected recording's transcript summary for the peek panel,
  // debounced + cached by transcriptId so scrolling doesn't hammer the API.
  const selectedRecording = screen.kind === "overview" ? recordings[selected] : undefined;
  const peekTranscriptId = selectedRecording?.activeTranscriptId ?? undefined;
  useEffect(() => {
    if (!peekTranscriptId || summaryCache.has(peekTranscriptId)) return;
    let cancelled = false;
    const timer = setTimeout(() => {
      setSummaryCache((m) => new Map(m).set(peekTranscriptId, "loading"));
      fetchTranscript(peekTranscriptId)
        .then((tr) => {
          if (!cancelled) setSummaryCache((m) => new Map(m).set(peekTranscriptId, tr.summary));
        })
        .catch(() => {
          if (!cancelled) setSummaryCache((m) => new Map(m).set(peekTranscriptId, "error"));
        });
    }, 200);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [peekTranscriptId, fetchTranscript]);
  const peekSummary = peekTranscriptId ? summaryCache.get(peekTranscriptId) : undefined;

  const refresh = useCallback(async ({ resetRecordings = false } = {}) => {
    const [jobsR, recR, statsR, accountR] = await Promise.allSettled([
      fetchJobs(),
      resetRecordings && fetchRecordings
        ? fetchRecordings({ limit: RECORDINGS_PAGE_SIZE })
        : Promise.resolve(undefined),
      fetchDashboardStats ? fetchDashboardStats() : Promise.resolve(undefined),
      fetchAccountStatus ? fetchAccountStatus() : Promise.resolve(undefined),
    ]);
    if (jobsR.status === "fulfilled") {
      setJobs(jobsR.value.items);
      setOrigin(jobsR.value.origin);
      setLoadError(undefined);
    } else {
      setLoadError(jobsR.reason instanceof Error ? jobsR.reason.message : String(jobsR.reason));
    }
    if (recR.status === "fulfilled" && recR.value) {
      setRecordings(recR.value.items);
      setRecordingsNextCursor(recR.value.nextCursor ?? null);
      setRecordingsTotalCount(recR.value.totalCount);
    }
    if (statsR.status === "fulfilled" && statsR.value) setStats(statsR.value);
    if (accountR.status === "fulfilled") {
      setAccountStatus(accountR.value);
    } else {
      setAccountStatus("error");
    }
  }, [fetchJobs, fetchRecordings, fetchDashboardStats, fetchAccountStatus]);

  const transcribeStoppedRecording = useCallback(async () => {
    const current = liveRecord;
    if (current?.kind !== "stopped") return;
    const artifact = current.artifact;
    if (artifact?.recordingId && artifact.uploadStatus === "uploaded") {
      await refresh({ resetRecordings: true });
      setStack([{ kind: "overview" }, { kind: "recordingDetail", recordingId: artifact.recordingId }]);
      return;
    }
    if (!artifact?.audioPath) {
      setNotice("No local audio file is available to transcribe.");
      return;
    }
    if (!transcribeRecordingArtifact) {
      setNotice("Transcription is not available in this CLI session.");
      return;
    }

    setLiveRecord({
      ...current,
      artifact: {
        ...artifact,
        uploadStatus: "uploading",
        transcriptionStatus: "not_started",
        error: undefined,
      },
    });
    try {
      const uploaded = await transcribeRecordingArtifact(artifact);
      const transcriptionStatus =
        uploaded.transcriptId != null || uploaded.status === "succeeded" || uploaded.status === "ready"
          ? "ready"
          : uploaded.status === "running"
            ? "processing"
            : uploaded.jobId
              ? "queued"
              : "not_started";
      setLiveRecord({
        ...current,
        artifact: {
          ...artifact,
          recordingId: uploaded.recordingId,
          ...(uploaded.jobId ? { jobId: uploaded.jobId } : {}),
          ...(uploaded.transcriptId ? { transcriptId: uploaded.transcriptId } : {}),
          uploadStatus: "uploaded",
          transcriptionStatus,
        },
      });
      setNotice(
        transcriptionStatus === "ready"
          ? "Transcription ready."
          : uploaded.jobId
            ? "Transcription queued."
            : "Uploaded to Recappi Cloud.",
      );
      await refresh({ resetRecordings: true });
    } catch (error) {
      setLiveRecord({
        ...current,
        artifact: {
          ...artifact,
          uploadStatus: "failed",
          transcriptionStatus: "failed",
          error: transcribeHandoffErrorCopy(error),
        },
      });
      setNotice("Transcription failed. Press enter to retry.");
    }
  }, [liveRecord, refresh, transcribeRecordingArtifact]);

  const loadMoreRecordings = useCallback(async () => {
    if (!fetchRecordings || !recordingsNextCursor || loadingMoreRecordings) return;
    setLoadingMoreRecordings(true);
    try {
      const page = await fetchRecordings({
        limit: RECORDINGS_PAGE_SIZE,
        cursor: recordingsNextCursor,
      });
      setRecordings((prev) => {
        const seen = new Set(prev.map((item) => item.recordingId));
        const merged = [...prev];
        for (const item of page.items) {
          if (!seen.has(item.recordingId)) merged.push(item);
        }
        return merged;
      });
      setRecordingsNextCursor(page.nextCursor ?? null);
      setRecordingsTotalCount(page.totalCount);
      setLoadError(undefined);
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : String(error));
    } finally {
      setLoadingMoreRecordings(false);
    }
  }, [fetchRecordings, loadingMoreRecordings, recordingsNextCursor]);

  useEffect(() => {
    void refresh({ resetRecordings: true });
    const id = setInterval(() => void refresh(), pollMs);
    return () => clearInterval(id);
  }, [refresh, pollMs]);

  const hasRunning = jobs.some((item) => item.status === "running");
  useEffect(() => {
    if (!hasRunning) return;
    const id = setInterval(() => setSpinnerFrame((f) => f + 1), spinnerMs);
    return () => clearInterval(id);
  }, [hasRunning, spinnerMs]);

  // Map each recording to its most relevant job status (running > queued > …) so
  // rows can show a real processing state (transcribing / queued), not just
  // whether a transcript exists.
  const jobRank = (s: string) =>
    s === "running" ? 4 : s === "queued" ? 3 : s === "failed" ? 2 : s === "succeeded" ? 1 : 0;
  const jobStatusByRecording = new Map<string, string>();
  for (const job of jobs) {
    const prev = jobStatusByRecording.get(job.recordingId);
    if (!prev || jobRank(job.status) > jobRank(prev)) {
      jobStatusByRecording.set(job.recordingId, job.status);
    }
  }

  // Overview is the recordings workbench: the full list, scrolled/windowed.
  const listLength =
    screen.kind === "jobs" ? jobs.length : screen.kind === "overview" ? recordings.length : 0;
  useEffect(() => {
    setSelected((i) => Math.max(0, Math.min(i, Math.max(0, listLength - 1))));
  }, [listLength]);

  const visibleRecordingRows = Math.max(3, size.rows - 6);
  useEffect(() => {
    if (screen.kind !== "overview" || !recordingsNextCursor) return;
    const nearLoadedEnd = recordings.length - selected <= RECORDINGS_PREFETCH_REMAINING;
    const underfilledViewport = recordings.length < visibleRecordingRows;
    if (nearLoadedEnd || underfilledViewport) void loadMoreRecordings();
  }, [
    loadMoreRecordings,
    recordings.length,
    recordingsNextCursor,
    screen.kind,
    selected,
    visibleRecordingRows,
  ]);

  const openTranscript = useCallback(
    async (transcriptId: string) => {
      setStack((st) => [...st, { kind: "transcript", loading: true }]);
      try {
        const data = await fetchTranscript(transcriptId);
        setStack((st) => [...st.slice(0, -1), { kind: "transcript", loading: false, data }]);
      } catch (error) {
        setStack((st) => [
          ...st.slice(0, -1),
          {
            kind: "transcript",
            loading: false,
            error: error instanceof Error ? error.message : String(error),
          },
        ]);
      }
    },
    [fetchTranscript],
  );

  // Detail screen: lazily fetch the full transcript (summary + segments) for the
  // open recording, cached by transcriptId.
  const detailTranscriptId =
    screen.kind === "recordingDetail"
      ? recordings.find((r) => r.recordingId === screen.recordingId)?.activeTranscriptId
      : undefined;
  useEffect(() => {
    if (!detailTranscriptId || transcriptCache.has(detailTranscriptId)) return;
    let cancelled = false;
    setTranscriptCache((m) => new Map(m).set(detailTranscriptId, "loading"));
    fetchTranscript(detailTranscriptId)
      .then((tr) => {
        if (!cancelled) setTranscriptCache((m) => new Map(m).set(detailTranscriptId, tr));
      })
      .catch(() => {
        if (!cancelled) setTranscriptCache((m) => new Map(m).set(detailTranscriptId, "error"));
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [detailTranscriptId, fetchTranscript]);

  // Download / open / reveal the recording audio, tracking per-recording state.
  const setAudio = (recordingId: string, action: AudioAction) =>
    setAudioCache((m) => new Map(m).set(recordingId, action));
  const runAudio = useCallback(
    async (recordingId: string, mode: "open" | "download" | "finder") => {
      if (!recordingAudio) {
        setNotice("Audio actions are not available");
        return;
      }
      setAudio(recordingId, { status: "downloading" });
      try {
        const localPath = await recordingAudio.downloadRecordingAudio(recordingId);
        if (mode === "open") {
          setAudio(recordingId, { status: "opening", localPath });
          await recordingAudio.openPath(localPath);
        } else if (mode === "finder") {
          setAudio(recordingId, { status: "opening", localPath });
          await recordingAudio.revealInFinder(localPath);
        }
        setAudio(recordingId, { status: "ready", localPath });
        void refreshDownloadedIds(); // reflect the new local download in the list
      } catch (error) {
        setAudio(recordingId, {
          status: "error",
          error: error instanceof Error ? error.message : String(error),
        });
      }
    },
    [recordingAudio, refreshDownloadedIds],
  );

  const goTab = (tab: TabKey) => {
    setStack([{ kind: tab }]);
    setSelected(0);
    setNotice(undefined);
  };
  const back = () => setStack((st) => (st.length > 1 ? st.slice(0, -1) : st));

  useInput((input, key) => {
    setNotice(undefined);
    if (screen.kind === "recordSetup") {
      if (input === "q" || key.leftArrow) back();
      return;
    }
    if (screen.kind === "record") {
      if (liveRecord?.kind === "error" && input === "r") {
        beginLiveRecord(liveRecord.selection ?? DEFAULT_RECORDING_SELECTION);
        return;
      }
      if (liveRecord?.kind === "error" && input === "o") {
        openUrl?.(settingsUrlFromRecordError(liveRecord.data));
        return;
      }
      if (liveRecord?.kind === "stopped" && key.return) {
        void transcribeStoppedRecording();
        return;
      }
      if (input === "q" || key.escape || key.leftArrow || input === "n") void stopLiveRecord();
      return;
    }
    if (input === "q") return exit();
    if (key.escape || key.leftArrow) return back();
    if (input === "1") return goTab("overview");
    if (input === "2") return goTab("jobs");
    if (input === "3") return goTab("account");
    if (input === "n") {
      setStack((st) => [...st, { kind: "recordSetup" }]);
      if (fetchRecordSetup) {
        fetchRecordSetup()
          .then((model) => {
            setRecordSetupInputs({
              sources: model.sources.length > 0 ? model.sources : DEFAULT_RECORDING_SOURCES,
              microphones: model.microphones ?? [],
            });
          })
          .catch(() => {
            setRecordSetupInputs({ sources: DEFAULT_RECORDING_SOURCES, microphones: [] });
          });
      }
      return;
    }
    if (input === "r") return void refresh({ resetRecordings: true });

    if (screen.kind === "overview") {
      if (key.upArrow || input === "k") setSelected((i) => Math.max(0, i - 1));
      if (key.downArrow || input === "j") setSelected((i) => Math.min(recordings.length - 1, i + 1));
      const rec = recordings[selected];
      if (key.return && rec)
        setStack((st) => [...st, { kind: "recordingDetail", recordingId: rec.recordingId }]);
      if (input === "t" && rec?.activeTranscriptId) void openTranscript(rec.activeTranscriptId);
      return;
    }
    if (screen.kind === "jobs") {
      if (key.upArrow || input === "k") setSelected((i) => Math.max(0, i - 1));
      if (key.downArrow || input === "j") setSelected((i) => Math.min(jobs.length - 1, i + 1));
      const job = jobs[selected];
      if (key.return && job) setStack((st) => [...st, { kind: "jobDetail", jobId: job.jobId }]);
      if (input === "t" && job?.transcriptId) void openTranscript(job.transcriptId);
      return;
    }
    if (screen.kind === "jobDetail") {
      const job = jobs.find((j) => j.jobId === screen.jobId);
      const links = job ? resolveJobLinks(job, origin) : {};
      if (input === "t" && job?.transcriptId) void openTranscript(job.transcriptId);
      else if ((input === "o" || input === "w") && links.webUrl) openUrl?.(links.webUrl);
      else if (input === "m") setNotice("Mac app deeplink not available yet");
      else if (input === "c" && links.webUrl) {
        copyText?.(links.webUrl);
        setNotice("Link copied");
      }
      return;
    }
    if (screen.kind === "recordingDetail") {
      const rec = recordings.find((r) => r.recordingId === screen.recordingId);
      const links = rec ? resolveRecordingLinks(rec.recordingId, rec.origin) : {};
      if (input === "t" && rec?.activeTranscriptId) void openTranscript(rec.activeTranscriptId);
      else if (input === "o" && rec) void runAudio(rec.recordingId, "open");
      else if (input === "d" && rec) void runAudio(rec.recordingId, "download");
      else if (input === "f" && rec) void runAudio(rec.recordingId, "finder");
      else if (input === "w" && links.webUrl) openUrl?.(links.webUrl);
      else if (input === "c" && links.webUrl) {
        copyText?.(links.webUrl);
        setNotice("Link copied");
      }
      return;
    }
  });

  // Full-screen drill-ins.
  if (screen.kind === "transcript") {
    return <TranscriptView loading={screen.loading} data={screen.data} error={screen.error} />;
  }
  if (screen.kind === "jobDetail") {
    const job = jobs.find((j) => j.jobId === screen.jobId);
    if (!job) return <Missing label="Job" />;
    return (
      <Detail notice={notice}>
        <JobDetailView item={job} origin={origin} spinnerFrame={spinnerFrame} nowMs={now()} />
      </Detail>
    );
  }
  if (screen.kind === "recordingDetail") {
    const rec = recordings.find((r) => r.recordingId === screen.recordingId);
    if (!rec) return <Missing label="Recording" />;
    const detailTranscript = rec.activeTranscriptId
      ? transcriptCache.get(rec.activeTranscriptId)
      : undefined;
    return (
      <Detail notice={notice}>
        <RecordingDetailView
          item={rec}
          nowMs={now()}
          transcript={detailTranscript}
          audio={audioCache.get(rec.recordingId)}
        />
      </Detail>
    );
  }
  if (screen.kind === "recordSetup") {
    return (
      <Box flexDirection="column" height={size.rows} paddingX={1}>
        <RecordSetupView
          model={recordSetupModel}
          onStart={beginLiveRecord}
          onCancel={() =>
            setStack((st) => (st.length > 1 ? st.slice(0, -1) : [{ kind: "overview" }]))
          }
        />
      </Box>
    );
  }
  if (screen.kind === "record") {
    if (liveRecord?.kind === "live" && liveRecord.session.mode === "live_captions") {
      return <LiveCaptionsScreen source={liveRecord.session.source} now={now} />;
    }
    if (
      liveRecord?.kind === "live" ||
      liveRecord?.kind === "starting" ||
      liveRecord?.kind === "stopping" ||
      liveRecord?.kind === "stopped"
    ) {
      return (
        <Detail notice={notice}>
          <RecordingHeroScreen
            telemetry={liveRecord.telemetry}
            artifact={liveRecord.kind === "stopped" ? liveRecord.artifact : undefined}
            canTranscribe={Boolean(transcribeRecordingArtifact)}
            now={now}
          />
        </Detail>
      );
    }
    return (
      <Box flexDirection="column" height={size.rows} paddingX={1}>
        <Box flexGrow={1} flexDirection="column" paddingX={1} paddingTop={1}>
          {liveRecord?.kind === "error" ? (
            (() => {
              if (liveRecord.code === "record.permission_required") {
                return (
                  <PermissionPreflightView items={permissionItemsFromRecordError(liveRecord.data)} />
                );
              }
              const copy = recordErrorCopy(liveRecord.code, liveRecord.message);
              return (
                <>
                  <Text color={copy.tone}>{copy.title}</Text>
                  {copy.detail ? <Text dimColor>{copy.detail}</Text> : null}
                </>
              );
            })()
          ) : (
            <Text dimColor>Starting recording…</Text>
          )}
        </Box>
        <Footer keys="r retry · o settings · q / esc / ← back" />
      </Box>
    );
  }

  const tab: TabKey =
    screen.kind === "jobs" ? "jobs" : screen.kind === "account" ? "account" : "overview";

  let body: React.ReactElement;
  let position = "";
  if (screen.kind === "overview") {
    // Budget the list body for chrome (tabs + stats bar + column header +
    // footer) and let the window account for date-group headers so the frame
    // never overflows the screen.
    const listBudget = Math.max(3, size.rows - 6);
    const buckets = recordings.map((r) => dateBucket(r.createdAt, now()));
    const win = groupedListWindow(buckets, selected, listBudget);
    const totalRecordings = Math.max(
      recordingsTotalCount ?? stats?.recordings.total ?? recordings.length,
      recordings.length,
    );
    position = recordings.length
      ? `${selected + 1} / ${totalRecordings}${loadingMoreRecordings ? " · loading" : ""}`
      : loadingMoreRecordings
        ? "loading"
        : "0";
    // On wide terminals, show a peek summary panel beside the list; the list
    // takes the remaining width so columns still align.
    const showPeek = size.columns >= 100;
    const peekWidth = showPeek ? 34 : 0;
    const listColumns = showPeek ? Math.max(30, size.columns - peekWidth - 3) : size.columns;
    body = (
      <OverviewView
        recordings={recordings.slice(win.start, win.end)}
        selectedIndex={selected - win.start}
        jobs={jobs}
        stats={stats}
        nowMs={now()}
        columns={listColumns}
        jobStatusByRecording={jobStatusByRecording}
        downloadedRecordingIds={downloadedIds}
        spinnerFrame={spinnerFrame}
        peekItem={recordings[selected]}
        peekSummary={peekSummary}
        showPeek={showPeek}
        peekWidth={peekWidth}
      />
    );
  } else if (screen.kind === "account") {
    position = "";
    body = <AccountView status={accountStatus} />;
  } else {
    const win = listWindow(selected, jobs.length, Math.max(3, size.rows - 4));
    position = jobs.length ? `${selected + 1} / ${jobs.length}` : "0";
    body = (
      <JobsView
        items={jobs.slice(win.start, win.end)}
        selectedIndex={selected - win.start}
        spinnerFrame={spinnerFrame}
      />
    );
  }

  const footerKeys =
    screen.kind === "jobs"
      ? `${position}  ·  ↑↓ select · ⏎ job · t transcript · n record · 1 overview · 3 account · r refresh · q quit`
      : screen.kind === "account"
        ? "3 account  ·  n record · 1 overview · 2 jobs · r refresh · q quit"
      : `${position}  ·  ↑↓ scroll · ⏎ open · t transcript · n record · 2 jobs · 3 account · r refresh · q quit`;

  return (
    <Box flexDirection="column" height={size.rows} paddingX={1}>
      <Header active={tab} />
      <Box flexGrow={1} flexDirection="column">
        {body}
        {loadError && jobs.length === 0 && recordings.length === 0 ? (
          <Box marginTop={1}>
            <Text color="red">! {loadError}</Text>
          </Box>
        ) : null}
      </Box>
      <Footer keys={footerKeys} />
    </Box>
  );
}

function Detail({
  notice,
  children,
}: {
  notice?: string;
  children: React.ReactNode;
}): React.ReactElement {
  return (
    <Box flexDirection="column">
      {children}
      {notice ? (
        <Box paddingX={1}>
          <Text color="green">{notice}</Text>
        </Box>
      ) : null}
    </Box>
  );
}

function Missing({ label }: { label: string }): React.ReactElement {
  return (
    <Box flexDirection="column" paddingX={1}>
      <Text dimColor>{label} no longer in the list.</Text>
      <Text dimColor>esc back · q quit</Text>
    </Box>
  );
}
