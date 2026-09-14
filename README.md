# Recappi Mini

## Local Development

Build the local app bundle with the repo default signing identity:

```bash
./scripts/build-app.sh
open "build/Recappi Mini.app"
```

The default `RecappiMini Dev` code signing identity keeps the app identity stable
across rebuilds, so macOS Screen Recording and other privacy permissions only
need to be granted once on this development machine. Do not use
`CODESIGN_IDENTITY=-` for local UI verification: ad-hoc signing changes the code
identity on every build and makes macOS show TCC permission prompts again.

## CLI

The npm `recappi` CLI source of truth lives in `cli/recappi`, with shared
machine-readable contracts in `cli/packages/contracts`.

```bash
pnpm install --frozen-lockfile
pnpm --filter recappi check
pnpm --filter recappi pack:check
```

Recording is mediated through the OS-neutral sidecar IPC contract documented in
`cli/recappi/docs/sidecar-ipc.md`. The npm package resolves native helpers from
`cli/recappi/helpers/<platform>-<arch>/`; development builds can override this
with `--sidecar-command` or `RECAPPI_MINI_SIDECAR`.

### Windows CLI

Windows x64 and arm64 packages include a self-contained native audio helper;
end users need Node.js (24 recommended), but do not need to install .NET.
Keep npm optional dependencies enabled when installing `recappi`.

```powershell
recappi auth login
recappi record --title "Meeting"
# Press Enter in the recording UI, or Ctrl+C, to stop and upload.
recappi record --no-microphone     # system audio only
recappi record --no-system-audio   # default microphone only
```

Recording uses the Windows default input/output devices. It saves a local PCM
WAV before uploading through the existing cloud API and queuing transcription.
Local recordings are account-partitioned under
`%USERPROFILE%\.config\recappi\recordings`; `RECAPPI_RECORDINGS_DIR` can override
the recording directory. If upload fails, the local file remains available for
`recappi upload <audio.wav>`. Never treat `state: completed` alone as cloud
success: inspect `recordingId` and `cloudHandoffError` in JSON output.

The first Windows version does not implement app-specific capture, microphone
device selection, input level previews, or live captions. Unsupported options
fail explicitly; the regular recording UI can run without live captions.
Devices are selected when capture starts; restart recording after switching the
Windows default devices. Enable microphone access for desktop apps in Windows
Settings when recording the microphone.

Build and verify from source on Windows with Node.js 24, pnpm and .NET SDK 10:

```powershell
pnpm install --frozen-lockfile
./scripts/build-windows-cli-helper.ps1
pnpm --filter recappi check
node cli/recappi/dist/index.js auth login
node cli/recappi/dist/index.js record
```

Use `-Architecture arm64` to cross-build the arm64 helper. Windows CLI code and
packaging are checked by CI; audio hardware checks are opt-in:

```powershell
# Three-second local capture, without cloud upload:
node cli/recappi/scripts/smoke-windows-recording.mjs
# Play a quiet test tone and verify it appears in system capture:
node cli/recappi/scripts/smoke-windows-recording.mjs --tone --system-only
# Verify an isolated npm installation without opening audio devices:
node cli/recappi/scripts/check-windows-install.mjs
```
