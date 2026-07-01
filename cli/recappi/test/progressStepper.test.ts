import { describe, expect, it } from "vitest";
import type { OperationEvent } from "../../packages/contracts/src/index";
import {
  applyStepperEvent,
  completeStepperModel,
  createStepperModel,
  formatStepperLines,
  isStepperEvent,
  markStepperFailed,
  type StepperModel,
} from "../src/progressStepper";

const NOW = 1_000_000;

function ev(status: string, extra: Partial<OperationEvent> = {}): OperationEvent {
  return { type: "progress", command: "upload", status, ...extra } as OperationEvent;
}

function fold(events: OperationEvent[], nowMs = NOW): StepperModel {
  return events.reduce((m, e) => applyStepperEvent(m, e, nowMs), createStepperModel());
}

function lines(model: StepperModel, nowMs = NOW, frame = 0): string[] {
  return formatStepperLines(model, nowMs, frame, false);
}

describe("progressStepper", () => {
  it("routes only upload pipeline events to the stepper", () => {
    expect(isStepperEvent(ev("checking_audio"))).toBe(true);
    expect(isStepperEvent(ev("running", { command: "jobs wait" }))).toBe(false);
    expect(isStepperEvent({ type: "progress", command: "recordings list" } as OperationEvent)).toBe(
      false,
    );
  });

  it("advances Check → Upload with file metadata and a real upload bar", () => {
    const model = fold([
      ev("checking_audio", { filePath: "标准录音 1.mp3" }),
      ev("starting_upload", {
        filePath: "标准录音 1.mp3",
        data: { file: { title: "标准录音 1", sizeBytes: 166_723_584, durationMs: 3_972_000 } },
      }),
      ev("uploading", { recordingId: "rec1", percent: 58 }),
    ]);
    const out = lines(model);
    expect(out[0]).toContain("✓");
    expect(out[0]).toContain("标准录音 1 · 159.0 MB · 1:06:12");
    expect(out[1]).toContain("Upload");
    expect(out[1]).toContain("█"); // real progress bar
    expect(out[1]).toContain("58%");
  });

  it("shows honest transcribe: percent bar when real, spinner + elapsed when not", () => {
    const base = fold([
      ev("uploaded", { origin: "https://recordmeet.ing", recordingId: "rec1" }),
      ev("starting_transcription", { recordingId: "rec1" }),
    ]);
    const noPercent = applyStepperEvent(base, ev("running", { recordingId: "rec1" }), NOW);
    const noPctLine = lines(noPercent, NOW + 134_000)[2]!;
    expect(noPctLine).toContain("Transcribing…");
    expect(noPctLine).toContain("2:14 elapsed");
    expect(noPctLine).not.toContain("%");

    const withPercent = applyStepperEvent(
      base,
      ev("running", { recordingId: "rec1", percent: 35 }),
      NOW,
    );
    const pctLine = lines(withPercent, NOW + 134_000)[2]!;
    expect(pctLine).toContain("35%");
    expect(pctLine).toContain("█");
    expect(pctLine).toContain("2:14 elapsed");
  });

  it("marks all steps done and points Done at the transcript on success", () => {
    const model = fold([
      ev("checking_audio", { filePath: "a.mp3" }),
      ev("starting_upload", { filePath: "a.mp3", data: { file: { title: "a", sizeBytes: 10 } } }),
      ev("uploading", { recordingId: "rec1", percent: 100 }),
      ev("uploaded", { origin: "https://recordmeet.ing", recordingId: "rec1" }),
      ev("starting_transcription", { recordingId: "rec1" }),
      ev("running", { recordingId: "rec1", percent: 80 }),
      ev("succeeded", { recordingId: "rec1", transcriptId: "tr9" }),
    ]);
    const out = lines(model);
    expect(out.every((l) => l.includes("✓"))).toBe(true);
    expect(out[3]).toContain("→ recappi transcript get tr9");
  });

  it("lands the failure marker on the active step with the real reason", () => {
    const uploading = fold([
      ev("checking_audio"),
      ev("starting_upload", { data: { file: { title: "x", sizeBytes: 10 } } }),
    ]);
    const failed = markStepperFailed(uploading, "Couldn't reach Recappi Cloud (cloud.http_error)");
    const out = lines(failed);
    expect(out[1]).toContain("✗");
    expect(out[1]).toContain("Couldn't reach Recappi Cloud (cloud.http_error)");
    expect(out[2]).toContain("○"); // Transcribe stays pending, not falsely ✓
  });

  it("marks Transcribe skipped for an upload-only run", () => {
    const uploaded = fold([
      ev("checking_audio"),
      ev("starting_upload", { data: { file: { title: "note", sizeBytes: 2_400_000 } } }),
      ev("uploaded", { origin: "https://recordmeet.ing", recordingId: "rec1" }),
    ]);
    const done = completeStepperModel(uploaded, { recordingId: "rec1" });
    const out = lines(done);
    expect(out[2]).toContain("·"); // skipped marker
    expect(out[2]).toContain("no --transcribe");
    expect(out[3]).toContain("→ recappi recordings get rec1");
  });
});
