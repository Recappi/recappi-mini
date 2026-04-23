#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/Tests/Fixtures/Audio"
TMP_DIR="$(mktemp -d)"
SOURCE_AIFF="$TMP_DIR/source.aiff"
RECORDING_M4A="$OUT_DIR/automation-recording.m4a"
UPLOAD_WAV="$OUT_DIR/automation-upload.wav"
MANIFEST_JSON="$OUT_DIR/fixture-manifest.json"
PHRASE="${RECAPPI_FIXTURE_PHRASE:-Recappi Mini automation smoke test. This sentence should survive upload and transcription.}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

say -o "$SOURCE_AIFF" "$PHRASE"

afconvert "$SOURCE_AIFF" \
  -o "$RECORDING_M4A" \
  -f m4af \
  -d aac@48000 \
  -c 2 \
  -b 128000 \
  >/dev/null

afconvert "$SOURCE_AIFF" \
  -o "$UPLOAD_WAV" \
  -f WAVE \
  -d LEI16@16000 \
  -c 1 \
  >/dev/null

RECORDING_SHA="$(shasum -a 256 "$RECORDING_M4A" | awk '{print $1}')"
UPLOAD_SHA="$(shasum -a 256 "$UPLOAD_WAV" | awk '{print $1}')"

python3 - <<'PY' "$MANIFEST_JSON" "$PHRASE" "$RECORDING_SHA" "$UPLOAD_SHA"
import json
import sys

manifest_path, phrase, recording_sha, upload_sha = sys.argv[1:5]

payload = {
    "generator": "scripts/generate-test-audio-fixtures.sh",
    "spoken_phrase": phrase,
    "artifacts": {
        "recording_m4a": "automation-recording.m4a",
        "upload_wav": "automation-upload.wav",
    },
    "checksums": {
        "recording_m4a_sha256": recording_sha,
        "upload_wav_sha256": upload_sha,
    },
}

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

printf 'Generated fixtures:\n- %s\n- %s\n- %s\n' "$RECORDING_M4A" "$UPLOAD_WAV" "$MANIFEST_JSON"
