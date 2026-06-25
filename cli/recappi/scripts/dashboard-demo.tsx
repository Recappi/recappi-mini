// Local interactive demo of the Ink dashboard with sample data — lets you feel
// the real UX (keyboard nav, spinner, advancing progress, transcript drill-in)
// without needing the /api/jobs server route deployed.
//
// Run from cli/recappi:  npx tsx scripts/dashboard-demo.tsx
import { runDashboard } from "../src/tui/index";
import type { JobListData, TranscriptData } from "../../packages/contracts/src/index";

const TOTAL = 13 * 60_000 + 48_000; // 13:48
let processed = 4 * 60_000; // start partway through

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

await runDashboard({ fetchJobs, fetchTranscript });
