This directory is reserved for native recording helpers bundled in the npm
package.

The CLI selects helpers by `process.platform` and `process.arch`:

- `darwin-arm64/RecappiMiniSidecar`
- `darwin-x64/RecappiMiniSidecar`
- `win32-x64/RecappiMiniSidecar.exe`
- `win32-arm64/RecappiMiniSidecar.exe`

Development builds can override helper resolution with `--sidecar-command` or
`RECAPPI_MINI_SIDECAR`.
