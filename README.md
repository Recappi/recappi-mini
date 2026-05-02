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
