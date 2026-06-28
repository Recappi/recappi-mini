// Local interactive demo of the Ink dashboard with sample data — lets you feel
// the real UX (keyboard nav, spinner, advancing progress, transcript drill-in)
// without needing the /api/jobs server route deployed.
//
// Run from cli/recappi:  npx tsx scripts/dashboard-demo.tsx
//
// Injects sample data for all root screens (Overview/home, Jobs, Account) so the
// new quality-bar styling can be eyeballed in a real terminal without a server.
import { runDashboard } from "../src/tui/index";
import type {
  AccountStatusData,
  DashboardStatsData,
  JobListData,
  RecordingListData,
  TranscriptData,
} from "../../packages/contracts/src/index";

const now = Date.now();
const HOUR = 3_600_000;
const DAY = 86_400_000;
const TOTAL = 13 * 60_000 + 48_000; // 13:48
let processed = 4 * 60_000; // start partway through

// Sample recordings so the Overview home shows the real list + peek (date
// grouping, semantic glyphs, downloaded marker), not "No recordings yet".
const recordings = [
  { recordingId: "rec_1", summaryTitle: "Design review — recap CLI redesign", status: "ready", durationMs: TOTAL, sizeBytes: 52_000_000, activeTranscriptId: "tr_1", createdAt: now - 30 * 60_000, updatedAt: now, origin: "local-demo" },
  { recordingId: "rec_2", title: "Product call with Alex", status: "ready", durationMs: 41 * 60_000, sizeBytes: 44_000_000, activeTranscriptId: "tr_2", createdAt: now - 2 * HOUR, updatedAt: now, origin: "local-demo" },
  { recordingId: "rec_3", title: "Weekly sync", status: "ready", durationMs: 22 * 60_000, createdAt: now - 26 * HOUR, updatedAt: now, origin: "local-demo" },
  { recordingId: "rec_4", title: "1:1 with Sam", status: "failed", durationMs: 31 * 60_000, createdAt: now - 3 * DAY, updatedAt: now, origin: "local-demo" },
  { recordingId: "rec_5", title: "Customer interview", status: "ready", durationMs: 57 * 60_000, activeTranscriptId: "tr_5", createdAt: now - 12 * DAY, updatedAt: now, origin: "local-demo" },
] as const;

const fetchRecordings = async (): Promise<RecordingListData> => ({
  items: recordings as unknown as RecordingListData["items"],
  totalCount: recordings.length,
  limit: 50,
  origin: "local-demo",
});

const fetchDashboardStats = async (): Promise<DashboardStatsData> => ({
  origin: "local-demo",
  recordings: { total: 23, ready: 18, uploading: 0, failed: 1, aborted: 0, totalDurationMs: 640 * 60_000, totalSizeBytes: 1_200_000_000 },
  jobs: { active: 2, queued: 1, running: 1, succeeded: 18, failed: 1 },
});

const fetchAccountStatus = async (): Promise<AccountStatusData> => ({
  loggedIn: true,
  email: "pengx17@gmail.com",
  userId: "u_demo",
  origin: "local-demo",
  billing: {
    origin: "local-demo",
    tier: "pro",
    minutesUsed: 420,
    minutesCap: 600,
    storageBytes: 3_200_000_000,
    storageCapBytes: 10_000_000_000,
    isOverMinutes: false,
    isOverStorage: false,
    batchMinutesUsed: 380,
    realtimeMinutesUsed: 40,
    periodStart: Math.floor((now - 18 * DAY) / 1000),
    periodEnd: Math.floor((now + 12 * DAY) / 1000),
  },
  localStore: { path: "~/.recappi/cli.db", accountScopedArtifacts: 7, unattributedArtifacts: 2 },
});

// Each poll advances the running job's processed audio, so the progress bar
// visibly moves while you watch — like a real transcription.
const fetchJobs = async (): Promise<JobListData> => {
  processed = Math.min(TOTAL, processed + 75_000);
  const running = processed >= TOTAL;
  return {
    items: [
      {
        jobId: "job_1",
        recordingId: "rec_1",
        status: running ? "succeeded" : "running",
        provider: "gemini",
        transcriptId: running ? "tr_1" : undefined,
        processedDurationMs: processed,
        recording: { title: "Design review", durationMs: TOTAL },
      },
      {
        jobId: "job_2",
        recordingId: "rec_2",
        status: "succeeded",
        transcriptId: "tr_2",
        recording: { title: "Product call with Alex", durationMs: 41 * 60_000 },
      },
      {
        jobId: "job_3",
        recordingId: "rec_3",
        status: "queued",
        recording: { title: "Weekly sync", durationMs: 22 * 60_000 },
      },
      {
        jobId: "job_4",
        recordingId: "rec_4",
        status: "failed",
        recording: { title: "Broken upload", durationMs: 2 * 60_000 },
      },
    ],
    status: "active",
    limit: 20,
    origin: "local-demo",
  };
};

const fetchTranscript = async (transcriptId: string): Promise<TranscriptData> => ({
  transcriptId,
  recordingId: "rec_2",
  jobId: "job_2",
  provider: "gemini",
  model: "gemini-2.5-pro",
  createdAt: 1,
  text: "...",
  segments: [
    {
      startMs: 0,
      endMs: 3_200,
      speaker: "Alex",
      text: "Thanks for joining, let's kick things off.",
    },
    {
      startMs: 12_500,
      endMs: 16_000,
      speaker: "Peng",
      text: "Sounds good — what's the agenda today?",
    },
    {
      startMs: 75_000,
      endMs: 80_400,
      speaker: "Alex",
      text: "Mainly the CLI dashboard and the release plan.",
    },
  ],
  summary: {
    status: "succeeded",
    title: "Product call with Alex",
    tldr: "Walked through the CLI dashboard and agreed to ship it this week.",
    keyPoints: ["Dashboard replaces the web monitoring view", "Ship behind a canary first"],
    actionItems: [{ who: "Peng", what: "review the dashboard UX" }],
  },
});

await runDashboard({
  fetchJobs,
  fetchTranscript,
  fetchRecordings,
  fetchDashboardStats,
  fetchAccountStatus,
});
