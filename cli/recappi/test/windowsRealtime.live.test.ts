// Opt-in production-service/hardware smoke. Only the checked-in spoken fixture
// is captured from our own player process. No recording is uploaded to the library.
// Run after building the Windows helper with RECAPPI_TEST_LIVE=1 and an existing CLI login.
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { resolveAuthContext, requireToken } from "../src/auth";
import { RecappiApiClient } from "../src/api";
import { loadWindowsCaptureBackend } from "../src/windowsCapture";
import { WindowsRecorder } from "../src/windowsRecorder";

describe.skipIf(process.platform !== "win32" || process.env.RECAPPI_TEST_LIVE !== "1")(
  "Windows realtime service smoke",
  () => {
    it.each([undefined, "zh"])(
      "captions the isolated spoken fixture (translation=%s)",
      async (translationLanguage) => {
        const auth = await resolveAuthContext();
        const status = await new RecappiApiClient(auth).authStatus();
        if (!status.userId)
          throw new Error("Log in to Recappi before running the live smoke test.");
        const account = {
          backendOrigin: auth.origin,
          userId: status.userId,
          authToken: requireToken(auth),
        };
        const player = spawn(
          "powershell.exe",
          [
            "-NoProfile",
            "-NonInteractive",
            "-File",
            fileURLToPath(new URL("../scripts/windows-tone-player.ps1", import.meta.url)),
            "-AudioPath",
            fileURLToPath(
              new URL("../../../Tests/Fixtures/Audio/automation-upload.wav", import.meta.url),
            ),
          ],
          { windowsHide: true, stdio: ["pipe", "pipe", "ignore"] },
        );
        const closed = once(player, "close");
        const output = createInterface({ input: player.stdout });
        let recordingId: string | undefined;
        const received: string[] = [];
        let resolveCaption!: () => void;
        let rejectCaption!: (error: Error) => void;
        const caption = new Promise<void>((resolve, reject) => {
          resolveCaption = resolve;
          rejectCaption = reject;
        });
        // A rejection may arrive during native startup; observe it immediately.
        void caption.catch(() => {});
        const recorder = new WindowsRecorder({
          root: mkdtempSync(join(tmpdir(), "recappi-live-smoke-")),
          loadBackend: async () => loadWindowsCaptureBackend(),
          emit: (event) => {
            if (event.type === "error" && event.retryable === false)
              rejectCaption(new Error(`${event.code}: ${event.message}`));
            if (
              event.type === "live_caption.delta" &&
              event.text.trim() &&
              event.stream === (translationLanguage ? "translation" : "source")
            ) {
              received.push(event.text);
              if (
                translationLanguage
                  ? /[\u3400-\u9fff]/.test(event.text)
                  : /mini|automation|sentence|transcription/i.test(event.text)
              )
                resolveCaption();
            }
          },
        });
        let nextId = 0;
        const request = async (method: string, params: unknown) => {
          const result = (await recorder.handle({
            jsonrpc: "2.0",
            id: ++nextId,
            method,
            params,
          })) as any;
          if (result.error) throw new Error(result.error.message);
          return result.result;
        };
        let timeout: ReturnType<typeof setTimeout> | undefined;
        try {
          const ready = await Promise.race([
            once(output, "line"),
            closed.then(() => {
              throw new Error("Fixture player exited");
            }),
          ]);
          expect(ready[0]).toBe("ready");
          await request("recappi.handshake", {
            protocolVersion: 1,
            client: { name: "live-smoke", version: "1" },
            account,
            capabilities: [],
          });
          const started = await request("recappi.recording.start", {
            account,
            options: {
              includeSystemAudio: true,
              includeMicrophone: false,
              targetProcessId: player.pid,
              liveCaptions: true,
              transcriptionLanguage: "en",
              translationLanguage,
            },
          });
          recordingId = started.sessionId;
          timeout = setTimeout(
            () =>
              rejectCaption(new Error("No recognizable live caption arrived within 25 seconds.")),
            25000,
          );
          await caption;
          expect(received.length).toBeGreaterThan(0);
          console.log(
            JSON.stringify({
              mode: translationLanguage ? "translation" : "transcription",
              text: received.at(-1),
            }),
          );
          const stopped = await request("recappi.recording.stop", { sessionId: recordingId });
          expect(stopped.state).toBe("completed");
          expect(stopped.artifacts[0].metadata.sizeBytes).toBeGreaterThan(44);
          recordingId = undefined;
        } finally {
          clearTimeout(timeout);
          try {
            await recorder.shutdown();
          } finally {
            player.stdin.end();
            const kill = setTimeout(() => player.kill(), 2000);
            await closed;
            clearTimeout(kill);
            output.close();
          }
        }
      },
      40000,
    );
  },
);
