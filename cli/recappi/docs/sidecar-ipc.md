# Recappi Mini Sidecar IPC v1

Status: task #252 contract for CLI reuse. Transport is newline-delimited JSON-RPC 2.0 over stdio.

## Ownership

- Recappi Mini sidecar owns macOS-native recording, permissions, local session writes, live-caption buffering, and upload/finalization hooks.
- Recappi CLI owns command parsing, machine-safe output, TUI rendering, CLI SQLite indexing, and account-scoped references to sidecar artifacts.
- Both sides use `(backendOrigin, userId)` as the account partition key. Unattributed local sessions remain explicit and are never silently reassigned.

## Startup

The CLI resolves a sidecar helper, spawns that process, and immediately sends
`recappi.handshake`. Development builds can pass `--sidecar-command` or set
`RECAPPI_MINI_SIDECAR`; packaged builds resolve helpers from
`helpers/<platform>-<arch>/` in the npm package. The JSON-RPC contract is
OS-neutral so macOS and Windows helpers can share the same CLI/TUI surface.

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
- `recappi.recording.start`
- `recappi.recording.stop`
- `recappi.recording.cancel`
- `recappi.recording.status`

Recording start params include the account partition and recording options:

```json
{
  "account": { "backendOrigin": "https://recordmeet.ing", "userId": "user_123" },
  "options": {
    "includeSystemAudio": true,
    "includeMicrophone": true,
    "liveCaptions": true,
    "translationLanguage": "zh",
    "title": "CLI recording"
  }
}
```

Stop/cancel/status use `{ "sessionId": "..." }`.

## Events

Events are JSON-RPC notifications with `method: "recappi.event"`:

- `ready`
- `recording.state`
- `audio.level`
- `live_caption.delta`
- `local_artifact.upserted`
- `error`

`live_caption.delta` is provisional stream data. It carries `stream`, `text`, optional `isFinal`, optional `segmentId`/`speaker`, and optional timing fields (`atMs`, `startMs`, `endMs`) so the CLI can map it to connecting/live/error status, partial caption rows, and finalized caption lines. If persisted, the artifact kind is `live_caption_draft`; it must not be treated as the official transcript.

## Local Artifacts

The sidecar may report local artifacts using `local_artifact.upserted`. The CLI stores these in its own SQLite index under the current account partition.

Supported v1 artifact kinds:

- `recording_session`
- `download`
- `live_caption_draft`

## Errors

JSON-RPC errors reject the pending CLI request. Sidecar-originated async failures use the `error` event and include a string `code`, human-readable `message`, optional `sessionId`, and optional `retryable`.
