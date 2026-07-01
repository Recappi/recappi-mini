import type { Command } from "commander/esm.mjs";
import {
  CLI_SCHEMA_VERSION,
  accountStatusDataSchema,
  audioCommandDataSchema,
  authImportDataSchema,
  authLoginDataSchema,
  authLogoutDataSchema,
  authStatusDataSchema,
  cliEnvelopeSchema,
  doctorDataSchema,
  dashboardStatsDataSchema,
  jobDataSchema,
  jobListDataSchema,
  operationEventSchema,
  recordCommandDataSchema,
  recordingDataSchema,
  recordingListDataSchema,
  recordingTranscribeDataSchema,
  toJsonSchema,
  transcriptDataSchema,
  uploadBatchDataSchema,
  type ContractSchema,
} from "../../packages/contracts/src/index";
import { allErrorCodeDescriptors } from "./errors";

// Per-command result `data` shapes, keyed by the full command path. Keying by
// name (not by registering schemas on the commander tree) keeps this map the one
// place that maps a command to its output contract, and lets `schema` pick up a
// command's data automatically once it is registered in cli.ts — so a command
// whose HTTP core lands later (e.g. `transcript get`) starts advertising its
// shape the moment it appears in the program, with no extra wiring here.
const COMMAND_DATA_SCHEMAS: Record<string, ContractSchema> = {
  "auth login": authLoginDataSchema,
  "auth logout": authLogoutDataSchema,
  "auth import-macos": authImportDataSchema,
  "auth status": authStatusDataSchema,
  "account status": accountStatusDataSchema,
  audio: audioCommandDataSchema,
  doctor: doctorDataSchema,
  "dashboard stats": dashboardStatsDataSchema,
  upload: uploadBatchDataSchema,
  record: recordCommandDataSchema,
  "recordings get": recordingDataSchema,
  "recordings list": recordingListDataSchema,
  "recordings retranscribe": recordingTranscribeDataSchema,
  "jobs list": jobListDataSchema,
  "jobs wait": jobDataSchema,
  "transcript get": transcriptDataSchema,
};

// Common options are added to every command level; documenting them once at the
// top of the schema keeps each command entry focused on its own flags.
const COMMON_OPTION_LONGS = new Set([
  "--json",
  "--jsonl",
  "--human",
  "--fields",
  "--compact",
  "--origin",
]);

const EXIT_CODE_LEGEND: Record<string, string> = {
  "0": "success",
  "1": "internal error",
  "2": "usage error",
  "3": "not logged in",
  "4": "input error",
  "5": "cloud error",
};

interface CommandArgumentDoc {
  name: string;
  required: boolean;
  description?: string;
}

interface CommandOptionDoc {
  flags: string;
  description: string;
}

interface CommandDoc {
  name: string;
  summary: string;
  arguments: CommandArgumentDoc[];
  options: CommandOptionDoc[];
  data?: unknown;
}

export interface SchemaDocument {
  schemaVersion: string;
  commands: CommandDoc[];
  commonOptions: CommandOptionDoc[];
  errorCodes: ReturnType<typeof allErrorCodeDescriptors>;
  exitCodes: Record<string, string>;
  envelope: unknown;
  event: unknown;
}

// Builds the full machine-readable contract for `recappi schema`: the runnable
// command surface (walked from the live commander program so it can never drift
// from what actually parses), the common options, the error-code catalogue, and
// JSON Schemas for the envelope and the JSONL event stream. zod v4 ships native
// JSON Schema export, so this needs no third-party converter.
export function buildSchemaDocument(program: Command): SchemaDocument {
  const commands: CommandDoc[] = [];
  walkCommands(program, [], commands);
  commands.sort((a, b) => a.name.localeCompare(b.name));

  return {
    schemaVersion: CLI_SCHEMA_VERSION,
    commands,
    commonOptions: commonOptionDocs(program),
    errorCodes: allErrorCodeDescriptors(),
    exitCodes: EXIT_CODE_LEGEND,
    envelope: toJsonSchema(cliEnvelopeSchema),
    event: toJsonSchema(operationEventSchema),
  };
}

function walkCommands(command: Command, path: string[], out: CommandDoc[]): void {
  for (const sub of subcommandsOf(command)) {
    const name = sub.name();
    if (name === "help") continue;
    const fullPath = [...path, name];
    const children = subcommandsOf(sub).filter((child) => child.name() !== "help");
    if (children.length === 0) {
      // A leaf command is the only thing an agent can actually run; group
      // commands (auth, jobs) exist only to namespace their children.
      out.push(leafCommandDoc(sub, fullPath.join(" ")));
    }
    walkCommands(sub, fullPath, out);
  }
}

function leafCommandDoc(command: Command, fullName: string): CommandDoc {
  const dataSchema = COMMAND_DATA_SCHEMAS[fullName];
  return {
    name: fullName,
    summary: command.description(),
    arguments: argumentDocs(command),
    options: optionDocs(command).filter((opt) => !isCommonOption(opt)),
    ...(dataSchema ? { data: toJsonSchema(dataSchema) } : {}),
  };
}

function commonOptionDocs(program: Command): CommandOptionDoc[] {
  return optionDocs(program).filter(isCommonOption);
}

function subcommandsOf(command: Command): Command[] {
  // `commands` is the public array of registered subcommands in commander.
  return (command.commands ?? []) as Command[];
}

function argumentDocs(command: Command): CommandArgumentDoc[] {
  const args = (command as unknown as { registeredArguments?: RegisteredArgument[] })
    .registeredArguments;
  if (!Array.isArray(args)) return [];
  return args.map((arg) => ({
    name: arg.name(),
    required: arg.required === true,
    ...(arg.description ? { description: arg.description } : {}),
  }));
}

function optionDocs(command: Command): CommandOptionDoc[] {
  const options = (command as unknown as { options?: RegisteredOption[] }).options;
  if (!Array.isArray(options)) return [];
  return options.map((opt) => ({ flags: opt.flags, description: opt.description ?? "" }));
}

function isCommonOption(opt: CommandOptionDoc): boolean {
  const long = opt.flags.split(/[ ,]+/).find((token) => token.startsWith("--"));
  return long ? COMMON_OPTION_LONGS.has(long) : false;
}

interface RegisteredArgument {
  name(): string;
  required?: boolean;
  description?: string;
}

interface RegisteredOption {
  flags: string;
  description?: string;
}
