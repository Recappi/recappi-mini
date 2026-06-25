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
