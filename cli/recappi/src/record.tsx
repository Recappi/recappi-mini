import React from "react";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { render, useInput, type Instance, type RenderOptions as InkRenderOptions } from "ink";
import {
  recordCommandDataSchema,
  type RecordCommandData,
  type SidecarAccount,
  type SidecarHandshakeResult,
  type SidecarLocalArtifact,
  type SidecarRecordingState,
} from "../../packages/contracts/src/index";
import { cliError } from "./errors";
import {
  defaultSidecarHandshakeParams,
  spawnMiniSidecar,
  type SpawnedMiniSidecar,
} from "./sidecar";
import { openCliStore, requireAccountPartition } from "./store";
import { LiveCaptionsScreen, type LiveCaptionEventSource } from "./tui/LiveCaptionsScreen";

const SIDECAR_COMMAND_ENV = "RECAPPI_MINI_SIDECAR";
const SIDECAR_HELPER_NAME = "RecappiMiniSidecar";

export interface RecordCommandOptions {
  account: SidecarAccount;
  cliVersion: string;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  title?: string;
  live?: boolean;
  includeSystemAudio?: boolean;
  includeMicrophone?: boolean;
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
  source: LiveCaptionEventSource;
  stop: () => Promise<void>;
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
): Promise<LiveRecordSession> {
  const session = await startRecordSession({ ...opts, live: true });
  return {
    source: session.source,
    stop: async () => {
      await session.stop();
    },
  };
}

interface ActiveRecordSession {
  source: LiveCaptionEventSource;
  stop: () => Promise<RecordCommandData>;
  cancel: () => Promise<void>;
  close: () => void;
}

async function startRecordSession(opts: RecordCommandOptions): Promise<ActiveRecordSession> {
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

    const started = await sidecar.client.startRecording({
      account,
      options: {
        includeSystemAudio: opts.includeSystemAudio ?? true,
        includeMicrophone: opts.includeMicrophone ?? true,
        liveCaptions: opts.live === true,
        ...(opts.translationLanguage ? { translationLanguage: opts.translationLanguage } : {}),
        ...(opts.transcriptionLanguage
          ? { transcriptionLanguage: opts.transcriptionLanguage }
          : {}),
        ...(opts.title ? { title: opts.title } : {}),
      },
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

function resolveSidecarCommand(opts: RecordCommandOptions): string {
  const command = opts.sidecarCommand?.trim() || opts.env?.[SIDECAR_COMMAND_ENV]?.trim();
  if (command) return command;

  const bundled = bundledSidecarCommand(process.platform, process.arch);
  if (bundled && existsSync(bundled)) return bundled;

  const platform = `${process.platform}-${process.arch}`;
  if (bundled) {
    throw cliError("usage.invalid_argument", "Recappi recording helper is not available.", {
      hint: `Expected bundled helper for ${platform} at ${bundled}. Reinstall recappi, or set ${SIDECAR_COMMAND_ENV} to a compatible helper.`,
    });
  }
  throw cliError("usage.invalid_argument", "Recappi recording is not supported on this platform yet.", {
    hint: `No bundled helper is registered for ${platform}. Set ${SIDECAR_COMMAND_ENV} to a compatible helper when one is available.`,
  });
}

export function bundledSidecarCommand(
  platform: NodeJS.Platform,
  arch: string,
): string | null {
  const executable = helperExecutableName(platform);
  if (!executable) return null;
  const packageRoot = new URL("..", import.meta.url);
  return fileURLToPath(new URL(`helpers/${platform}-${arch}/${executable}`, packageRoot));
}

function helperExecutableName(platform: NodeJS.Platform): string | null {
  if (platform === "darwin") return SIDECAR_HELPER_NAME;
  if (platform === "win32") return `${SIDECAR_HELPER_NAME}.exe`;
  return null;
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
