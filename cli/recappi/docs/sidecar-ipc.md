# Recappi Mini Sidecar IPC v1

Status: task #252 contract for CLI reuse, updated by task #261 for packaged macOS helper `.app` launch. Transport is newline-delimited JSON-RPC 2.0 over stdio.

## Ownership

- `RecappiCaptureCore` owns macOS-native capture through `CaptureAudioRecordingSession`: ScreenCaptureKit system/app audio, microphone sample buffers, writer/mixer/diagnostics, and `states` / `levels` streams.
- Recappi Mini sidecar owns the JSON-RPC adapter, permissions preflight, local session metadata/artifact mapping, live-caption buffering, and upload/finalization hooks.
- Recappi CLI owns command parsing, machine-safe output, TUI rendering, CLI SQLite indexing, and account-scoped references to sidecar artifacts.
- Both sides use `(backendOrigin, userId)` as the account partition key. Unattributed local sessions remain explicit and are never silently reassigned.

## Startup

The CLI resolves a sidecar helper, launches it, and immediately sends
`recappi.handshake`. Development builds can pass `--sidecar-command` or set
`RECAPPI_MINI_SIDECAR`. Packaged macOS builds resolve a signed helper `.app`
from `helpers/<platform>-<arch>/` and launch it through LaunchServices so
Screen Recording permission is attributed to the helper app. The CLI still
speaks newline-delimited JSON-RPC over stdin/stdout; on macOS `.app` helpers
that stdio is connected through LaunchServices `--stdin` / `--stdout` pipes.
The JSON-RPC contract remains OS-neutral so macOS and Windows helpers can share
the same CLI/TUI surface.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "recappi.handshake",
  "params": {
    "protocolVersion": 1,
    "client": { "name": "recappi-cli", "version": "0.1.0" },
    "account": { "backendOrigin": "https://recordmeet.ing", "userId": "user_123" },
    "capabilities": ["recording.capture", "live_captions.stream"]
  }
}
```

The sidecar replies with its protocol version, app/sidecar version, and supported capabilities. Protocol v1 only supports one CLI client per sidecar process; multi-client or long-lived daemon mode can move to a local socket later.

## Requests

- `recappi.handshake`
- `recappi.recording.sources.list`
- `recappi.recording.microphones.list`
- `recappi.permissions.status`
- `recappi.recording.start`
- `recappi.recording.stop`
- `recappi.recording.cancel`
- `recappi.recording.status`

`recappi.recording.sources.list` returns helper-backed capture targets. The
system source is always present; app sources are shown only when the helper can
send `targetBundleId` back to native capture instead of falling back to system
audio.

```json
{
  "sources": [
    { "id": "system", "kind": "system", "label": "System audio · all apps" },
    {
      "id": "app:com.apple.Safari",
      "kind": "app",
      "label": "Safari",
      "appName": "Safari",
      "bundleId": "com.apple.Safari"
    }
  ]
}
```

`recappi.recording.microphones.list` returns selectable microphone devices for
the additive microphone input:

```json
{
  "microphones": [
    { "id": "BuiltInMicrophoneDevice", "label": "MacBook Pro Microphone", "isDefault": true }
  ]
}
```

Permission status and recording start both use recording options. Permission
status is a no-prompt preflight so the CLI/TUI can show a setup screen before a
recording attempt hits macOS TCC:

```json
{
  "options": {
    "includeSystemAudio": true,
    "includeMicrophone": true,
    "targetBundleId": "com.apple.Safari",
    "microphoneDeviceId": "BuiltInMicrophoneDevice",
    "liveCaptions": false
  }
}
```

The sidecar replies with a `permissions` array. Permission names are
`screen_recording` and `microphone`; status is `granted`, `denied`, or
`unknown`. Permission items may include `requiresProcessRestart: true`; for
Screen Recording this means permission was enabled but the current helper
process cannot use it, so the CLI must ask the user to run `recappi record`
again.

```json
{
  "permissions": [
    {
      "name": "screen_recording",
      "status": "granted",
      "requiresProcessRestart": true,
      "hint": "Screen Recording enabled. Run recappi record again to start."
    }
  ]
}
```

Recording start params include the account partition and recording options:

```json
{
  "account": { "backendOrigin": "https://recordmeet.ing", "userId": "user_123" },
  "options": {
    "includeSystemAudio": true,
    "includeMicrophone": true,
    "targetBundleId": "com.apple.Safari",
    "microphoneDeviceId": "BuiltInMicrophoneDevice",
    "liveCaptions": true,
    "translationLanguage": "zh",
    "title": "CLI recording"
  }
}
```

On macOS, `recappi.recording.start` creates a shared-core
`CaptureAudioRecordingSession`. The sidecar forwards the core session's
`states` stream as `recording.state` events and its `levels` stream as
`audio.level` events, then maps the returned `CaptureArtifact` to a
`recording_session` local artifact on stop.

Stop/cancel/status use `{ "sessionId": "..." }`.

## Events

Events are JSON-RPC notifications with `method: "recappi.event"`:

- `ready`
- `recording.state`
- `audio.level`
- `live_caption.delta`
- `local_artifact.upserted`
- `error`

`audio.level` carries one physical input lane only: `input` is `system` or
`microphone`. The sidecar must not emit `mixed` in IPC; the CLI/TUI combines
system and microphone levels itself when it needs a single meter. Native macOS
helpers emit levels from the shared core session's captured sample buffers at a
throttled UI cadence, using `rmsDb` plus `atMs`.

`live_caption.delta` is provisional stream data. It carries `stream`, `text`, optional `isFinal`, optional `segmentId`/`speaker`, and optional timing fields (`atMs`, `startMs`, `endMs`) so the CLI can map it to connecting/live/error status, partial caption rows, and finalized caption lines. If persisted, the artifact kind is `live_caption_draft`; it must not be treated as the official transcript.

## Local Artifacts

The sidecar may report local artifacts using `local_artifact.upserted`. The CLI stores these in its own SQLite index under the current account partition.

Supported v1 artifact kinds:

- `recording_session`
- `download`
- `live_caption_draft`

## Errors

JSON-RPC errors reject the pending CLI request. Sidecar-originated async failures use the `error` event and include a string `code`, human-readable `message`, optional `sessionId`, and optional `retryable`.

Sidecar JSON-RPC errors can include `data.cliCode` to map into stable CLI error
codes. Known recording codes:

- `record.permission_required`
- `record.capture_failed`
