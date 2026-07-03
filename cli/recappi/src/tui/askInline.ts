import type { AskCitation } from "../api";

// Inline-citation rendering for Ask answers, mirroring the macOS app's
// `AskInlineAnswer` (RecappiMini/Views/Cloud/Detail/CloudDetailAskModels.swift).
// The backend keeps `[[seg-N]]` markers in the assistant text so every client
// places citations next to the sentence they support; this helper strips unknown
// markers and turns known ones into short inline labels. Keep this in parity with
// the Swift version (golden test) so the two clients never drift.

const MARKER = /\[\[(seg-[^\]]+)\]\]/g;
// Marker plus any leading whitespace, for the plain-stripped fallback.
const LOOSE_MARKER = /\s*\[?\[seg-[^\]]+\]\]?/g;
// Punctuation that should hug the preceding word when a marker is removed.
const TRAILING_PUNCTUATION = ".。!！?？,，;；:：";

export type AskInlineSegment =
  | { kind: "text"; text: string }
  | { kind: "citation"; label: string; citation: AskCitation };

export function formatAskTimecode(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

// The low-interruption inline label: the start timecode when known, else the
// first part of a range label, else the 1-based index, else "Source".
export function askCitationInlineLabel(citation: AskCitation): string {
  if (typeof citation.startMs === "number") return formatAskTimecode(citation.startMs);
  const label = citation.label?.trim();
  if (label) {
    const firstRangePart = label.split(/[-–—]/)[0]?.trim();
    if (firstRangePart) return firstRangePart;
  }
  if (typeof citation.index === "number") return `#${citation.index + 1}`;
  return "Source";
}

export function hasCitationMarkers(content: string): boolean {
  MARKER.lastIndex = 0;
  return MARKER.test(content);
}

// Plain answer with every marker removed (used for --json-free plain output and
// as the fallback when there are no resolvable citations).
export function strippedAskAnswer(content: string): string {
  return content.replace(LOOSE_MARKER, "");
}

// Split the answer into text / citation segments with citations placed inline
// right after the text they support. Unknown markers are dropped (with the same
// punctuation cleanup as the app).
export function renderAskInline(content: string, citations: AskCitation[]): AskInlineSegment[] {
  const bySegmentId = new Map<string, AskCitation>();
  for (const citation of citations) {
    if (citation.segmentId && !bySegmentId.has(citation.segmentId)) {
      bySegmentId.set(citation.segmentId, citation);
    }
  }
  if (!hasCitationMarkers(content) || bySegmentId.size === 0) {
    const text = strippedAskAnswer(content);
    return text ? [{ kind: "text", text }] : [];
  }

  const segments: AskInlineSegment[] = [];
  let lastVisibleChar: string | undefined;

  const pushText = (text: string) => {
    if (!text) return;
    const prev = segments[segments.length - 1];
    if (prev && prev.kind === "text") prev.text += text;
    else segments.push({ kind: "text", text });
    lastVisibleChar = text[text.length - 1];
  };
  const pushCitation = (citation: AskCitation) => {
    // Give the marker a leading space when it would otherwise stick to a word.
    if (lastVisibleChar !== undefined && !/\s/.test(lastVisibleChar)) pushText(" ");
    const label = askCitationInlineLabel(citation);
    segments.push({ kind: "citation", label, citation });
    lastVisibleChar = label[label.length - 1];
  };

  MARKER.lastIndex = 0;
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = MARKER.exec(content)) !== null) {
    const textBefore = content.slice(lastIndex, match.index);
    const citation = bySegmentId.get(match[1]!);
    if (citation) {
      pushText(textBefore);
      pushCitation(citation);
    } else {
      const nextChar = content[match.index + match[0].length];
      pushText(cleanupBeforeRemovedMarker(textBefore, nextChar));
    }
    lastIndex = match.index + match[0].length;
  }
  pushText(content.slice(lastIndex));
  return segments;
}

function cleanupBeforeRemovedMarker(text: string, nextChar: string | undefined): string {
  if (!nextChar || !TRAILING_PUNCTUATION.includes(nextChar)) return text;
  return text.replace(/[ \t]+$/, "");
}

function truncateSnippet(snippet: string, max = 100): string {
  const clean = snippet.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

// Render the answer for the plain (`recappi ask`, human/non-TTY) surface: inline
// ⟨mm:ss⟩ citations placed in-text, then a compact Sources list mapping each
// marker to its speaker/snippet. Used by the `ask` command; keep the inline
// placement identical to the TUI so the two surfaces read the same.
export function formatAskAnswerPlain(content: string, citations: AskCitation[]): string {
  const segments = renderAskInline(content, citations);
  const body = segments
    .map((segment) => (segment.kind === "text" ? segment.text : `⟨${segment.label}⟩`))
    .join("")
    .trim();

  // Only list citations that were actually placed inline, de-duplicated, in order.
  const seen = new Set<string>();
  const cited: AskCitation[] = [];
  for (const segment of segments) {
    if (segment.kind !== "citation") continue;
    const key = segment.citation.segmentId ?? segment.label;
    if (seen.has(key)) continue;
    seen.add(key);
    cited.push(segment.citation);
  }
  if (cited.length === 0) return body;

  const sources = cited.map((citation) => {
    const label = askCitationInlineLabel(citation);
    const meta = [citation.speaker?.trim(), citation.snippet ? truncateSnippet(citation.snippet) : ""]
      .filter(Boolean)
      .join(" · ");
    return `  ⟨${label}⟩${meta ? ` ${meta}` : ""}`;
  });
  return `${body}\n\nSources:\n${sources.join("\n")}`;
}
