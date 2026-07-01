import { promises as fs } from "node:fs";
import path from "node:path";
import { normalizeAudioType, type SupportedAudioType } from "../../packages/contracts/src/index";
import { cliError } from "./errors";
import { parseWavHeader } from "./wav";

export interface AudioFilePlan {
  filePath: string;
  title: string;
  contentType: SupportedAudioType;
  durationMs?: number;
  sizeBytes: number;
}

const EXT_TO_CONTENT_TYPE: Record<string, SupportedAudioType> = {
  ".wav": "audio/wav",
  ".mp3": "audio/mp3",
  ".aiff": "audio/aiff",
  ".aif": "audio/aiff",
  ".aac": "audio/aac",
  ".m4a": "audio/aac",
  ".ogg": "audio/ogg",
  ".flac": "audio/flac",
};

export function contentTypeForPath(filePath: string): SupportedAudioType | null {
  const fromExtension = EXT_TO_CONTENT_TYPE[path.extname(filePath).toLowerCase()];
  return fromExtension ? normalizeAudioType(fromExtension) : null;
}

export async function planAudioFile(
  filePath: string,
  titleOverride?: string,
): Promise<AudioFilePlan> {
  let stat;
  try {
    stat = await fs.stat(filePath);
  } catch (error) {
    if (isNodeErrorCode(error, "ENOENT") || isNodeErrorCode(error, "ENOTDIR")) {
      throw cliError("input.not_found", `Path not found: ${filePath}`);
    }
    if (isNodeErrorCode(error, "EACCES") || isNodeErrorCode(error, "EPERM")) {
      throw cliError("input.permission_denied", `Permission denied reading path: ${filePath}`, {
        hint: "Grant this terminal/agent access to the file, or copy the audio to a readable location.",
      });
    }
    throw cliError(
      "internal.unexpected",
      error instanceof Error ? error.message : `Could not inspect path: ${filePath}`,
    );
  }
  if (!stat.isFile()) {
    throw cliError("input.not_file", `Path is not a file: ${filePath}`, {
      hint: "Pass one or more audio files explicitly. For a folder, expand a shell glob such as recappi upload ./recordings/*.m4a.",
    });
  }
  const contentType = contentTypeForPath(filePath);
  if (!contentType) {
    throw cliError("input.unsupported_audio", `Unsupported audio file: ${filePath}`, {
      hint: "Supported extensions: wav, mp3, aiff, aac, m4a, ogg, flac.",
    });
  }
  const title = titleOverride ?? path.basename(filePath, path.extname(filePath));
  const durationMs = await readDurationMs(filePath, contentType);
  return {
    filePath,
    title,
    contentType,
    sizeBytes: stat.size,
    ...(durationMs ? { durationMs } : {}),
  };
}

function isNodeErrorCode(error: unknown, code: string): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === code;
}

async function readDurationMs(
  filePath: string,
  contentType: SupportedAudioType,
): Promise<number | undefined> {
  if (contentType === "audio/wav") {
    const handle = await fs.open(filePath, "r");
    try {
      const buffer = Buffer.alloc(4096);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      return parseWavHeader(buffer.subarray(0, bytesRead)).durationMs;
    } finally {
      await handle.close();
    }
  }
  try {
    const { parseFile } = await import("music-metadata");
    const metadata = await parseFile(filePath, { duration: true });
    if (typeof metadata.format.duration === "number" && Number.isFinite(metadata.format.duration)) {
      return Math.max(1, Math.round(metadata.format.duration * 1000));
    }
  } catch {
    throw cliError(
      "input.duration_unavailable",
      `Could not read duration for non-WAV file: ${filePath}`,
      {
        hint: "Pass a WAV file, or use an audio file with readable duration metadata.",
      },
    );
  }
  throw cliError(
    "input.duration_unavailable",
    `Could not read duration for non-WAV file: ${filePath}`,
    {
      hint: "Pass a WAV file, or use an audio file with readable duration metadata.",
    },
  );
}
