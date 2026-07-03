import { describe, expect, it } from "vitest";
import { RecappiApiClient } from "../src/api";
import type { AuthContext } from "../src/auth";

const auth: AuthContext = {
  origin: "https://recordmeet.ing",
  token: "token",
  source: "env",
};

describe("Recappi API client", () => {
  it("maps billing status into the CLI account usage contract", async () => {
    const client = new RecappiApiClient(auth, { fetchImpl: billingFetch() });

    await expect(client.billingStatus()).resolves.toEqual({
      origin: "https://recordmeet.ing",
      tier: "unlimited",
      periodStart: 1710000000000,
      periodEnd: 1712592000000,
      storageBytes: 1234,
      storageCapBytes: null,
      minutesUsed: 42.5,
      batchMinutesUsed: 40,
      realtimeMinutesUsed: 2.5,
      minutesCap: null,
      isOverStorage: false,
      isOverMinutes: false,
    });
  });

  it("fetches recording Ask thread history with inline citation markers intact", async () => {
    const client = new RecappiApiClient(auth, { fetchImpl: askThreadFetch() });

    await expect(client.fetchAskThread("recording-1")).resolves.toMatchObject({
      origin: "https://recordmeet.ing",
      thread: { id: "thread-1", recordingId: "recording-1" },
      messages: [
        {
          id: "msg-assistant",
          role: "assistant",
          status: "completed",
          content: "Launch is Friday [[seg-2]].",
          citations: [
            {
              id: "citation-1",
              segmentId: "seg-2",
              index: 1,
              startMs: 1000,
              endMs: 2500,
              label: "0:01-0:02",
              speaker: "Peng",
              snippet: "Friday is the launch date.",
              order: 0,
            },
          ],
        },
      ],
    });
  });

  it("fetches recording Ask suggestions", async () => {
    const client = new RecappiApiClient(auth, { fetchImpl: askSuggestionsFetch() });

    await expect(client.fetchAskSuggestions("recording-1", { language: "en" })).resolves.toEqual({
      origin: "https://recordmeet.ing",
      transcriptId: "transcript-1",
      model: "gpt-5.5",
      language: "English (en)",
      cached: true,
      suggestions: [
        {
          id: "suggestion-1",
          question: "What launch date did the team choose?",
          reason: "The transcript names Friday.",
        },
      ],
    });
  });

  it("streams recording Ask events over SSE", async () => {
    const requests: unknown[] = [];
    const client = new RecappiApiClient(auth, { fetchImpl: askStreamFetch(requests) });

    const events = [];
    for await (const event of client.askRecordingStream({
      recordingId: "recording-1",
      question: "When is launch?",
      webSearch: true,
      model: "gpt-5.5",
    })) {
      events.push(event);
    }

    expect(requests).toEqual([{ question: "When is launch?", webSearch: true, model: "gpt-5.5" }]);
    expect(events).toEqual([
      {
        type: "metadata",
        recordingId: "recording-1",
        transcriptId: "transcript-1",
        threadId: "thread-1",
        userMessageId: "msg-user",
        assistantMessageId: "msg-assistant",
        model: "gpt-5.5",
        webSearch: true,
        segmentCount: 2,
        citationMarker: "[[seg-id]]",
      },
      { type: "answer_delta", delta: "Launch is " },
      { type: "answer_delta", delta: "Friday [[seg-2]]." },
      {
        type: "citation",
        citation: {
          segmentId: "seg-2",
          index: 1,
          startMs: 1000,
          endMs: 2500,
          label: "0:01-0:02",
          speaker: "Peng",
          snippet: "Friday is the launch date.",
        },
      },
      {
        type: "done",
        threadId: "thread-1",
        userMessageId: "msg-user",
        assistantMessageId: "msg-assistant",
        content: "Launch is Friday [[seg-2]].",
        citations: [
          {
            segmentId: "seg-2",
            index: 1,
            startMs: 1000,
            endMs: 2500,
            label: "0:01-0:02",
            speaker: "Peng",
            snippet: "Friday is the launch date.",
          },
        ],
      },
    ]);
  });

  it("surfaces recording Ask error frames", async () => {
    const client = new RecappiApiClient(auth, {
      fetchImpl: async () =>
        sseResponse([{ event: "error", data: { type: "error", message: "assistant busy" } }]),
    });

    await expect(async () => {
      for await (const _event of client.askRecordingStream({
        recordingId: "recording-1",
        question: "Anything?",
      })) {
        // consume
      }
    }).rejects.toMatchObject({
      descriptor: { code: "cloud.http_error", message: "assistant busy" },
    });
  });
});

function billingFetch(): typeof fetch {
  return async (input) => {
    const url = requestUrl(input);
    expect(url.pathname).toBe("/api/billing/status");
    return jsonResponse({
      tier: "unlimited",
      periodStart: 1710000000000,
      periodEnd: 1712592000000,
      storageBytes: 1234,
      storageCapBytes: null,
      minutesUsed: 42.5,
      batchMinutesUsed: 40,
      realtimeMinutesUsed: 2.5,
      minutesCap: null,
      isOverStorage: false,
      isOverMinutes: false,
    });
  };
}

function askThreadFetch(): typeof fetch {
  return async (input) => {
    const url = requestUrl(input);
    expect(url.pathname).toBe("/api/recordings/recording-1/ask-thread");
    return jsonResponse({
      thread: {
        id: "thread-1",
        recordingId: "recording-1",
        createdAt: 1710000000000,
        updatedAt: 1710000001000,
      },
      messages: [
        {
          id: "msg-assistant",
          role: "assistant",
          status: "completed",
          sequence: 2,
          content: "Launch is Friday [[seg-2]].",
          model: "gpt-5.5",
          webSearch: false,
          errorMessage: null,
          createdAt: 1710000000000,
          updatedAt: 1710000001000,
          citations: [
            {
              id: "citation-1",
              segmentId: "seg-2",
              index: 1,
              startMs: 1000,
              endMs: 2500,
              label: "0:01-0:02",
              speaker: "Peng",
              snippet: "Friday is the launch date.",
              order: 0,
            },
          ],
        },
      ],
    });
  };
}

function askSuggestionsFetch(): typeof fetch {
  return async (input) => {
    const url = requestUrl(input);
    expect(url.pathname).toBe("/api/recordings/recording-1/ask-suggestions");
    expect(url.searchParams.get("language")).toBe("en");
    return jsonResponse({
      transcriptId: "transcript-1",
      model: "gpt-5.5",
      language: "English (en)",
      cached: true,
      suggestions: [
        {
          id: "suggestion-1",
          question: "What launch date did the team choose?",
          reason: "The transcript names Friday.",
        },
      ],
    });
  };
}

function askStreamFetch(requests: unknown[]): typeof fetch {
  return async (input, init) => {
    const url = requestUrl(input);
    expect(url.pathname).toBe("/api/recordings/recording-1/ask-thread/messages");
    expect(init?.method).toBe("POST");
    expect(new Headers(init?.headers).get("accept")).toBe("text/event-stream");
    requests.push(JSON.parse(String(init?.body)));
    return sseResponse([
      {
        event: "metadata",
        data: {
          type: "metadata",
          recordingId: "recording-1",
          transcriptId: "transcript-1",
          threadId: "thread-1",
          userMessageId: "msg-user",
          assistantMessageId: "msg-assistant",
          model: "gpt-5.5",
          webSearch: true,
          segmentCount: 2,
          citationMarker: "[[seg-id]]",
        },
      },
      { event: "answer_delta", data: { type: "answer_delta", delta: "Launch is " } },
      { event: "answer_delta", data: { type: "answer_delta", delta: "Friday [[seg-2]]." } },
      {
        event: "citation",
        data: {
          type: "citation",
          citation: {
            segmentId: "seg-2",
            index: 1,
            startMs: 1000,
            endMs: 2500,
            label: "0:01-0:02",
            speaker: "Peng",
            snippet: "Friday is the launch date.",
          },
        },
      },
      {
        event: "done",
        data: {
          type: "done",
          threadId: "thread-1",
          userMessageId: "msg-user",
          assistantMessageId: "msg-assistant",
          content: "Launch is Friday [[seg-2]].",
          citations: [
            {
              segmentId: "seg-2",
              index: 1,
              startMs: 1000,
              endMs: 2500,
              label: "0:01-0:02",
              speaker: "Peng",
              snippet: "Friday is the launch date.",
            },
          ],
        },
      },
    ]);
  };
}

function sseResponse(events: { event: string; data: unknown }[]): Response {
  const body = events
    .map(({ event, data }) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
    .join("");
  return new Response(body, {
    headers: { "content-type": "text/event-stream" },
  });
}

function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  headers.set("content-type", "application/json");
  return new Response(JSON.stringify(body), {
    ...init,
    headers,
  });
}

function requestUrl(input: Parameters<typeof fetch>[0]): URL {
  if (input instanceof Request) return new URL(input.url);
  if (input instanceof URL) return input;
  return new URL(input);
}
