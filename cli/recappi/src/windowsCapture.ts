import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import type { WindowsCapture, WindowsCaptureBackend } from "./windowsRecorder";

export function loadWindowsCaptureBackend(): WindowsCaptureBackend {
  if (process.platform !== "win32") throw new Error("Windows capture requires Windows.");
  const packageName = `recappi-helper-win32-${process.arch}`;
  let executable: string;
  try {
    executable = join(
      dirname(createRequire(import.meta.url).resolve(`${packageName}/package.json`)),
      "RecappiAudioCapture.exe",
    );
  } catch {
    executable = fileURLToPath(
      new URL(`../../helpers/win32-${process.arch}/RecappiAudioCapture.exe`, import.meta.url),
    );
  }
  if (!existsSync(executable)) throw new Error("Windows recording helper is missing.");
  return {
    start: (callback, options) =>
      new Promise<WindowsCapture>((resolve, reject) => {
        const args = [
          ...(!options.includeSystemAudio ? ["--no-system-audio"] : []),
          ...(!options.includeMicrophone ? ["--no-microphone"] : []),
        ];
        const child = spawn(executable, args, {
          stdio: ["pipe", "pipe", "pipe"],
          windowsHide: true,
        });
        let ready = false;
        let stopping = false;
        let failed = false;
        const exited = new Promise<void>((done) => child.once("close", () => done()));
        const fail = (error: Error) => {
          if (failed) return;
          failed = true;
          clearTimeout(timer);
          if (ready) callback(error, new Float32Array());
          else reject(error);
          child.stdin.end();
          child.kill();
        };
        const timer = setTimeout(
          () => fail(new Error("Windows audio device initialization timed out.")),
          8000,
        );
        child.once("error", fail);
        child.stdin.on("error", fail);
        child.stderr.resume();
        const lines = createInterface({ input: child.stdout });
        lines.on("line", (line) => {
          try {
            const message = JSON.parse(line);
            if (message.type === "error") {
              fail(new Error(message.message));
              return;
            }
            if (message.type === "ready" && !ready) {
              ready = true;
              clearTimeout(timer);
              resolve({
                sampleRate: message.sampleRate,
                channels: message.channels,
                stop: async () => {
                  stopping = true;
                  child.stdin.end();
                  const killTimer = setTimeout(() => child.kill(), 2000);
                  try {
                    await exited;
                    if (child.exitCode !== 0)
                      throw new Error(
                        "Windows audio capture did not stop cleanly. The partial WAV has been retained.",
                      );
                  } finally {
                    clearTimeout(killTimer);
                  }
                },
              });
            } else if (message.type === "audio" && ready && !failed) {
              const bytes = Buffer.from(message.samples, "base64");
              if (bytes.length % 4) throw new Error("Invalid Windows PCM frame.");
              const samples = new Float32Array(bytes.length / 4);
              for (let i = 0; i < samples.length; i++) samples[i] = bytes.readFloatLE(i * 4);
              callback(null, samples);
            }
          } catch (error) {
            fail(error instanceof Error ? error : new Error("Invalid Windows capture output."));
          }
        });
        child.once("close", (code) => {
          clearTimeout(timer);
          if (!stopping && !failed)
            fail(new Error(`Windows audio capture exited unexpectedly (${code}).`));
        });
      }),
  };
}
