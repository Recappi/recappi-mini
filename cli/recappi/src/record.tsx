import React from "react";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { render, useInput, type Instance, type RenderOptions as InkRenderOptions } from "ink";
import {
  recordCommandDataSchema,
  type RecordCommandData,
  type SidecarCapability,
  type SidecarAccount,
  type SidecarHandshakeResult,
  type SidecarLocalArtifact,
  type SidecarMicrophoneDevice,
  type SidecarRecordingSource,
  type SidecarPermissionItem,
  type SidecarRecordingState,
} from "../../packages/contracts/src/index";
import { cliError } from "./errors";
import {
  DEFAULT_RECORDING_SOURCES,
  recordingCaptureMappingFromSelection,
  type RecordingMicrophoneDevice,
  type RecordingInputSelection,
  type RecordingSource,
} from "./recordingCore";
import {
  defaultSidecarHandshakeParams,
  spawnMiniSidecar,
  type SpawnedMiniSidecar,
} from "./sidecar";
import { openCliStore, requireAccountPartition } from "./store";
import { LiveCaptionsScreen, type LiveCaptionEventSource } from "./tui/LiveCaptionsScreen";

const SIDECAR_COMMAND_ENV = "RECAPPI_MINI_SIDECAR";
const SIDECAR_HELPER_NAME = "RecappiMiniSidecar";
const SIDECAR_APP_BUNDLE_NAME = "Recappi Recorder.app";
const requireFromCli = createRequire(import.meta.url);

export interface RecordCommandOptions {
  account: SidecarAccount;
  cliVersion: string;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  title?: string;
  live?: boolean;
  includeSystemAudio?: boolean;
  includeMicrophone?: boolean;
  targetBundleId?: string;
  microphoneDeviceId?: string;
  translationLanguage?: string;
  transcriptionLanguage?: string;
  sidecarCommand?: string;
  sidecarArgs?: string[];
  renderLive?: boolean;
  runtime?: RecordRuntimeDeps;
}

export interface RecordRuntimeDeps {
  spawnSidecar?: (opts: {
    command: string;
    args?: string[];
    env?: NodeJS.ProcessEnv;
  }) => SpawnedMiniSidecar;
  createLiveRenderer?: (source: LiveCaptionEventSource) => RecordLiveRenderer;
  waitForStop?: () => Promise<void>;
  now?: () => number;
  renderApp?: LiveRendererRenderApp;
}

export interface RecordLiveRenderer {
  waitUntilStop: () => Promise<void>;
  close: () => void;
}

export interface LiveRecordSession {
  mode?: "local" | "live_captions";
  source: LiveCaptionEventSource;
  stop: () => Promise<RecordCommandData>;
}

export interface RecordInputOptions {
  cliVersion: string;
  env?: NodeJS.ProcessEnv;
  sidecarCommand?: string;
  sidecarArgs?: string[];
  runtime?: Pick<RecordRuntimeDeps, "spawnSidecar">;
}

export interface RecordInputModel {
  sources: RecordingSource[];
  microphones: RecordingMicrophoneDevice[];
}

type LiveRendererRenderApp = (
  node: React.ReactNode,
  options?: InkRenderOptions,
) => Pick<Instance, "unmount">;

export async function recordViaSidecar(opts: RecordCommandOptions): Promise<RecordCommandData> {
  let liveRenderer: RecordLiveRenderer | undefined;
  let session: ActiveRecordSession | undefined;
  try {
    session = await startRecordSession(opts);
    if (opts.renderLive) {
      liveRenderer =
        opts.runtime?.createLiveRenderer?.(session.source) ??
        createInkLiveRenderer({
          source: session.source,
          renderApp: opts.runtime?.renderApp,
          now: opts.runtime?.now,
        });
    }

    if (liveRenderer) {
      await liveRenderer.waitUntilStop();
    } else {
      await (opts.runtime?.waitForStop ?? waitForStopSignal)();
    }

    return await session.stop();
  } catch (error) {
    if (session) {
      try {
        await session.cancel();
      } catch {
        /* best-effort cleanup */
      }
    }
    throw error;
  } finally {
    liveRenderer?.close();
    session?.close();
  }
}

export async function startLiveRecordSession(
  opts: Omit<RecordCommandOptions, "live" | "renderLive">,
  selection: RecordingInputSelection = {
    sourceId: DEFAULT_RECORDING_SOURCES[0]!.id,
    includeMicrophone: true,
  },
  sources: RecordingSource[] = DEFAULT_RECORDING_SOURCES,
): Promise<LiveRecordSession> {
  const capture = recordingCaptureMappingFromSelection(selection, sources);
  const session = await startRecordSession({
    ...opts,
    includeSystemAudio: capture.includeSystemAudio,
    includeMicrophone: capture.includeMicrophone,
    targetBundleId: capture.targetBundleId,
    microphoneDeviceId: capture.microphoneDeviceId,
    live: false,
  });
  return {
    mode: "local",
    source: session.source,
    stop: session.stop,
  };
}

export async function listRecordInputs(opts: RecordInputOptions): Promise<RecordInputModel> {
  const command = resolveSidecarCommand(opts);
  const sidecarArgs = opts.sidecarArgs ?? [];
  const spawnSidecar = opts.runtime?.spawnSidecar ?? spawnMiniSidecar;
  const sidecar = spawnSidecar({ command, args: sidecarArgs, env: opts.env });
  try {
    await sidecar.client.handshake(
      defaultSidecarHandshakeParams({
        client: { name: "recappi-cli", version: opts.cliVersion },
        capabilities: ["recording.capture"],
      }),
    );
    const [sourceResult, microphoneResult] = await Promise.all([
      sidecar.client.listRecordingSources(),
      sidecar.client.listMicrophones(),
    ]);
    const sources = normalizeSidecarSources(sourceResult.sources);
    const microphones = normalizeSidecarMicrophones(microphoneResult.microphones);
    return {
      sources: sources.length > 0 ? sources : DEFAULT_RECORDING_SOURCES,
      microphones,
    };
  } finally {
    sidecar.kill();
  }
}

interface ActiveRecordSession {
  source: LiveCaptionEventSource;
  stop: () => Promise<RecordCommandData>;
  cancel: () => Promise<void>;
  close: () => void;
}

async function startRecordSession(opts: RecordCommandOptions): Promise<ActiveRecordSession> {
  let retriedAfterMicrophoneGrant = false;
  while (true) {
    try {
      return await startRecordSessionOnce(opts);
    } catch (error) {
      if (
        !retriedAfterMicrophoneGrant &&
        isPermissionRestartRequiredError(error, "microphone")
      ) {
        retriedAfterMicrophoneGrant = true;
        continue;
      }
      throw error;
    }
  }
}

async function startRecordSessionOnce(opts: RecordCommandOptions): Promise<ActiveRecordSession> {
  const command = resolveSidecarCommand(opts);
  const sidecarArgs = opts.sidecarArgs ?? [];
  const spawnSidecar = opts.runtime?.spawnSidecar ?? spawnMiniSidecar;
  const sidecar = spawnSidecar({ command, args: sidecarArgs, env: opts.env });
  const account = requireAccountPartition(opts.account);
  const artifacts: SidecarLocalArtifact[] = [];
  let handshake: SidecarHandshakeResult | undefined;
  let sessionId: string | undefined;
  let latestState: SidecarRecordingState | undefined;
  let recordingId: string | undefined;
  let localSessionRef: string | undefined;
  let stopPromise: Promise<RecordCommandData> | undefined;
  let closed = false;

  const unsubscribe = sidecar.client.onEvent((event) => {
    if (event.type === "recording.state") {
      latestState = event.state;
      if (event.recordingId) recordingId = event.recordingId;
      if (event.localSessionRef) localSessionRef = event.localSessionRef;
    }
    if (event.type === "local_artifact.upserted") {
      artifacts.push(event.artifact);
    }
  });
  const close = () => {
    if (closed) return;
    closed = true;
    unsubscribe();
    sidecar.kill();
  };
  const cancel = async () => {
    if (sessionId && latestState && latestState !== "completed" && latestState !== "cancelled") {
      try {
        await sidecar.client.cancelRecording({ sessionId });
      } catch {
        /* best-effort cleanup */
      }
    }
    close();
  };

  try {
    handshake = await sidecar.client.handshake(
      defaultSidecarHandshakeParams({
        client: { name: "recappi-cli", version: opts.cliVersion },
        account: opts.account,
        capabilities: opts.live
          ? ["recording.capture", "recording.upload", "live_captions.stream"]
          : ["recording.capture", "recording.upload"],
      }),
    );
    assertSidecarCapabilities(handshake, opts);

    const recordingOptions = {
      includeSystemAudio: opts.includeSystemAudio ?? true,
      includeMicrophone: opts.includeMicrophone ?? true,
      ...(opts.targetBundleId ? { targetBundleId: opts.targetBundleId } : {}),
      ...(opts.microphoneDeviceId ? { microphoneDeviceId: opts.microphoneDeviceId } : {}),
      liveCaptions: opts.live === true,
      ...(opts.translationLanguage ? { translationLanguage: opts.translationLanguage } : {}),
      ...(opts.transcriptionLanguage ? { transcriptionLanguage: opts.transcriptionLanguage } : {}),
      ...(opts.title ? { title: opts.title } : {}),
    };
    const preflight = await sidecar.client.getPermissionStatus({ options: recordingOptions });
    assertRecordingPermissions(preflight.permissions);

    const started = await sidecar.client.startRecording({
      account,
      options: recordingOptions,
    });
    sessionId = started.sessionId;
    latestState = started.state;
    localSessionRef = started.localSessionRef;

    return {
      source: sidecar.client,
      stop: () => {
        stopPromise ??= (async () => {
          try {
            const stopped = await sidecar.client.stopRecording({ sessionId: sessionId! });
            latestState = stopped.state;
            recordingId = stopped.recordingId ?? recordingId;
            localSessionRef = stopped.localSessionRef ?? localSessionRef;
            artifacts.push(...(stopped.artifacts ?? []));

            const uniqueArtifacts = dedupeArtifacts(artifacts);
            persistArtifacts(uniqueArtifacts, account, opts);
            return recordCommandDataSchema.parse({
              origin: account.backendOrigin,
              userId: account.userId,
              live: opts.live === true,
              sessionId: stopped.sessionId,
              state: stopped.state,
              ...(recordingId ? { recordingId } : {}),
              ...(localSessionRef ? { localSessionRef } : {}),
              ...(handshake?.sidecar ? { sidecar: handshake.sidecar } : {}),
              artifacts: uniqueArtifacts,
            });
          } finally {
            close();
          }
        })();
        return stopPromise;
      },
      cancel,
      close,
    };
  } catch (error) {
    await cancel();
    throw error;
  }
}

function isPermissionRestartRequiredError(
  error: unknown,
  permissionName: "microphone" | "screen_recording",
): boolean {
  const root = isRecord(error) ? error : undefined;
  const descriptor = isRecord(root?.descriptor) ? root.descriptor : undefined;
  if (descriptor?.code !== "record.permission_required") return false;

  const sidecarError = isRecord(root?.data) ? root.data : undefined;
  const sidecarData = isRecord(sidecarError?.data) ? sidecarError.data : undefined;
  return (
    sidecarData?.permission === permissionName &&
    (sidecarData.requiresProcessRestart === true ||
      sidecarData.requiresProcessRestart === "true")
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeSidecarSources(sources: SidecarRecordingSource[]): RecordingSource[] {
  const seen = new Set<string>();
  const out: RecordingSource[] = [];
  for (const source of sources) {
    const id =
      source.kind === "app" && source.bundleId ? `app:${source.bundleId}` : source.id || source.kind;
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push({
      id,
      kind: source.kind,
      label: source.label,
      ...(source.appName ? { appName: source.appName } : {}),
      ...(source.bundleId ? { bundleId: source.bundleId } : {}),
      canIncludeMicrophone: true,
    });
  }
  return out;
}

function normalizeSidecarMicrophones(
  microphones: SidecarMicrophoneDevice[],
): RecordingMicrophoneDevice[] {
  return microphones
    .filter((device) => device.id && device.label)
    .map((device) => ({
      id: device.id,
      label: device.label,
      ...(device.isDefault === true ? { isDefault: true } : {}),
    }));
}

function assertRecordingPermissions(permissions: SidecarPermissionItem[]): void {
  const blocked = permissions.find((permission) => {
    if (permission.status === "granted") return false;
    // Microphone "unknown" means macOS has not shown the native prompt yet.
    // Let recording.start reach AVCaptureDevice.requestAccess instead of
    // dead-ending the user in System Settings with no prompt/row to approve.
    if (permission.name === "microphone" && permission.status === "unknown") return false;
    // ScreenCaptureKit can be more authoritative than CGPreflightScreenCaptureAccess
    // for this helper; let capture startup verify screen/system-audio access.
    if (permission.name === "screen_recording" && permission.status === "unknown") return false;
    return true;
  });
  if (!blocked) return;
  const label =
    blocked.name === "microphone"
      ? "Microphone"
      : blocked.name === "screen_recording"
        ? "Screen Recording"
        : "Recording";
  throw cliError("record.permission_required", `${label} permission is required before recording.`, {
    hint: blocked.hint,
    data: {
      code: -32020,
      message: `${label} permission is required before recording.`,
      data: {
        cliCode: "record.permission_required",
        permission: blocked.name,
        ...(blocked.requiresProcessRestart
          ? { requiresProcessRestart: blocked.requiresProcessRestart }
          : {}),
        ...(blocked.hint ? { recovery: blocked.hint } : {}),
        permissions,
      },
    },
  });
}

function assertSidecarCapabilities(
  handshake: SidecarHandshakeResult,
  opts: Pick<RecordCommandOptions, "live">,
): void {
  const capabilities = new Set<SidecarCapability>(handshake.capabilities);
  const missing: SidecarCapability[] = [];
  if (!capabilities.has("recording.capture")) missing.push("recording.capture");
  if (opts.live && !capabilities.has("live_captions.stream")) {
    missing.push("live_captions.stream");
  }
  if (missing.length === 0) return;

  throw cliError("record.capture_unavailable", "Recappi recording helper does not support capture.", {
    hint: `Found ${handshake.sidecar.name} ${handshake.sidecar.version}, but it did not advertise ${missing.join(
      ", ",
    )}. Upgrade recappi, or set ${SIDECAR_COMMAND_ENV} to a compatible helper.`,
  });
}

function resolveSidecarCommand(
  opts: Pick<RecordCommandOptions, "sidecarCommand" | "env" | "homeDir">,
): string {
  const command = opts.sidecarCommand?.trim() || opts.env?.[SIDECAR_COMMAND_ENV]?.trim();
  if (command) return command;

  const bundled = bundledSidecarCommand(process.platform, process.arch);
  if (bundled && existsSync(bundled)) return ensureBundledHelperExecutable(bundled, opts);

  const platform = `${process.platform}-${process.arch}`;
  if (bundled) {
    throw cliError("record.helper_unavailable", "Recappi recording helper is not available.", {
      hint: `Expected bundled helper for ${platform} at ${bundled}. Reinstall recappi, or set ${SIDECAR_COMMAND_ENV} to a compatible helper.`,
    });
  }
  throw cliError("record.unsupported_platform", "Recappi recording is not supported on this platform yet.", {
    hint: `No bundled helper is registered for ${platform}. Set ${SIDECAR_COMMAND_ENV} to a compatible helper when one is available.`,
  });
}

export function ensureBundledHelperExecutable(
  path: string,
  opts: Pick<RecordCommandOptions, "env" | "homeDir"> = {},
): string {
  if (process.platform === "darwin" && path.endsWith(".app")) {
    const stableApp = ensureStableDarwinHelperApp(path, opts);
    const executable = darwinAppExecutablePath(stableApp);
    if (!existsSync(executable)) {
      throw cliError("record.helper_unavailable", "Recappi recording helper is not available.", {
        hint: `Expected bundled helper executable inside ${stableApp}. Reinstall recappi, or set ${SIDECAR_COMMAND_ENV} to a compatible helper.`,
      });
    }
    ensureExecutableMode(executable);
    return stableApp;
  }
  if (process.platform === "win32") return path;
  ensureExecutableMode(path);
  return path;
}

function ensureExecutableMode(path: string): void {
  const mode = statSync(path).mode;
  if ((mode & 0o111) !== 0) return;
  try {
    chmodSync(path, mode | 0o755);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw cliError("record.helper_unavailable", "Recappi recording helper is not executable.", {
      hint: `Could not make bundled helper executable at ${path}: ${message}. Reinstall recappi, or set ${SIDECAR_COMMAND_ENV} to a compatible helper.`,
    });
  }
}

function ensureStableDarwinHelperApp(
  sourceApp: string,
  opts: Pick<RecordCommandOptions, "env" | "homeDir"> = {},
): string {
  const targetApp = stableDarwinHelperAppPath(opts);
  const markerPath = join(dirname(targetApp), ".recappi-helper-source");
  const signature = helperSourceSignature(sourceApp);
  const currentSignature = readTextIfExists(markerPath);

  if (existsSync(darwinAppExecutablePath(targetApp)) && currentSignature === signature) {
    return targetApp;
  }

  const tempApp = `${targetApp}.tmp-${process.pid}-${Date.now()}`;
  try {
    mkdirSync(dirname(targetApp), { recursive: true });
    rmSync(tempApp, { recursive: true, force: true });
    cpSync(sourceApp, tempApp, { recursive: true });
    ensureExecutableMode(darwinAppExecutablePath(tempApp));
    rmSync(targetApp, { recursive: true, force: true });
    renameSync(tempApp, targetApp);
    writeFileSync(markerPath, signature);
    return targetApp;
  } catch (error) {
    rmSync(tempApp, { recursive: true, force: true });
    const message = error instanceof Error ? error.message : String(error);
    throw cliError("record.helper_unavailable", "Recappi recording helper could not be installed.", {
      hint: `Could not prepare the local recorder at ${targetApp}: ${message}. Reinstall recappi, or set ${SIDECAR_COMMAND_ENV} to a compatible helper.`,
    });
  }
}

function stableDarwinHelperAppPath(opts: Pick<RecordCommandOptions, "env" | "homeDir"> = {}): string {
  const base =
    opts.env?.RECAPPI_HELPER_HOME?.trim() ||
    join(opts.homeDir ?? homedir(), "Library", "Application Support", "Recappi");
  return join(base, SIDECAR_APP_BUNDLE_NAME);
}

function helperSourceSignature(sourceApp: string): string {
  const executablePath = darwinAppExecutablePath(sourceApp);
  const infoPath = join(sourceApp, "Contents", "Info.plist");
  const signaturePath = join(sourceApp, "Contents", "_CodeSignature", "CodeResources");
  return JSON.stringify({
    app: SIDECAR_APP_BUNDLE_NAME,
    executable: fileDigest(executablePath),
    info: fileDigest(infoPath),
    codeSignature: existsSync(signaturePath) ? fileDigest(signaturePath) : null,
  });
}

function fileDigest(path: string): string {
  const hash = createHash("sha256");
  hash.update(readFileSync(path));
  return hash.digest("hex");
}

function readTextIfExists(path: string): string | null {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

export function bundledSidecarCommand(
  platform: NodeJS.Platform,
  arch: string,
): string | null {
  const executable = helperExecutableName(platform);
  if (!executable) return null;
  const helperPackage = helperPackageName(platform, arch);
  if (helperPackage) {
    const packageJson = resolveOptionalHelperPackage(helperPackage);
    if (packageJson) return join(dirname(packageJson), executable);
  }
  const packageRoot = new URL("..", import.meta.url);
  return fileURLToPath(new URL(`helpers/${platform}-${arch}/${executable}`, packageRoot));
}

function helperExecutableName(platform: NodeJS.Platform): string | null {
  if (platform === "darwin") return SIDECAR_APP_BUNDLE_NAME;
  if (platform === "win32") return `${SIDECAR_HELPER_NAME}.exe`;
  return null;
}

function darwinAppExecutablePath(appPath: string): string {
  return join(appPath, "Contents", "MacOS", SIDECAR_HELPER_NAME);
}

function helperPackageName(platform: NodeJS.Platform, arch: string): string | null {
  if (platform === "darwin" && arch === "arm64") return "recappi-helper-darwin-arm64";
  return null;
}

function resolveOptionalHelperPackage(packageName: string): string | null {
  try {
    return requireFromCli.resolve(`${packageName}/package.json`);
  } catch {
    return null;
  }
}

function persistArtifacts(
  artifacts: SidecarLocalArtifact[],
  account: SidecarAccount,
  opts: RecordCommandOptions,
): void {
  if (artifacts.length === 0) return;
  const store = openCliStore({ homeDir: opts.homeDir, env: opts.env });
  try {
    for (const artifact of artifacts) {
      store.addLocalArtifact({
        kind: artifact.kind,
        account,
        localPath: artifact.localPath,
        remoteId: artifact.remoteId,
        metadata: artifact.metadata,
      });
    }
  } finally {
    store.close();
  }
}

function dedupeArtifacts(artifacts: SidecarLocalArtifact[]): SidecarLocalArtifact[] {
  const seen = new Set<string>();
  const out: SidecarLocalArtifact[] = [];
  for (const artifact of artifacts) {
    const key = [artifact.kind, artifact.localPath, artifact.remoteId ?? ""].join("\u0000");
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(artifact);
  }
  return out;
}

export function waitForStopSignal(): Promise<void> {
  return new Promise((resolve) => {
    const stop = () => {
      process.off("SIGINT", stop);
      process.off("SIGTERM", stop);
      resolve();
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
}

function createInkLiveRenderer(opts: {
  source: LiveCaptionEventSource;
  renderApp?: LiveRendererRenderApp;
  now?: () => number;
}): RecordLiveRenderer {
  let resolveStop: (() => void) | undefined;
  const stopped = new Promise<void>((resolve) => {
    resolveStop = resolve;
  });
  const renderApp = opts.renderApp ?? render;
  const app = renderApp(
    <RecordLiveScreen
      source={opts.source}
      onStop={() => resolveStop?.()}
      now={opts.now ?? Date.now}
    />,
    { alternateScreen: true, interactive: true },
  );
  return {
    waitUntilStop: () => stopped,
    close: () => app.unmount(),
  };
}

function RecordLiveScreen({
  source,
  onStop,
  now,
}: {
  source: LiveCaptionEventSource;
  onStop: () => void;
  now: () => number;
}): React.ReactElement {
  useInput((input, key) => {
    if (input === "q" || key.escape || key.leftArrow) onStop();
  });
  return <LiveCaptionsScreen source={source} now={now} />;
}
