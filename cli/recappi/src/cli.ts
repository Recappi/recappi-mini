import { Command, CommanderError, InvalidArgumentError } from "commander/esm.mjs";
import os from "node:os";
import {
  recordCommandDataSchema,
  type JobStatusFilter,
  type OperationEvent,
  type RecordCommandData,
} from "../../packages/contracts/src/index";
import { cliError, RecappiCliError, toCliError } from "./errors";
import {
  clearAuthConfig,
  inspectMacOSAppKeychain,
  requireToken,
  resolveAuthContext,
  saveAuthConfig,
} from "./auth";
import { loginWithDeviceCode } from "./auth-login";
import { RecappiApiClient } from "./api";
import { createRecordingAudioRuntime } from "./audio";
import { commandMetadataHelpText, commonTasksHelpText } from "./commandMetadata";
import {
  createHumanProgressState,
  renderEvent,
  renderFailure,
  renderSuccess,
  type OutputMode,
} from "./render";
import { buildSchemaDocument, type SchemaDocument } from "./schema";
import { CLI_VERSION } from "./version";
import type { RunDashboardDeps } from "./tui";
import type { TabKey } from "./tui/chrome";
import {
  listRecordInputs,
  recordViaSidecar,
  startLiveRecordSession,
  startRecordSetupLevelPreview,
  type RecordRuntimeDeps,
} from "./record";
import { recordingArtifactFromRecordData } from "./recordingCore";

const DASHBOARD_RECORDINGS_PAGE_SIZE = 50;

interface RecordCloudHandoffOptions {
  title?: string;
  language?: string;
  onEvent?: (event: OperationEvent) => void;
}

async function uploadRecordedSessionAfterStop(
  client: RecappiApiClient,
  data: RecordCommandData,
  opts: RecordCloudHandoffOptions = {},
): Promise<RecordCommandData> {
  const artifact = recordingArtifactFromRecordData(data);
  if (!artifact.audioPath) return data;

  try {
    const upload = await client.uploadPathBatch({
      inputPath: artifact.audioPath,
      transcribe: true,
      wait: false,
      ...(opts.title ? { title: opts.title } : {}),
      ...(opts.language ? { language: opts.language } : {}),
      onEvent: opts.onEvent,
    });
    if (upload.failures.length > 0) {
      const failure = upload.failures[0]!;
      return recordCommandDataSchema.parse({
        ...data,
        cloudHandoffError: failure.error,
      });
    }
    const success = upload.successes[0];
    if (!success) {
      return recordCommandDataSchema.parse({
        ...data,
        cloudHandoffError: cliError(
          "input.unsupported_audio",
          "No supported local audio file was uploaded.",
        ).descriptor,
      });
    }

    return recordCommandDataSchema.parse({
      ...data,
      recordingId: success.recordingId,
      ...(success.jobId ? { jobId: success.jobId } : {}),
      ...(success.transcriptId ? { transcriptId: success.transcriptId } : {}),
    });
  } catch (error) {
    return recordCommandDataSchema.parse({
      ...data,
      cloudHandoffError: toCliError(error).descriptor,
    });
  }
}

export interface CliDeps {
  argv?: string[];
  env?: NodeJS.ProcessEnv;
  stdout?: (text: string) => void;
  stderr?: (text: string) => void;
  isTTY?: boolean;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  homeDir?: string;
  openUrl?: (url: string) => Promise<void>;
  runDashboard?: (deps: RunDashboardDeps) => Promise<void>;
  recordRuntime?: RecordRuntimeDeps;
}

interface GlobalOptions {
  mode?: OutputMode;
  fields?: string[];
  compact?: boolean;
  origin?: string;
}

export async function runCli(deps: CliDeps = {}): Promise<number> {
  const argv = deps.argv ?? process.argv.slice(2);
  const stdout = deps.stdout ?? ((text) => process.stdout.write(text));
  const stderr = deps.stderr ?? ((text) => process.stderr.write(text));
  const isTTY = deps.isTTY ?? Boolean(process.stdout.isTTY);
  let parsed: ParsedCommand | null = null;

  try {
    parsed = parseArgv(argv, isTTY);
    if (parsed.kind === "help") {
      stdout(parsed.helpText);
      return 0;
    }
    const mode = parsed.options.mode ?? (isTTY ? "human" : "json");
    const render = {
      mode,
      compact: parsed.options.compact,
      fields: parsed.options.fields,
      stdout,
      stderr,
      progress: createHumanProgressState(mode === "human" && isTTY),
    };
    if (parsed.kind === "schema") {
      // Offline, auth-free: an agent must be able to discover the contract
      // before it has a token, so this returns before resolveAuthContext.
      renderSuccess("schema", parsed.document, render);
      return 0;
    }
    if (parsed.kind === "version") {
      renderSuccess("version", { version: CLI_VERSION }, render);
      return 0;
    }
    const auth = await resolveAuthContext({
      origin: parsed.options.origin,
      env: deps.env,
      homeDir: deps.homeDir,
    });
    const client = new RecappiApiClient(auth, {
      fetchImpl: deps.fetchImpl,
      sleep: deps.sleep,
      env: deps.env,
      homeDir: deps.homeDir,
    });

    if (parsed.kind === "dashboard") {
      const status = await client.authStatus();
      const account =
        status.loggedIn && status.userId
          ? { backendOrigin: auth.origin, userId: status.userId }
          : null;
      const recordingAudio = createRecordingAudioRuntime(client, {
        account,
        env: deps.env,
        homeDir: deps.homeDir,
      });
      const runDashboard = deps.runDashboard ?? (await import("./tui")).runDashboard;
      await runDashboard({
        fetchJobs: () => client.listJobs({ status: "active", limit: 20 }),
        fetchRecordings: ({ cursor, limit = DASHBOARD_RECORDINGS_PAGE_SIZE } = {}) =>
          client.listRecordings({ limit, cursor }),
        fetchDashboardStats: () => client.dashboardStats(),
        fetchAccountStatus: () => client.accountStatus(),
        fetchTranscript: (transcriptId) => client.getTranscript(transcriptId),
        recordingAudio,
        listDownloadedRecordingIds: () => recordingAudio.listDownloadedRecordingIds(),
        listDownloads: () => recordingAudio.listDownloads(),
        fetchRecordSetup: async () =>
          listRecordInputs({
            cliVersion: CLI_VERSION,
            env: deps.env,
            runtime: deps.recordRuntime,
          }),
        startLiveRecord: async (selection, sources) => {
          const liveStatus = await client.authStatus();
          if (!liveStatus.loggedIn || !liveStatus.userId) {
            throw cliError("auth.not_logged_in", "Sign in before starting a sidecar recording.", {
              hint: "Run recappi auth login, or import the Recappi Mini session with recappi auth import-macos.",
            });
          }
          return startLiveRecordSession(
            {
              account: {
                backendOrigin: auth.origin,
                userId: liveStatus.userId,
                authToken: requireToken(auth),
                ...(liveStatus.email ? { email: liveStatus.email } : {}),
              },
              cliVersion: CLI_VERSION,
              env: deps.env,
              homeDir: deps.homeDir,
              runtime: deps.recordRuntime,
            },
            selection,
            sources,
          );
        },
        startRecordSetupPreview: async (selection, sources) =>
          startRecordSetupLevelPreview(
            {
              cliVersion: CLI_VERSION,
              env: deps.env,
              runtime: deps.recordRuntime,
            },
            selection,
            sources,
          ),
        transcribeRecordingArtifact: async (artifact, onEvent) => {
          if (!artifact.audioPath) {
            throw cliError("input.not_found", "No local audio file is available to transcribe.");
          }
          const data = await client.uploadPathBatch({
            inputPath: artifact.audioPath,
            transcribe: true,
            wait: false,
            onEvent,
          });
          if (data.failures.length > 0) {
            const failure = data.failures[0]!;
            throw cliError(failure.error.code, failure.error.message, {
              hint: failure.error.hint,
              retryable: failure.error.retryable,
            });
          }
          const success = data.successes[0];
          if (!success) {
            throw cliError("input.unsupported_audio", "No supported local audio file was uploaded.");
          }
          return success;
        },
        retranscribeRecording: (recordingId, options = {}) =>
          client.transcribeRecording({ recordingId, ...options }),
        initialView: parsed.initialView,
      });
      return 0;
    }
    if (parsed.kind === "auth-status") {
      const data = await client.authStatus();
      renderSuccess("auth status", data, render);
      return data.loggedIn ? 0 : 3;
    }
    if (parsed.kind === "account-status") {
      const data = await client.accountStatus();
      renderSuccess("account status", data, render);
      return data.loggedIn ? 0 : 3;
    }
    if (parsed.kind === "auth-login") {
      const data = await loginWithDeviceCode({
        origin: auth.origin,
        homeDir: deps.homeDir,
        noOpen: parsed.noOpen,
        onPrompt: (message) => stderr(message),
        deps: {
          fetchImpl: deps.fetchImpl,
          openUrl: deps.openUrl,
          sleep: deps.sleep,
        },
      });
      renderSuccess("auth login", data, render);
      return 0;
    }
    if (parsed.kind === "auth-logout") {
      const cleared = await clearAuthConfig(deps.homeDir ?? os.homedir());
      renderSuccess("auth logout", { loggedIn: false, origin: auth.origin, cleared }, render);
      return 0;
    }
    if (parsed.kind === "auth-import-macos") {
      const keychain = await inspectMacOSAppKeychain({ env: deps.env });
      if (!keychain.token) {
        throw cliError("auth.not_logged_in", keychain.message, {
          hint: keychain.hint ?? "Run recappi auth login instead.",
        });
      }
      await saveAuthConfig(deps.homeDir ?? os.homedir(), {
        origin: auth.origin,
        token: keychain.token,
      });
      renderSuccess(
        "auth import-macos",
        { imported: true, origin: auth.origin, source: "macos-keychain" },
        render,
      );
      return 0;
    }
    if (parsed.kind === "doctor") {
      const data = await client.doctor();
      renderSuccess("doctor", data, render);
      if (data.status !== "error") return 0;
      return data.checks.some((check) => check.name.startsWith("auth.")) ? 3 : 1;
    }
    if (parsed.kind === "upload") {
      const data = await client.uploadPathBatch({
        inputPath: parsed.path,
        title: parsed.title,
        transcribe: parsed.transcribe,
        wait: parsed.wait,
        language: parsed.language,
        provider: parsed.provider,
        prompt: parsed.prompt,
        force: parsed.force,
        onEvent: (event) => renderEvent(event, render),
      });
      if (data.failures.length > 0) {
        // Batch-level partial failure: the per-file failures keep their real
        // codes in data.failures[].error. The top-level code must NOT pretend
        // to be one specific category (e.g. cloud.http_error) — failures may be
        // input errors. Use input.partial_failure with retryable:false so an
        // agent inspects per-file retryability instead of blanket-retrying.
        const worst = data.failures.reduce((max, item) => Math.max(max, item.error.exitCode), 1);
        const descriptor = {
          code: "input.partial_failure" as const,
          exitCode: worst,
          retryable: false,
          message: `${data.failures.length} of ${data.totalCount} upload(s) failed.`,
          hint: "Inspect data.failures[].error for per-file codes; retry only the failed files.",
        };
        renderFailure("upload", descriptor, render, data);
        return worst;
      }
      renderSuccess("upload", data, render);
      return 0;
    }
    if (parsed.kind === "record") {
      const status = await client.authStatus();
      if (!status.loggedIn || !status.userId) {
        throw cliError("auth.not_logged_in", "Sign in before starting a sidecar recording.", {
          hint: "Run recappi auth login, or import the Recappi Mini session with recappi auth import-macos.",
        });
      }
      const translationLanguage =
        parsed.translationLanguage ?? (mode === "human" && isTTY ? "zh" : undefined);
      const captured = await recordViaSidecar({
        account: {
          backendOrigin: auth.origin,
          userId: status.userId,
          authToken: requireToken(auth),
          ...(status.email ? { email: status.email } : {}),
        },
        cliVersion: CLI_VERSION,
        env: deps.env,
        homeDir: deps.homeDir,
        title: parsed.title,
        live: parsed.live === true || (mode === "human" && isTTY),
        includeSystemAudio: parsed.includeSystemAudio,
        includeMicrophone: parsed.includeMicrophone,
        translationLanguage,
        transcriptionLanguage: parsed.transcriptionLanguage,
        sidecarCommand: parsed.sidecarCommand,
        renderLive: parsed.live === true && mode === "human" && isTTY,
        renderHero: parsed.live !== true && mode === "human" && isTTY,
        requireLiveCaptions: parsed.live === true,
        runtime: deps.recordRuntime,
      });
      const data = await uploadRecordedSessionAfterStop(client, captured, {
        title: parsed.title,
        language: parsed.transcriptionLanguage,
        onEvent: (event) => renderEvent(event, render),
      });
      renderSuccess("record", data, render);
      return 0;
    }
    if (parsed.kind === "audio") {
      const status = await client.authStatus();
      if (!status.loggedIn || !status.userId) {
        throw cliError("auth.not_logged_in", "Sign in before using local audio actions.", {
          hint: "Run recappi auth login, or import the Recappi Mini session with recappi auth import-macos.",
        });
      }
      const recordingAudio = createRecordingAudioRuntime(client, {
        account: { backendOrigin: auth.origin, userId: status.userId },
        env: deps.env,
        homeDir: deps.homeDir,
      });
      const download = await recordingAudio.downloadRecordingAudioFile(
        parsed.recordingId,
        parsed.outputDir ? { directory: parsed.outputDir } : undefined,
      );
      if (parsed.action === "open") {
        await recordingAudio.openPath(download.localPath);
      } else if (parsed.action === "reveal") {
        await recordingAudio.revealInFinder(download.localPath);
      }
      renderSuccess(
        "audio",
        {
          origin: auth.origin,
          recordingId: parsed.recordingId,
          localPath: download.localPath,
          action: parsed.action,
          reused: download.reused,
          ...(download.artifactId !== undefined ? { artifactId: download.artifactId } : {}),
          ...(download.contentType ? { contentType: download.contentType } : {}),
          ...(download.contentLength !== undefined
            ? { contentLength: download.contentLength }
            : {}),
        },
        render,
      );
      return 0;
    }
    if (parsed.kind === "jobs-wait") {
      const parsedOptions = parsed.options;
      const data = await client.waitForJob(parsed.jobId, {
        onEvent: (event) =>
          renderEvent(event, {
            ...render,
            mode: parsedOptions.mode === "jsonl" ? "jsonl" : "human",
          }),
      });
      renderSuccess("jobs wait", data, render);
      return 0;
    }
    if (parsed.kind === "jobs-list") {
      const data = await client.listJobs({ status: parsed.status, limit: parsed.limit });
      renderSuccess("jobs list", data, render);
      return 0;
    }
    if (parsed.kind === "recordings-list") {
      const data = await client.listRecordings({
        limit: parsed.limit,
        cursor: parsed.cursor,
        search: parsed.search,
      });
      renderSuccess("recordings list", data, render);
      return 0;
    }
    if (parsed.kind === "recordings-get") {
      const data = await client.getRecording(parsed.recordingId);
      renderSuccess("recordings get", data, render);
      return 0;
    }
    if (parsed.kind === "recordings-retranscribe") {
      const eventMode: OutputMode = parsed.options.mode === "jsonl" ? "jsonl" : "human";
      const data = await client.transcribeRecording({
        recordingId: parsed.recordingId,
        language: parsed.language,
        provider: parsed.provider,
        model: parsed.model,
        prompt: parsed.prompt,
        scene: parsed.scene,
        wait: parsed.wait,
        onEvent:
          parsed.wait || mode === "jsonl"
            ? (event) =>
                renderEvent(event, {
                  ...render,
                  mode: eventMode,
                })
            : undefined,
      });
      renderSuccess("recordings retranscribe", data, render);
      return 0;
    }
    if (parsed.kind === "dashboard-stats") {
      const data = await client.dashboardStats();
      renderSuccess("dashboard stats", data, render);
      return 0;
    }
    if (parsed.kind === "transcript-get") {
      const data = await client.getTranscript(parsed.transcriptId);
      renderSuccess("transcript get", data, render);
      return 0;
    }
    throw cliError("usage.invalid_argument", "Unknown command.");
  } catch (error) {
    const cli = normalizeTopLevelError(error);
    const mode = parsed?.options.mode ?? explicitMode(argv) ?? (isTTY ? "human" : "json");
    renderFailure(
      parsed?.commandName ?? "recappi",
      cli.descriptor,
      {
        mode,
        compact: parsed?.options.compact,
        fields: undefined,
        stdout,
        stderr,
      },
      cli.data,
    );
    return cli.descriptor.exitCode;
  }
}

type ParsedCommand =
  | { kind: "help"; options: GlobalOptions; commandName: "recappi"; helpText: string }
  | { kind: "dashboard"; options: GlobalOptions; commandName: "dashboard"; initialView: TabKey }
  | { kind: "auth-login"; options: GlobalOptions; commandName: "auth login"; noOpen?: boolean }
  | { kind: "auth-logout"; options: GlobalOptions; commandName: "auth logout" }
  | { kind: "auth-import-macos"; options: GlobalOptions; commandName: "auth import-macos" }
  | { kind: "auth-status"; options: GlobalOptions; commandName: "auth status" }
  | { kind: "account-status"; options: GlobalOptions; commandName: "account status" }
  | {
      kind: "upload";
      options: GlobalOptions;
      commandName: "upload";
      path: string;
      title?: string;
      transcribe?: boolean;
      wait?: boolean;
      language?: string;
      provider?: string;
      prompt?: string;
      force?: boolean;
    }
  | {
      kind: "record";
      options: GlobalOptions;
      commandName: "record";
      title?: string;
      live?: boolean;
      includeSystemAudio?: boolean;
      includeMicrophone?: boolean;
      translationLanguage?: string;
      transcriptionLanguage?: string;
      sidecarCommand?: string;
    }
  | {
      kind: "audio";
      options: GlobalOptions;
      commandName: "audio";
      recordingId: string;
      action: AudioAction;
      outputDir?: string;
    }
  | { kind: "jobs-wait"; options: GlobalOptions; commandName: "jobs wait"; jobId: string }
  | {
      kind: "jobs-list";
      options: GlobalOptions;
      commandName: "jobs list";
      status: JobStatusFilter;
      limit: number;
    }
  | {
      kind: "recordings-list";
      options: GlobalOptions;
      commandName: "recordings list";
      limit: number;
      cursor?: string;
      search?: string;
    }
  | {
      kind: "recordings-get";
      options: GlobalOptions;
      commandName: "recordings get";
      recordingId: string;
    }
  | {
      kind: "recordings-retranscribe";
      options: GlobalOptions;
      commandName: "recordings retranscribe";
      recordingId: string;
      language?: string;
      provider?: string;
      model?: string;
      prompt?: string;
      scene?: string;
      wait?: boolean;
    }
  | { kind: "dashboard-stats"; options: GlobalOptions; commandName: "dashboard stats" }
  | {
      kind: "schema";
      options: GlobalOptions;
      commandName: "schema";
      document: SchemaDocument;
    }
  | { kind: "version"; options: GlobalOptions; commandName: "version" }
  | { kind: "doctor"; options: GlobalOptions; commandName: "doctor" }
  | {
      kind: "transcript-get";
      options: GlobalOptions;
      commandName: "transcript get";
      transcriptId: string;
    };

function parseArgv(argv: string[], isTTY: boolean): ParsedCommand {
  let selected: ParsedCommand | null = null;
  let helpText = "";
  const program = buildProgram({
    onHelpOutput: (text) => {
      helpText += text;
    },
    onSelect: (command) => {
      selected = command;
    },
  });

  try {
    program.parse(argv, { from: "user" });
  } catch (error) {
    if (error instanceof CommanderError) {
      if (error.exitCode === 0 && isCommanderHelp(error)) {
        return {
          kind: "help",
          options: { mode: isTTY ? "human" : "json" },
          commandName: "recappi",
          helpText: helpText || program.helpInformation(),
        };
      }
      if (isCommanderAutoHelp(error) && !hasCommandToken(argv)) {
        if (program.opts<RootCommanderOptions>().version) {
          return {
            kind: "version",
            options: collectGlobalOptions(program),
            commandName: "version",
          };
        }
        const dashboard = dashboardCommand(program, argv, isTTY);
        if (dashboard) return dashboard;
        if (explicitMode(argv)) {
          throw cliError("usage.missing_command", "Missing command.", {
            hint: "Run recappi --help for available commands.",
          });
        }
        return {
          kind: "help",
          options: { mode: isTTY ? "human" : "json" },
          commandName: "recappi",
          helpText: helpText || program.helpInformation(),
        };
      }
      const dashboard = dashboardCommand(program, argv, isTTY);
      if (isCommanderAutoHelp(error) && dashboard) return dashboard;
      if (isCommanderAutoHelp(error) && isTTY && !explicitMode(argv) && helpText) {
        return {
          kind: "help",
          options: { mode: "human" },
          commandName: "recappi",
          helpText,
        };
      }
      throw commanderToCliError(error);
    }
    throw error;
  }

  if (!selected) {
    if (program.opts<RootCommanderOptions>().version) {
      return { kind: "version", options: collectGlobalOptions(program), commandName: "version" };
    }
    const dashboard = dashboardCommand(program, argv, isTTY);
    if (dashboard) return dashboard;
    if (explicitMode(argv)) {
      throw cliError("usage.missing_command", "Missing command.", {
        hint: "Run recappi --help for available commands.",
      });
    }
    return {
      kind: "help",
      options: { mode: isTTY ? "human" : "json" },
      commandName: "recappi",
      helpText: helpText || program.helpInformation(),
    };
  }
  return selected;
}

function setMode(options: GlobalOptions, mode: OutputMode): void {
  if (options.mode && options.mode !== mode) {
    throw cliError("usage.invalid_argument", "Choose only one output mode.");
  }
  options.mode = mode;
}

function explicitMode(argv: string[]): OutputMode | undefined {
  if (argv.includes("--jsonl")) return "jsonl";
  if (argv.includes("--json")) return "json";
  if (argv.includes("--human")) return "human";
  return undefined;
}

function shouldRunDashboard(argv: string[], isTTY: boolean): boolean {
  if (!isTTY || argv.includes("--json") || argv.includes("--jsonl")) return false;
  const commands = commandTokens(argv);
  return commands.length === 0 || (commands.length === 1 && commands[0] === "jobs");
}

function dashboardCommand(
  program: Command,
  argv: string[],
  isTTY: boolean,
): Extract<ParsedCommand, { kind: "dashboard" }> | null {
  if (!shouldRunDashboard(argv, isTTY)) return null;
  const initialView = commandTokens(argv)[0] === "jobs" ? "jobs" : "overview";
  return {
    kind: "dashboard",
    options: dashboardOptions(program, argv),
    commandName: "dashboard",
    initialView,
  };
}

interface BuildProgramOptions {
  onHelpOutput: (text: string) => void;
  onSelect: (command: ParsedCommand) => void;
}

interface CommanderCommonOptions {
  json?: boolean;
  jsonl?: boolean;
  human?: boolean;
  compact?: boolean;
  verbose?: boolean;
  fields?: string[];
  origin?: string;
}

interface RootCommanderOptions extends CommanderCommonOptions {
  version?: boolean;
}

interface AuthLoginCommanderOptions extends CommanderCommonOptions {
  // Commander maps `--no-open` to `open: false` (defaults to true), not `noOpen`.
  open?: boolean;
}

interface UploadCommanderOptions extends CommanderCommonOptions {
  title?: string;
  transcribe?: boolean;
  wait?: boolean;
  language?: string;
  provider?: string;
  prompt?: string;
  force?: boolean;
}

interface RecordCommanderOptions extends CommanderCommonOptions {
  title?: string;
  live?: boolean;
  systemAudio?: boolean;
  microphone?: boolean;
  translationLanguage?: string;
  transcriptionLanguage?: string;
  sidecarCommand?: string;
}

type AudioAction = "download" | "open" | "reveal";

interface AudioCommanderOptions extends CommanderCommonOptions {
  download?: boolean;
  open?: boolean;
  reveal?: boolean;
  outputDir?: string;
}

interface JobsListCommanderOptions extends CommanderCommonOptions {
  status?: JobStatusFilter;
  limit?: number;
}

interface RecordingsListCommanderOptions extends CommanderCommonOptions {
  limit?: number;
  cursor?: string;
  search?: string;
}

interface RecordingsRetranscribeCommanderOptions extends CommanderCommonOptions {
  language?: string;
  provider?: string;
  model?: string;
  prompt?: string;
  scene?: string;
  wait?: boolean;
}

function buildProgram({ onHelpOutput, onSelect }: BuildProgramOptions): Command {
  const program = new Command("recappi");
  program
    .description("Recappi Cloud command line interface")
    .option("-v, --version", "show CLI version")
    .exitOverride()
    .showHelpAfterError(false)
    .showSuggestionAfterError(false)
    .configureOutput({
      writeOut: onHelpOutput,
      writeErr: onHelpOutput,
      outputError: () => {},
    })
    .addHelpText(
      "after",
      `
${commonTasksHelpText()}

Agent mode:
  Non-TTY stdout defaults to JSON. Progress and human diagnostics go to stderr.
  Use --json for a single envelope or --jsonl for a terminal event stream.
  Use recappi schema --json --compact to probe commands, capabilities, examples,
  related commands, output schemas, error codes, and JSONL events.
`,
    );
  addCommonOptions(program);

  const auth = program.command("auth").description("Sign in/out and check Recappi Cloud auth");
  addCommonOptions(auth);
  const authLogin = auth
    .command("login")
    .description("Sign in to Recappi Cloud with a device code")
    .option("--no-open", "print the device URL without opening a browser")
    .addHelpText("after", commandMetadataHelpText("auth login"));
  addCommonOptions(authLogin);
  authLogin.action((opts: AuthLoginCommanderOptions, command: Command) => {
    onSelect({
      kind: "auth-login",
      options: collectGlobalOptions(command),
      commandName: "auth login",
      ...(opts.open === false ? { noOpen: true } : {}),
    });
  });

  const authLogout = auth
    .command("logout")
    .description("Remove the Recappi CLI sign-in token")
    .addHelpText("after", commandMetadataHelpText("auth logout"));
  addCommonOptions(authLogout);
  authLogout.action((_options: CommanderCommonOptions, command: Command) => {
    onSelect({
      kind: "auth-logout",
      options: collectGlobalOptions(command),
      commandName: "auth logout",
    });
  });

  const authImportMacOS = auth
    .command("import-macos")
    .description("Copy the Recappi Mini macOS app session into CLI config")
    .addHelpText("after", commandMetadataHelpText("auth import-macos"));
  addCommonOptions(authImportMacOS);
  authImportMacOS.action((_options: CommanderCommonOptions, command: Command) => {
    onSelect({
      kind: "auth-import-macos",
      options: collectGlobalOptions(command),
      commandName: "auth import-macos",
    });
  });

  const authStatus = auth
    .command("status")
    .description("Show Recappi Cloud sign-in status")
    .addHelpText("after", commandMetadataHelpText("auth status"));
  addCommonOptions(authStatus);
  authStatus.action((_options: CommanderCommonOptions, command: Command) => {
    onSelect({
      kind: "auth-status",
      options: collectGlobalOptions(command),
      commandName: "auth status",
    });
  });

  const doctor = program
    .command("doctor")
    .description("Check Recappi auth, cloud connectivity, and local audio support")
    .addHelpText("after", commandMetadataHelpText("doctor"));
  addCommonOptions(doctor);
  doctor.action((_options: CommanderCommonOptions, command: Command) => {
    onSelect({
      kind: "doctor",
      options: collectGlobalOptions(command),
      commandName: "doctor",
    });
  });

  const account = program.command("account").description("Show account status, quota, and usage");
  addCommonOptions(account);
  const accountStatus = account
    .command("status")
    .description("Show account, quota, and local state")
    .addHelpText("after", commandMetadataHelpText("account status"));
  addCommonOptions(accountStatus);
  accountStatus.action((_options: CommanderCommonOptions, command: Command) => {
    onSelect({
      kind: "account-status",
      options: collectGlobalOptions(command),
      commandName: "account status",
    });
  });

  const upload = program
    .command("upload <file-or-dir>")
    .description("Upload a local audio file or directory (optionally transcribe)")
    .option("--title <title>", "recording title", parseStringOption("--title"))
    .option("--transcribe", "start transcription after upload")
    .option("--wait", "wait for the transcription job to reach a terminal state")
    .option("--language <lang>", "transcription language hint", parseStringOption("--language"))
    .option("--provider <name>", "transcription provider", parseStringOption("--provider"))
    .option("--prompt <text>", "transcription prompt/context", parseStringOption("--prompt"))
    .option("--force", "force upload if a conflict is retryable")
    .addHelpText("after", commandMetadataHelpText("upload"));
  addCommonOptions(upload);
  upload.action((inputPath: string, opts: UploadCommanderOptions, command: Command) => {
    onSelect({
      kind: "upload",
      options: collectGlobalOptions(command),
      commandName: "upload",
      path: inputPath,
      ...(typeof opts.title === "string" ? { title: opts.title } : {}),
      ...(opts.transcribe === true ? { transcribe: true } : {}),
      ...(opts.wait === true ? { wait: true, transcribe: true } : {}),
      ...(typeof opts.language === "string" ? { language: opts.language } : {}),
      ...(typeof opts.provider === "string" ? { provider: opts.provider } : {}),
      ...(typeof opts.prompt === "string" ? { prompt: opts.prompt } : {}),
      ...(opts.force === true ? { force: true } : {}),
    });
  });

  const record = program
    .command("record")
    .description("Record system/mic audio via the Recappi Mini sidecar")
    .option("--title <title>", "recording title", parseStringOption("--title"))
    .option("--live", "show live captions while recording")
    .option("--no-system-audio", "record microphone only")
    .option("--no-microphone", "record system audio only")
    .option(
      "--translation-language <lang>",
      "live caption translation language",
      parseStringOption("--translation-language"),
    )
    .option(
      "--transcription-language <lang>",
      "recording/transcription language hint",
      parseStringOption("--transcription-language"),
    )
    .option(
      "--sidecar-command <path>",
      "Recappi Mini sidecar executable",
      parseStringOption("--sidecar-command"),
    )
    .addHelpText("after", commandMetadataHelpText("record"));
  addCommonOptions(record);
  record.action((opts: RecordCommanderOptions, command: Command) => {
    if (opts.systemAudio === false && opts.microphone === false) {
      throw cliError("usage.invalid_argument", "Choose at least one recording input.", {
        hint: "Use system audio, microphone, or both.",
      });
    }
    onSelect({
      kind: "record",
      options: collectGlobalOptions(command),
      commandName: "record",
      ...(typeof opts.title === "string" ? { title: opts.title } : {}),
      ...(opts.live === true ? { live: true } : {}),
      ...(opts.systemAudio === false ? { includeSystemAudio: false } : {}),
      ...(opts.microphone === false ? { includeMicrophone: false } : {}),
      ...(typeof opts.translationLanguage === "string"
        ? { translationLanguage: opts.translationLanguage }
        : {}),
      ...(typeof opts.transcriptionLanguage === "string"
        ? { transcriptionLanguage: opts.transcriptionLanguage }
        : {}),
      ...(typeof opts.sidecarCommand === "string" ? { sidecarCommand: opts.sidecarCommand } : {}),
    });
  });

  const audio = program
    .command("audio")
    .description("Download, open, or reveal a recording's audio file")
    .argument("<recording-id>", "recording id")
    .option("--download", "download audio and print the local path")
    .option("--open", "download if needed, then open the audio file")
    .option("--reveal", "download if needed, then reveal the audio file in Finder")
    .option(
      "--output-dir <dir>",
      "directory for downloaded audio",
      parseStringOption("--output-dir"),
    )
    .addHelpText("after", commandMetadataHelpText("audio"));
  addCommonOptions(audio);
  audio.action((recordingId: string, opts: AudioCommanderOptions, command: Command) => {
    onSelect({
      kind: "audio",
      options: collectGlobalOptions(command),
      commandName: "audio",
      recordingId,
      action: audioAction(opts),
      ...(opts.outputDir ? { outputDir: opts.outputDir } : {}),
    });
  });

  const schema = program
    .command("schema")
    .description("Print the machine-readable CLI contract (commands, error codes, JSON Schemas)")
    .addHelpText("after", commandMetadataHelpText("schema"));
  addCommonOptions(schema);
  schema.action((_options: CommanderCommonOptions, command: Command) => {
    onSelect({
      kind: "schema",
      options: collectGlobalOptions(command),
      commandName: "schema",
      document: buildSchemaDocument(program),
    });
  });

  const dashboard = program.command("dashboard").description("Fetch dashboard counters and stats");
  addCommonOptions(dashboard);
  const dashboardStats = dashboard
    .command("stats")
    .description("Fetch dashboard counters")
    .addHelpText("after", commandMetadataHelpText("dashboard stats"));
  addCommonOptions(dashboardStats);
  dashboardStats.action((_options: CommanderCommonOptions, command: Command) => {
    onSelect({
      kind: "dashboard-stats",
      options: collectGlobalOptions(command),
      commandName: "dashboard stats",
    });
  });

  const recordings = program.command("recordings").description("List, fetch, and re-transcribe recordings");
  addCommonOptions(recordings);
  const recordingsList = recordings
    .command("list")
    .description("List recent recordings")
    .option("--limit <n>", "number of recordings to show", parseLimitOption("--limit", 1, 100), 20)
    .option("--cursor <cursor>", "pagination cursor", parseStringOption("--cursor"))
    .option("--search <query>", "search recordings and transcripts", parseStringOption("--search"))
    .addHelpText("after", commandMetadataHelpText("recordings list"));
  addCommonOptions(recordingsList);
  recordingsList.action((_options: RecordingsListCommanderOptions, command: Command) => {
    const opts = command.opts<RecordingsListCommanderOptions>();
    onSelect({
      kind: "recordings-list",
      options: collectGlobalOptions(command),
      commandName: "recordings list",
      limit: opts.limit ?? 20,
      ...(typeof opts.cursor === "string" ? { cursor: opts.cursor } : {}),
      ...(typeof opts.search === "string" ? { search: opts.search } : {}),
    });
  });

  const recordingsGet = recordings
    .command("get <recordingId>")
    .description("Fetch a recording by recording id")
    .addHelpText("after", commandMetadataHelpText("recordings get"));
  addCommonOptions(recordingsGet);
  recordingsGet.action(
    (recordingId: string, _options: CommanderCommonOptions, command: Command) => {
      onSelect({
        kind: "recordings-get",
        options: collectGlobalOptions(command),
        commandName: "recordings get",
        recordingId,
      });
    },
  );

  const recordingsRetranscribe = recordings
    .command("retranscribe <recordingId>")
    .description("Start a fresh transcription job for an existing recording")
    .option("--language <lang>", "transcription language hint", parseStringOption("--language"))
    .option("--provider <name>", "transcription provider", parseStringOption("--provider"))
    .option("--model <name>", "transcription model", parseStringOption("--model"))
    .option("--prompt <text>", "custom transcription prompt/context", parseStringOption("--prompt"))
    .option("--scene <id>", "transcription scene preset", parseStringOption("--scene"))
    .option("--wait", "wait for the transcription job to reach a terminal state")
    .addHelpText("after", commandMetadataHelpText("recordings retranscribe"));
  addCommonOptions(recordingsRetranscribe);
  recordingsRetranscribe.action(
    (recordingId: string, _options: RecordingsRetranscribeCommanderOptions, command: Command) => {
      const opts = command.opts<RecordingsRetranscribeCommanderOptions>();
      onSelect({
        kind: "recordings-retranscribe",
        options: collectGlobalOptions(command),
        commandName: "recordings retranscribe",
        recordingId,
        ...(typeof opts.language === "string" ? { language: opts.language } : {}),
        ...(typeof opts.provider === "string" ? { provider: opts.provider } : {}),
        ...(typeof opts.model === "string" ? { model: opts.model } : {}),
        ...(typeof opts.prompt === "string" ? { prompt: opts.prompt } : {}),
        ...(typeof opts.scene === "string" ? { scene: opts.scene } : {}),
        ...(opts.wait === true ? { wait: true } : {}),
      });
    },
  );

  const transcript = program
    .command("transcript")
    .description("Read transcripts (create via upload --transcribe or recordings retranscribe)")
    .addHelpText(
      "after",
      `
To create a transcript (not here):
  Local audio file          recappi upload <file> --transcribe --wait
  Existing cloud recording  recappi recordings retranscribe <recordingId> --wait
`,
    );
  addCommonOptions(transcript);
  const transcriptGet = transcript
    .command("get <transcriptId>")
    .description("Fetch a transcript by transcript id")
    .addHelpText("after", commandMetadataHelpText("transcript get"));
  addCommonOptions(transcriptGet);
  transcriptGet.action(
    (transcriptId: string, _options: CommanderCommonOptions, command: Command) => {
      onSelect({
        kind: "transcript-get",
        options: collectGlobalOptions(command),
        commandName: "transcript get",
        transcriptId,
      });
    },
  );

  const jobs = program.command("jobs").description("List transcription jobs and wait for one to finish");
  addCommonOptions(jobs);
  const jobsList = jobs
    .command("list")
    .description("List recent transcription jobs")
    .option(
      "--status <status>",
      "filter jobs: active, queued, running, succeeded, failed, all",
      parseJobStatusOption,
      "all",
    )
    .option("--limit <n>", "number of jobs to show", parseLimitOption("--limit", 1, 50), 10);
  jobsList.addHelpText("after", commandMetadataHelpText("jobs list"));
  addCommonOptions(jobsList);
  jobsList.action((_options: JobsListCommanderOptions, command: Command) => {
    const opts = command.opts<JobsListCommanderOptions>();
    onSelect({
      kind: "jobs-list",
      options: collectGlobalOptions(command),
      commandName: "jobs list",
      status: opts.status ?? "all",
      limit: opts.limit ?? 10,
    });
  });

  const jobsWait = jobs
    .command("wait <jobId>")
    .description("Wait for an existing transcription job to finish")
    .addHelpText("after", commandMetadataHelpText("jobs wait"));
  addCommonOptions(jobsWait);
  jobsWait.action((jobId: string, _options: CommanderCommonOptions, command: Command) => {
    onSelect({
      kind: "jobs-wait",
      options: collectGlobalOptions(command),
      commandName: "jobs wait",
      jobId,
    });
  });

  return program;
}

function addCommonOptions(command: Command): void {
  command
    .option("--json", "write one JSON envelope to stdout")
    .option("--jsonl", "write JSONL operation events to stdout")
    .option("--human", "write human-readable output")
    .option("--fields <list>", "comma-separated data fields to keep", parseFieldsOption)
    .option("--compact", "omit empty optional data and print compact JSON")
    .option("--verbose", "accept verbose wrappers without changing output")
    .option("--origin <url>", "Recappi Cloud origin", parseStringOption("--origin"));
}

function audioAction(opts: AudioCommanderOptions): AudioAction {
  const selected = [
    opts.download ? "download" : null,
    opts.open ? "open" : null,
    opts.reveal ? "reveal" : null,
  ].filter((action): action is AudioAction => action !== null);
  if (selected.length > 1) {
    throw cliError("usage.invalid_argument", "Choose only one of --download, --open, or --reveal.");
  }
  return selected[0] ?? "download";
}

function parseStringOption(flag: string): (value: string) => string {
  return (value: string): string => {
    if (!value || value.startsWith("-")) {
      throw new InvalidArgumentError(`Missing value for ${flag}.`);
    }
    return value;
  };
}

function parseFieldsOption(value: string): string[] {
  if (!value || value.startsWith("-")) {
    throw new InvalidArgumentError("Missing value for --fields.");
  }
  const fields = value
    .split(",")
    .map((field) => field.trim())
    .filter(Boolean);
  if (fields.length === 0) {
    throw new InvalidArgumentError("Missing value for --fields.");
  }
  return fields;
}

function parseJobStatusOption(value: string): JobStatusFilter {
  const allowed = ["active", "queued", "running", "succeeded", "failed", "all"] as const;
  if (!allowed.includes(value as JobStatusFilter)) {
    throw new InvalidArgumentError(`Invalid status '${value}'. Allowed: ${allowed.join(", ")}.`);
  }
  return value as JobStatusFilter;
}

function parseLimitOption(flag: string, min: number, max: number): (value: string) => number {
  return (value: string): number => {
    const n = Number(value);
    if (!Number.isInteger(n) || n < min || n > max) {
      throw new InvalidArgumentError(`${flag} must be an integer from ${min} to ${max}.`);
    }
    return n;
  };
}

function collectGlobalOptions(command: Command): GlobalOptions {
  const chain: Command[] = [];
  for (let current: Command | null = command; current; current = current.parent) {
    chain.unshift(current);
  }
  const options: GlobalOptions = {};
  for (const item of chain) {
    const opts = item.opts<CommanderCommonOptions>();
    if (opts.json) setMode(options, "json");
    if (opts.jsonl) setMode(options, "jsonl");
    if (opts.human) setMode(options, "human");
    if (opts.compact) options.compact = true;
    if (opts.fields) options.fields = opts.fields;
    if (typeof opts.origin === "string") options.origin = opts.origin;
  }
  return options;
}

function dashboardOptions(program: Command, argv: string[]): GlobalOptions {
  if (commandTokens(argv)[0] === "jobs") {
    const jobs = program.commands.find((command) => command.name() === "jobs");
    if (jobs) return collectGlobalOptions(jobs);
  }
  return collectGlobalOptions(program);
}

const VALUE_OPTIONS = new Set([
  "--fields",
  "--origin",
  "--title",
  "--language",
  "--provider",
  "--model",
  "--prompt",
  "--scene",
  "--translation-language",
  "--transcription-language",
  "--sidecar-command",
  "--status",
  "--limit",
  "--cursor",
  "--search",
]);

function hasCommandToken(argv: string[]): boolean {
  return commandTokens(argv).length > 0;
}

function commandTokens(argv: string[]): string[] {
  const commands: string[] = [];
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]!;
    if (token === "--") {
      commands.push(...argv.slice(index + 1));
      break;
    }
    if (!token.startsWith("-")) {
      commands.push(token);
      continue;
    }
    const [flag] = token.split("=", 1);
    if (VALUE_OPTIONS.has(flag) && !token.includes("=")) index += 1;
  }
  return commands;
}

function isCommanderHelp(error: CommanderError): boolean {
  return error.code === "commander.help" || error.code === "commander.helpDisplayed";
}

function isCommanderAutoHelp(error: CommanderError): boolean {
  return error.code === "commander.help" && error.message === "(outputHelp)";
}

function commanderToCliError(error: CommanderError): RecappiCliError {
  if (error.code === "commander.optionMissingArgument" && error.message.includes("--fields")) {
    return missingFieldsValueError();
  }
  if (
    error.code === "commander.invalidArgument" &&
    error.message.includes("Missing value for --fields.")
  ) {
    return missingFieldsValueError();
  }
  return cliError("usage.invalid_argument", cleanCommanderMessage(error.message), {
    hint: "Run recappi --help for available commands.",
  });
}

function missingFieldsValueError(): RecappiCliError {
  return cliError("usage.invalid_argument", "Missing value for --fields.", {
    hint: "Pass comma-separated fields, for example --fields recordingId,status.",
  });
}

function cleanCommanderMessage(message: string): string {
  if (message === "(outputHelp)") return "Missing or incomplete command.";
  return message.replace(/^error:\s*/i, "");
}

function normalizeTopLevelError(error: unknown): RecappiCliError {
  if (error instanceof Error && error.message.startsWith("Unknown --fields:")) {
    return cliError("usage.invalid_argument", error.message);
  }
  return toCliError(error);
}
