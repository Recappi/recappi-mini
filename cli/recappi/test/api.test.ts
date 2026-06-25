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
