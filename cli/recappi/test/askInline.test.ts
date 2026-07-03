import { describe, expect, it } from "vitest";
import type { AskCitation } from "../src/api";
import {
  askCitationInlineLabel,
  formatAskAnswerPlain,
  formatAskTimecode,
  renderAskInline,
  strippedAskAnswer,
} from "../src/tui/askInline";

// Parity with the macOS app's AskInlineAnswer
// (RecappiMini/Views/Cloud/Detail/CloudDetailAskModels.swift). Same input →
// same stripping/placement so the two clients never drift.
describe("askInline", () => {
  const seg = (over: Partial<AskCitation> = {}): AskCitation => ({
    segmentId: "seg-1",
    startMs: 83_000, // 1:23
    speaker: "Peng",
    snippet: "the relevant sentence",
    ...over,
  });

  it("formats timecodes like the app (m:ss and h:mm:ss)", () => {
    expect(formatAskTimecode(0)).toBe("0:00");
    expect(formatAskTimecode(83_000)).toBe("1:23");
    expect(formatAskTimecode(3_723_000)).toBe("1:02:03");
    expect(formatAskTimecode(-5)).toBe("0:00");
  });

  it("labels a citation by start timecode, then label range, index, then Source", () => {
    expect(askCitationInlineLabel(seg())).toBe("1:23");
    expect(askCitationInlineLabel(seg({ startMs: null, label: "2:00 – 2:30" }))).toBe("2:00");
    expect(askCitationInlineLabel(seg({ startMs: null, label: undefined, index: 4 }))).toBe("#5");
    expect(askCitationInlineLabel(seg({ startMs: null, label: undefined, index: undefined }))).toBe(
      "Source",
    );
  });

  it("returns a single text segment when there are no markers", () => {
    expect(renderAskInline("Just an answer.", [])).toEqual([
      { kind: "text", text: "Just an answer." },
    ]);
  });

  it("places a known citation inline right after its sentence", () => {
    const out = renderAskInline("They shipped it[[seg-1]].", [seg()]);
    expect(out).toEqual([
      { kind: "text", text: "They shipped it " },
      { kind: "citation", label: "1:23", citation: seg() },
      { kind: "text", text: "." },
    ]);
  });

  it("does not insert a leading space when the marker follows whitespace", () => {
    const out = renderAskInline("They shipped it [[seg-1]]done.", [seg()]);
    expect(out[0]).toEqual({ kind: "text", text: "They shipped it " });
    expect(out[1]).toEqual({ kind: "citation", label: "1:23", citation: seg() });
  });

  it("drops unknown markers and trims trailing space before punctuation", () => {
    // No citation matches seg-9 → marker removed; the space before "." is cleaned.
    const out = renderAskInline("An unsupported claim [[seg-9]].", []);
    expect(out).toEqual([{ kind: "text", text: "An unsupported claim." }]);
  });

  it("strips all markers for the plain fallback", () => {
    expect(strippedAskAnswer("A [[seg-1]] b [[seg-2]] c")).toBe("A b c");
  });

  it("formats the plain answer with inline markers and a Sources list", () => {
    const out = formatAskAnswerPlain("They shipped it[[seg-1]].", [seg()]);
    expect(out).toBe(
      "They shipped it ⟨1:23⟩.\n\nSources:\n  ⟨1:23⟩ Peng · the relevant sentence",
    );
  });

  it("omits the Sources list when there are no placed citations", () => {
    expect(formatAskAnswerPlain("Plain answer, no refs.", [])).toBe("Plain answer, no refs.");
  });
});
