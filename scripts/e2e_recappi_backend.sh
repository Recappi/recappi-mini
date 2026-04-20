#!/bin/bash
set -euo pipefail

if [[ -z "${RECAPPI_TEST_AUTH_TOKEN:-}" ]]; then
  echo "RECAPPI_TEST_AUTH_TOKEN is required" >&2
  exit 1
fi

ORIGIN="${RECAPPI_TEST_BACKEND_URL:-https://recordmeet.ing}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d /tmp/recappi-e2e.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

say -o "$TMPDIR/test.aiff" "hello from recappi mini backend end to end test"
afconvert -f WAVE -d LEI16@16000,1 "$TMPDIR/test.aiff" "$TMPDIR/test.wav" >/dev/null 2>&1

AUTH_TOKEN="$RECAPPI_TEST_AUTH_TOKEN"

BEARER_SESSION=$(curl -fsS "$ORIGIN/api/auth/get-session" \
  -H "origin: $ORIGIN" \
  -H "authorization: Bearer $AUTH_TOKEN")

echo "$BEARER_SESSION" | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort("missing user") unless j["user"] && j["session"]; puts "bearer session ok"' >/dev/null

CREATE=$(curl -fsS -X POST "$ORIGIN/api/recordings" \
  -H "origin: $ORIGIN" \
  -H "authorization: Bearer $AUTH_TOKEN" \
  -H "content-type: application/json" \
  --data '{"title":"recappi e2e probe"}')

REC_ID=$(printf '%s' "$CREATE" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["id"]')
PART_SIZE=$(printf '%s' "$CREATE" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["partSize"]')
SIZE=$(stat -f%z "$TMPDIR/test.wav")

PUT=$(curl -fsS -X PUT "$ORIGIN/api/recordings/$REC_ID/parts/1" \
  -H "origin: $ORIGIN" \
  -H "authorization: Bearer $AUTH_TOKEN" \
  -H "content-type: application/octet-stream" \
  -H "content-length: $SIZE" \
  --data-binary @"$TMPDIR/test.wav")

ETAG=$(printf '%s' "$PUT" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["etag"]')

curl -fsS -X POST "$ORIGIN/api/recordings/$REC_ID/complete" \
  -H "origin: $ORIGIN" \
  -H "authorization: Bearer $AUTH_TOKEN" \
  -H "content-type: application/json" \
  --data "{\"parts\":[{\"partNumber\":1,\"etag\":\"$ETAG\"}]}" >/dev/null

TRANSCRIBE=$(curl -fsS -X POST "$ORIGIN/api/recordings/$REC_ID/transcribe" \
  -H "origin: $ORIGIN" \
  -H "authorization: Bearer $AUTH_TOKEN" \
  -H "content-type: application/json" \
  --data '{"language":"en"}')

JOB_ID=$(printf '%s' "$TRANSCRIBE" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["jobId"]')

STATUS=""
for _ in {1..20}; do
  JOB=$(curl -fsS "$ORIGIN/api/jobs/$JOB_ID" \
    -H "origin: $ORIGIN" \
    -H "authorization: Bearer $AUTH_TOKEN")
  STATUS=$(printf '%s' "$JOB" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["status"]')
  if [[ "$STATUS" == "succeeded" || "$STATUS" == "failed" ]]; then
    break
  fi
  sleep 2
done

if [[ "$STATUS" != "succeeded" ]]; then
  echo "Job did not succeed: $STATUS" >&2
  exit 1
fi

TRANSCRIPT=$(curl -fsS "$ORIGIN/api/recordings/$REC_ID/transcript?jobId=$JOB_ID" \
  -H "origin: $ORIGIN" \
  -H "authorization: Bearer $AUTH_TOKEN")

TEXT=$(printf '%s' "$TRANSCRIPT" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["text"]')
if [[ -z "$TEXT" ]]; then
  echo "Transcript was empty" >&2
  exit 1
fi

echo "recappi backend e2e ok"
