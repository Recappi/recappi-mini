import {
  cliErrorCodeSchema,
  type CliErrorCode,
  type CliErrorDescriptor,
} from "../../packages/contracts/src/index";

const DEFAULT_EXIT_CODES: Record<CliErrorCode, number> = {
  "usage.invalid_argument": 2,
  "usage.missing_command": 2,
  "auth.not_logged_in": 3,
  "auth.unauthorized": 3,
  "input.not_found": 4,
  "input.permission_denied": 4,
  "input.not_file": 4,
  "input.unsupported_audio": 4,
  "input.duration_unavailable": 4,
  "input.partial_failure": 1, // always overridden with the worst per-file exit code
  "record.helper_unavailable": 2,
  "record.unsupported_platform": 2,
  "record.capture_unavailable": 2,
  "record.permission_required": 2,
  "record.capture_failed": 1,
  "cloud.conflict.upload_in_progress": 5,
  "cloud.recording_not_ready": 5,
  "cloud.job_failed": 5,
  "cloud.job_timed_out": 5,
  "cloud.http_error": 5,
  "cloud.invalid_response": 5,
  "internal.unexpected": 1,
};

const RETRYABLE_DEFAULTS: Partial<Record<CliErrorCode, boolean>> = {
  "cloud.conflict.upload_in_progress": true,
  "cloud.http_error": true,
  "cloud.job_timed_out": true,
};

export class RecappiCliError extends Error {
  readonly descriptor: CliErrorDescriptor;
  readonly data?: unknown;

  constructor(descriptor: CliErrorDescriptor, data?: unknown) {
    super(descriptor.message);
    this.name = "RecappiCliError";
    this.descriptor = descriptor;
    this.data = data;
  }
}

export function describeError(
  code: CliErrorCode,
  message: string,
  opts: { hint?: string; retryable?: boolean; exitCode?: number } = {},
): CliErrorDescriptor {
  return {
    code,
    exitCode: opts.exitCode ?? DEFAULT_EXIT_CODES[code],
    retryable: opts.retryable ?? RETRYABLE_DEFAULTS[code] ?? false,
    message,
    ...(opts.hint ? { hint: opts.hint } : {}),
  };
}

export function cliError(
  code: CliErrorCode,
  message: string,
  opts: { hint?: string; retryable?: boolean; exitCode?: number; data?: unknown } = {},
): RecappiCliError {
  return new RecappiCliError(describeError(code, message, opts), opts.data);
}

export function toCliError(error: unknown): RecappiCliError {
  if (error instanceof RecappiCliError) return error;
  if (error instanceof Error) {
    return cliError("internal.unexpected", error.message || "Unexpected error.");
  }
  return cliError("internal.unexpected", String(error));
}

export interface ErrorCodeDescriptor {
  code: CliErrorCode;
  // null when the exit code is computed at runtime rather than fixed.
  exitCode: number | null;
  retryable: boolean;
  note?: string;
}

// Static, machine-readable catalogue of every error code the CLI can emit, used
// by `recappi schema` so an agent can learn exit codes and retryability without
// triggering each failure. Sourced from the same tables describeError() uses, so
// the catalogue never drifts from real behaviour.
export function allErrorCodeDescriptors(): ErrorCodeDescriptor[] {
  return cliErrorCodeSchema.options.map((code) => {
    if (code === "input.partial_failure") {
      // exitCode is overridden per call with the worst per-file exit code, so a
      // fixed number here would lie. Surface that it is dynamic instead.
      return {
        code,
        exitCode: null,
        retryable: false,
        note: "exitCode is the worst per-file failure exit code; inspect data.failures[].error.",
      };
    }
    return {
      code,
      exitCode: DEFAULT_EXIT_CODES[code],
      retryable: RETRYABLE_DEFAULTS[code] ?? false,
    };
  });
}

export function describeHttpError(status: number, message: string): CliErrorDescriptor {
  if (status === 401 || status === 403) {
    return describeError("auth.unauthorized", message || "Recappi authentication failed.", {
      hint: "Run recappi auth status, or sign in to Recappi Mini and retry.",
    });
  }
  if (status === 409 && /upload is already in progress/i.test(message)) {
    return describeError(
      "cloud.conflict.upload_in_progress",
      message || "An upload is already in progress.",
      { retryable: true },
    );
  }
  if (status === 404 && /transcript not found/i.test(message)) {
    return describeError("cloud.recording_not_ready", message || "Transcript is not ready.", {
      retryable: true,
      hint: "Wait for the transcription job to succeed, then retry transcript get.",
    });
  }
  if (status === 409 && /not ready|uploading state/i.test(message)) {
    return describeError("cloud.recording_not_ready", message || "Recording is not ready.", {
      retryable: true,
    });
  }
  return describeError("cloud.http_error", message || `Recappi Cloud request failed (${status}).`, {
    retryable: status >= 500,
  });
}
