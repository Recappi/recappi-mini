This directory contains native recording helpers bundled in the npm package.

The CLI selects helpers by `process.platform` and `process.arch`:

- `darwin-arm64/Recappi Recorder.app`
- `darwin-x64/Recappi Recorder.app`
- Windows launches `dist/windows-sidecar.js` with the current Node.js executable.
  It resolves `RecappiAudioCapture.exe` from the optional
  `recappi-helper-win32-x64` or `recappi-helper-win32-arm64` npm package.

Development builds can override helper resolution with `--sidecar-command` or
`RECAPPI_MINI_SIDECAR`.

Run `scripts/build-cli-helper.sh` for macOS or
`scripts/build-windows-cli-helper.ps1` for Windows. Native binaries ship in
separate optional packages whose versions match `recappi`. The CLI package
ships JavaScript only; `pack:check` verifies its entry points and dependencies.
