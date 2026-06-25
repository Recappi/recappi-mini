import { execFile } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { cliError } from "./errors";

const execFileAsync = promisify(execFile);
const DEFAULT_ORIGIN = "https://recordmeet.ing";

export interface AuthContext {
  origin: string;
  token: string | null;
  source: AuthSource;
}

export type AuthSource = "env" | "config" | "macos-keychain" | "none";

export type MacOSKeychainStatus = "ok" | "missing" | "error" | "disabled" | "unsupported";

export interface MacOSKeychainInspection {
  status: MacOSKeychainStatus;
  token: string | null;
  message: string;
  hint?: string;
}

export interface ResolveAuthOptions {
  origin?: string;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  platform?: NodeJS.Platform;
  includeMacOSKeychain?: boolean;
}

export async function resolveAuthContext(opts: ResolveAuthOptions = {}): Promise<AuthContext> {
  const env = opts.env ?? process.env;
  const origin = validateOrigin(
    opts.origin ?? env.RECAPPI_ORIGIN ?? env.RECAPPI_BACKEND_ORIGIN ?? DEFAULT_ORIGIN,
  );
  const fromEnv = env.RECAPPI_AUTH_TOKEN?.trim();
  if (fromEnv) return { origin, token: fromEnv, source: "env" };

  const homeDir = opts.homeDir ?? os.homedir();
  const config = await readConfig(homeDir);
  if (config.token)
    return {
      origin: config.origin ? validateOrigin(config.origin) : origin,
      token: config.token,
      source: "config",
    };

  if (opts.includeMacOSKeychain === true) {
    const keychain = await inspectMacOSAppKeychain({
      env,
      platform: opts.platform,
    });
    if (keychain.token) return { origin, token: keychain.token, source: "macos-keychain" };
  }

  return { origin, token: null, source: "none" };
}

export function requireToken(ctx: AuthContext): string {
  if (!ctx.token) {
    throw cliError("auth.not_logged_in", "Not logged in to Recappi.", {
      hint: "Run recappi auth login, or set RECAPPI_AUTH_TOKEN for automation.",
    });
  }
  return ctx.token;
}

export function validateOrigin(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw cliError("usage.invalid_argument", "Invalid Recappi backend URL.", {
      hint: "Pass an http(s) origin, for example --origin https://recordmeet.ing.",
    });
  }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || !url.hostname) {
    throw cliError("usage.invalid_argument", "Invalid Recappi backend URL.", {
      hint: "Pass an http(s) origin, for example --origin https://recordmeet.ing.",
    });
  }
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    (url.pathname !== "/" && url.pathname !== "")
  ) {
    throw cliError("usage.invalid_argument", "Invalid Recappi backend URL.", {
      hint: "Pass only the origin, without path, query, credentials, or fragment.",
    });
  }
  return url.origin;
}

export async function saveAuthConfig(
  homeDir: string,
  config: { token: string; origin: string },
): Promise<void> {
  const target = primaryConfigPath(homeDir);
  await fs.mkdir(path.dirname(target), { recursive: true, mode: 0o700 });
  const existing = await readConfigObject(target);
  const next = {
    ...existing,
    origin: validateOrigin(config.origin),
    authToken: config.token,
  };
  const tmp = `${target}.${process.pid}.${Date.now()}.tmp`;
  await fs.writeFile(tmp, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
  await fs.rename(tmp, target);
  await fs.chmod(target, 0o600).catch(() => {});
}

export async function clearAuthConfig(homeDir: string): Promise<boolean> {
  const target = primaryConfigPath(homeDir);
  const existing = await readConfigObject(target);
  if (!("authToken" in existing)) return false;
  delete existing.authToken;
  await fs.mkdir(path.dirname(target), { recursive: true, mode: 0o700 });
  await fs.writeFile(target, `${JSON.stringify(existing, null, 2)}\n`, { mode: 0o600 });
  await fs.chmod(target, 0o600).catch(() => {});
  return true;
}

export async function inspectMacOSAppKeychain(
  opts: Pick<ResolveAuthOptions, "env" | "platform"> = {},
): Promise<MacOSKeychainInspection> {
  const env = opts.env ?? process.env;
  if (env.RECAPPI_DISABLE_KEYCHAIN_AUTH === "1") {
    return {
      status: "disabled",
      token: null,
      message: "macOS app keychain lookup is disabled by RECAPPI_DISABLE_KEYCHAIN_AUTH=1.",
    };
  }
  const platform = opts.platform ?? process.platform;
  if (platform !== "darwin") {
    return {
      status: "unsupported",
      token: null,
      message: "macOS app keychain lookup is only available on macOS.",
    };
  }
  return readMacOSAppToken();
}

export function primaryConfigPath(homeDir: string): string {
  return path.join(homeDir, ".config", "recappi", "config.json");
}

async function readConfig(homeDir: string): Promise<{ token?: string; origin?: string }> {
  const candidates = [primaryConfigPath(homeDir), path.join(homeDir, ".recappi", "config.json")];
  for (const candidate of candidates) {
    try {
      const parsed = await readConfigObject(candidate);
      const token = typeof parsed.authToken === "string" ? parsed.authToken.trim() : undefined;
      const origin = typeof parsed.origin === "string" ? parsed.origin.trim() : undefined;
      if (token || origin) return { ...(token ? { token } : {}), ...(origin ? { origin } : {}) };
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== "ENOENT") {
        throw cliError("usage.invalid_argument", `Could not read Recappi config: ${candidate}`, {
          hint: "Ensure the file is valid JSON or use RECAPPI_AUTH_TOKEN.",
        });
      }
    }
  }
  return {};
}

async function readConfigObject(candidate: string): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(await fs.readFile(candidate, "utf8")) as Record<string, unknown>;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw error;
  }
}

async function readMacOSAppToken(): Promise<MacOSKeychainInspection> {
  try {
    const { stdout } = await execFileAsync(
      "/usr/bin/security",
      ["find-generic-password", "-s", "com.recappi.mini", "-a", "recappi.auth-token", "-w"],
      { timeout: 2000, maxBuffer: 1024 * 1024 },
    );
    const token = stdout.trim();
    if (token.length > 0) {
      return {
        status: "ok",
        token,
        message: "Found a Recappi Mini app token in the macOS keychain.",
      };
    }
    return {
      status: "missing",
      token: null,
      message: "Recappi Mini app keychain item was present but empty.",
    };
  } catch (error) {
    const err = error as NodeJS.ErrnoException & { killed?: boolean; signal?: string };
    const timedOut = err.killed || err.signal === "SIGTERM";
    const stderr = typeof err.message === "string" ? err.message : "";
    if (!timedOut && /could not be found|The specified item could not be found/i.test(stderr)) {
      return {
        status: "missing",
        token: null,
        message: "No Recappi Mini app token was found in the macOS keychain.",
      };
    }
    return {
      status: "error",
      token: null,
      message: timedOut
        ? "Timed out while reading the Recappi Mini app keychain token."
        : "Could not read the Recappi Mini app keychain token.",
      hint: "Use recappi auth login for the CLI, or run recappi auth import-macos explicitly if you want to import the app session.",
    };
  }
}
