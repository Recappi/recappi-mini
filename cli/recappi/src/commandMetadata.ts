export interface CommandExampleDoc {
  description: string;
  command: string;
}

export interface CommandMetadata {
  capabilities: string[];
  examples: CommandExampleDoc[];
  relatedCommands?: string[];
}

export interface CommonTaskDoc {
  label: string;
  command: string;
}

export const COMMON_TASKS: CommonTaskDoc[] = [
  { label: "Record audio + live captions", command: "recappi record --live" },
  { label: "Transcribe a local file", command: "recappi upload <file> --transcribe --wait" },
  { label: "Re-transcribe a recording", command: "recappi recordings retranscribe <recordingId> --wait" },
  { label: "List / find recordings", command: "recappi recordings list" },
  { label: "Read a transcript", command: "recappi transcript get <transcriptId>" },
  { label: "Download / open audio", command: "recappi audio <recordingId> --open" },
  { label: "Check a transcription job", command: "recappi jobs wait <jobId>" },
  { label: "Account · quota · usage", command: "recappi account status" },
  { label: "Sign in", command: "recappi auth login" },
  { label: "Diagnose auth / audio setup", command: "recappi doctor" },
];

export const COMMAND_METADATA: Record<string, CommandMetadata> = {
  "auth import-macos": {
    capabilities: ["Reuse the macOS app's signed-in session for the CLI"],
    examples: [
      { description: "Copy the macOS app session into CLI config", command: "recappi auth import-macos" },
    ],
    relatedCommands: ["auth login", "auth status"],
  },
  "auth login": {
    capabilities: ["Authenticate the CLI via device-code OAuth"],
    examples: [
      { description: "Start device-code sign-in", command: "recappi auth login" },
      { description: "Print the login URL without opening a browser", command: "recappi auth login --no-open" },
    ],
    relatedCommands: ["auth status", "auth import-macos"],
  },
  "auth logout": {
    capabilities: ["Sign the CLI out and clear stored token"],
    examples: [{ description: "Remove the local CLI token", command: "recappi auth logout" }],
    relatedCommands: ["auth status", "auth login"],
  },
  "auth status": {
    capabilities: ["Check whether the CLI is signed in, and as whom"],
    examples: [{ description: "Show sign-in status", command: "recappi auth status" }],
    relatedCommands: ["auth login", "doctor"],
  },
  "account status": {
    capabilities: ["Show account plan, minutes/storage quota, and usage"],
    examples: [{ description: "Show account, quota, and local state", command: "recappi account status" }],
    relatedCommands: ["auth status", "dashboard stats"],
  },
  doctor: {
    capabilities: ["Diagnose auth, cloud connectivity, local audio/TCC permissions"],
    examples: [{ description: "Check setup health", command: "recappi doctor" }],
    relatedCommands: ["auth status", "record"],
  },
  upload: {
    capabilities: [
      "Upload a local audio file",
      "Batch-upload every supported audio file in a directory (recursive)",
      "Transcribe uploaded audio",
      "Wait for transcription to finish",
    ],
    examples: [
      {
        description: "Upload a local audio file and wait for transcription",
        command: "recappi upload talk.m4a --transcribe --wait",
      },
      {
        description: "Recursively upload + transcribe every audio file in a folder",
        command: "recappi upload ./recordings --transcribe",
      },
      {
        description: "Transcribe with title and language hints",
        command: 'recappi upload talk.m4a --transcribe --language en --title "Team sync"',
      },
    ],
    relatedCommands: ["jobs wait", "recordings list", "transcript get"],
  },
  record: {
    capabilities: [
      "Record system audio and/or mic",
      "Live captions while recording",
      "Auto upload+transcribe+summarize on stop",
    ],
    examples: [
      { description: "Record with live captions", command: "recappi record --live" },
      { description: "Record a microphone-only voice note", command: 'recappi record --no-system-audio --title "Voice note"' },
      { description: "Record with live caption translation", command: "recappi record --live --translation-language en" },
    ],
    relatedCommands: ["recordings list", "transcript get"],
  },
  audio: {
    capabilities: ["Download audio", "Open in default player", "Reveal in Finder"],
    examples: [
      { description: "Download and open audio", command: "recappi audio <recordingId> --open" },
      { description: "Download audio and print the local path", command: "recappi audio <recordingId> --download" },
      { description: "Reveal downloaded audio in Finder", command: "recappi audio <recordingId> --reveal" },
    ],
    relatedCommands: ["recordings list", "recordings get"],
  },
  schema: {
    capabilities: ["Print the full machine-readable CLI contract for agents"],
    examples: [
      { description: "Read the full machine-readable command contract", command: "recappi schema --json --compact" },
    ],
  },
  "dashboard stats": {
    capabilities: ["Fetch aggregate dashboard counters/stats"],
    examples: [{ description: "Fetch dashboard counters", command: "recappi dashboard stats --json --compact" }],
    relatedCommands: ["account status", "recordings list"],
  },
  "recordings get": {
    capabilities: ["Fetch one recording's metadata and status by id"],
    examples: [{ description: "Fetch one recording", command: "recappi recordings get <recordingId>" }],
    relatedCommands: ["recordings list", "transcript get", "audio"],
  },
  "recordings list": {
    capabilities: ["List recent recordings", "Search recordings and transcripts", "Find a recordingId"],
    examples: [
      { description: "List recent recordings", command: "recappi recordings list" },
      { description: "Search recordings and transcripts", command: "recappi recordings list --search <query>" },
    ],
    relatedCommands: ["recordings get", "audio", "transcript get"],
  },
  "recordings retranscribe": {
    capabilities: ["Re-transcribe an existing recording", "Re-transcribe with new language/prompt/scene/model"],
    examples: [
      {
        description: "Start a fresh transcription for an existing cloud recording",
        command: "recappi recordings retranscribe <recordingId> --wait",
      },
      {
        description: "Re-transcribe with language and prompt hints",
        command: 'recappi recordings retranscribe <recordingId> --language en --prompt "medical terms" --wait',
      },
    ],
    relatedCommands: ["jobs wait", "transcript get"],
  },
  "transcript get": {
    capabilities: ["Fetch a finished transcript by id"],
    examples: [{ description: "Fetch an existing transcript", command: "recappi transcript get <transcriptId>" }],
    relatedCommands: ["recordings get", "jobs wait"],
  },
  "jobs list": {
    capabilities: ["List transcription jobs", "Filter by status"],
    examples: [
      { description: "List active transcription jobs", command: "recappi jobs list --status active" },
      { description: "List recent jobs across statuses", command: "recappi jobs list --status all --limit 20" },
    ],
    relatedCommands: ["jobs wait", "recordings retranscribe"],
  },
  "jobs wait": {
    capabilities: ["Block until a transcription job reaches a terminal state"],
    examples: [
      { description: "Wait for a transcription job", command: "recappi jobs wait <jobId>" },
    ],
    relatedCommands: ["jobs list", "transcript get"],
  },
};

export function commonTasksHelpText(): string {
  return [
    "Common tasks:",
    ...COMMON_TASKS.map((task) => `  ${task.label.padEnd(30)} ${task.command}`),
  ].join("\n");
}

export function commandMetadataHelpText(commandName: string): string {
  const metadata = COMMAND_METADATA[commandName];
  if (!metadata) return "";
  const lines: string[] = [];
  if (metadata.examples.length > 0) {
    lines.push("Examples:");
    for (const example of metadata.examples) {
      lines.push(`  ${example.command}`);
      lines.push(`    ${example.description}`);
    }
  }
  if (metadata.relatedCommands && metadata.relatedCommands.length > 0) {
    lines.push("Related:");
    lines.push(`  ${metadata.relatedCommands.join(" · ")}`);
  }
  return lines.length > 0 ? `\n${lines.join("\n")}\n` : "";
}
