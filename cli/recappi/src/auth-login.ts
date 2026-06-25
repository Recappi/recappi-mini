import { execFile } from "node:child_process";
import os from "node:os";
import { promisify } from "node:util";
import { saveAuthConfig, validateOrigin } from "./auth";
import { cliError } from "./errors";

const execFileAsync = promisify(execFile);

export interface AuthLoginResult {
  loggedIn: true;
  origin: string;
  email?: string;
  userId?: string;
}

export interface AuthLoginDeps {
  fetchImpl?: typeof fetch;
  openUrl?: (url: string) => Promise<void>;
  sleep?: (ms: number) => Promise<void>;
}

interface DeviceStartResponse {
  device_code?: unknown;
  user_code?: unknown;
  verification_uri?: unknown;
  verification_uri_complete?: unknown;
  expires_in?: unknown;
  interval?: unknown;
}

type DevicePollResponse =
  | { status?: "pending"; interval?: number }
  | { status?: "slow_down"; interval?: number }
  | { status?: "expired" }
  | { status?: "denied" }
  | {
      status?: "authorized";
      token?: unknown;
      user?: unknown;
    };

export async function loginWithDeviceCode(opts: {
  origin: string;
  homeDir?: string;
  noOpen?: boolean;
  onPrompt?: (message: string) => void;
  deps?: AuthLoginDeps;
}): Promise<AuthLoginResult> {
  const origin = validateOrigin(opts.origin);
  const fetchImpl = opts.deps?.fetchImpl ?? fetch;
  const sleep = opts.deps?.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const start = await startDeviceAuth(origin, fetchImpl);

  opts.onPrompt?.(
    [
      "To sign in to Recappi CLI:",
      `  1. Open ${start.verificationUri}`,
      `  2. Enter code: ${start.userCode}`,
      "",
    ].join("\n"),
  );

  if (!opts.noOpen) {
    const openUrl = opts.deps?.openUrl ?? openUrlWithSystemBrowser;
    await openUrl(start.verificationUriComplete).catch((error) => {
      opts.onPrompt?.(
        `Could not open the browser automatically: ${
          error instanceof Error ? error.message : String(error)
        }\n`,
      );
    });
  }

  let intervalMs = start.interval * 1000;
  const expiresAt = Date.now() + start.expiresIn * 1000;
  while (Date.now() < expiresAt) {
    await sleep(intervalMs);
    const poll = await pollDeviceAuth(origin, start.deviceCode, fetchImpl);
    if (poll.status === "pending") {
      if (typeof poll.interval === "number") intervalMs = poll.interval * 1000;
      continue;
    }
    if (poll.status === "slow_down") {
      intervalMs =
        (typeof poll.interval === "number" ? poll.interval : intervalMs / 1000 + 5) * 1000;
      continue;
    }
    if (poll.status === "denied") {
      throw cliError("auth.unauthorized", "Recappi CLI sign-in was denied.");
    }
    if (poll.status === "expired") {
      throw cliError("auth.unauthorized", "Recappi CLI sign-in code expired.", {
        hint: "Run recappi auth login again.",
      });
    }
    if (poll.status === "authorized") {
      const token = typeof poll.token === "string" ? poll.token.trim() : "";
      if (!token) {
        throw cliError("cloud.invalid_response", "Recappi device auth returned no token.");
      }
      const user = isRecord(poll.user) ? poll.user : {};
      await saveAuthConfig(opts.homeDir ?? os.homedir(), { origin, token });
      return {
        loggedIn: true,
        origin,
        ...(typeof user.email === "string" ? { email: user.email } : {}),
        ...(typeof user.id === "string" ? { userId: user.id } : {}),
      };
    }
    throw cliError("cloud.invalid_response", "Recappi device auth returned an unknown status.");
  }

  throw cliError("auth.unauthorized", "Recappi CLI sign-in timed out.", {
    hint: "Run recappi auth login again.",
  });
}

async function startDeviceAuth(
  origin: string,
  fetchImpl: typeof fetch,
): Promise<{
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  verificationUriComplete: string;
  expiresIn: number;
  interval: number;
}> {
  const response = await fetchImpl(new URL("/api/device-auth/start", origin), {
    method: "POST",
  });
  if (!response.ok) {
    throw cliError(
      "cloud.http_error",
      `Could not start Recappi device sign-in (${response.status}).`,
      {
        retryable: response.status >= 500,
      },
    );
  }
  const body = (await response.json()) as DeviceStartResponse;
  const deviceCode = stringField(body.device_code, "device_code");
  const userCode = stringField(body.user_code, "user_code");
  const verificationUri = stringField(body.verification_uri, "verification_uri");
  const verificationUriComplete = stringField(
    body.verification_uri_complete,
    "verification_uri_complete",
  );
  const expiresIn = numberField(body.expires_in, "expires_in");
  const interval = numberField(body.interval, "interval");
  return { deviceCode, userCode, verificationUri, verificationUriComplete, expiresIn, interval };
}

async function pollDeviceAuth(
  origin: string,
  deviceCode: string,
  fetchImpl: typeof fetch,
): Promise<DevicePollResponse> {
  const response = await fetchImpl(new URL("/api/device-auth/poll", origin), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ device_code: deviceCode }),
  });
  if (!response.ok) {
    throw cliError("cloud.http_error", `Recappi device sign-in poll failed (${response.status}).`, {
      retryable: response.status >= 500,
    });
  }
  return (await response.json()) as DevicePollResponse;
}

async function openUrlWithSystemBrowser(url: string): Promise<void> {
  if (process.platform === "darwin") {
    await execFileAsync("/usr/bin/open", [url]);
    return;
  }
  if (process.platform === "win32") {
    await execFileAsync("cmd", ["/c", "start", "", url]);
    return;
  }
  await execFileAsync("xdg-open", [url]);
}

function stringField(value: unknown, name: string): string {
  if (typeof value === "string" && value.length > 0) return value;
  throw cliError("cloud.invalid_response", `Recappi device auth response is missing ${name}.`);
}

function numberField(value: unknown, name: string): number {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) return value;
  throw cliError("cloud.invalid_response", `Recappi device auth response is missing ${name}.`);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
