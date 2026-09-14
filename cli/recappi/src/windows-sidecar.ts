import { createInterface } from "node:readline";
import { WindowsRecorder } from "./windowsRecorder";
import { loadWindowsCaptureBackend } from "./windowsCapture";

// The CLI owns Ctrl+C and sends recording.stop before closing our stdin.
process.on("SIGINT", () => {});
const send = (message: unknown) => process.stdout.write(`${JSON.stringify(message)}\n`);
const recorder = new WindowsRecorder({
  root: process.env.RECAPPI_RECORDINGS_DIR,
  loadBackend: async () => loadWindowsCaptureBackend(),
  emit: (event) => send({ jsonrpc: "2.0", method: "recappi.event", params: event }),
});

// Serialize requests so a stop cannot overtake an asynchronous handshake.
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
try {
  for await (const line of lines) {
    let request: unknown;
    try {
      request = JSON.parse(line);
    } catch {
      send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Invalid JSON." } });
      continue;
    }
    send(await recorder.handle(request));
  }
} finally {
  await recorder.shutdown();
}
