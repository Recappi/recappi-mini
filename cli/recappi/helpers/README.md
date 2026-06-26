This directory contains native recording helpers bundled in the npm package.

The CLI selects helpers by `process.platform` and `process.arch`:

- `darwin-arm64/Recappi Recorder.app`
- `darwin-x64/Recappi Recorder.app`
- `win32-x64/RecappiMiniSidecar.exe`
- `win32-arm64/RecappiMiniSidecar.exe`

Development builds can override helper resolution with `--sidecar-command` or
`RECAPPI_MINI_SIDECAR`.

Run `scripts/build-cli-helper.sh` from the repository root before `pnpm pack` or
`pnpm publish`; `pack:check` fails if the package does not include at least one
Darwin helper executable.
