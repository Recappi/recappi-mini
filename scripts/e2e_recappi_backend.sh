#!/bin/bash
set -euo pipefail

if [[ -z "${RECAPPI_TEST_COOKIE:-}" ]]; then
  echo "RECAPPI_TEST_COOKIE is required" >&2
  exit 1
fi

ORIGIN="${RECAPPI_TEST_BACKEND_URL:-https://recordmeet.ing}"
TMPDIR="$(mktemp -d /tmp/recappi-e2e.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

say -o "$TMPDIR/test.aiff" "hello from recappi mini backend end to end test"
afconvert -f WAVE -d LEI16@16000,1 "$TMPDIR/test.aiff" "$TMPDIR/test.wav" >/dev/null 2>&1

COOKIE_HEADER="__Secure-better-auth.session_token=${RECAPPI_TEST_COOKIE}"
SESSION=$(curl -fsS "$ORIGIN/api/auth/get-session" \
  -H "origin: $ORIGIN" \
  -H "cookie: $COOKIE_HEADER")

echo "$SESSION" | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort("missing user") unless j["user"] && j["session"]; puts "session ok"' >/dev/null

CREATE=$(curl -fsS -X POST "$ORIGIN/api/recordings" \
  -H "origin: $ORIGIN" \
  -H "content-type: application/json" \
  -H "cookie: $COOKIE_HEADER" \
  --data '{"title":"recappi e2e probe"}')

REC_ID=$(printf '%s' "$CREATE" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["id"]')
PART_SIZE=$(printf '%s' "$CREATE" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["partSize"]')
SIZE=$(stat -f%z "$TMPDIR/test.wav")

PUT=$(curl -fsS -X PUT "$ORIGIN/api/recordings/$REC_ID/parts/1" \
  -H "origin: $ORIGIN" \
  -H "content-type: application/octet-stream" \
  -H "content-length: $SIZE" \
  -H "cookie: $COOKIE_HEADER" \
  --data-binary @"$TMPDIR/test.wav")

ETAG=$(printf '%s' "$PUT" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["etag"]')

curl -fsS -X POST "$ORIGIN/api/recordings/$REC_ID/complete" \
  -H "origin: $ORIGIN" \
  -H "content-type: application/json" \
  -H "cookie: $COOKIE_HEADER" \
  --data "{\"parts\":[{\"partNumber\":1,\"etag\":\"$ETAG\"}]}" >/dev/null

TRANSCRIBE=$(curl -fsS -X POST "$ORIGIN/api/recordings/$REC_ID/transcribe" \
  -H "origin: $ORIGIN" \
  -H "content-type: application/json" \
  -H "cookie: $COOKIE_HEADER" \
  --data '{"language":"en"}')

JOB_ID=$(printf '%s' "$TRANSCRIBE" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["jobId"]')

STATUS=""
for _ in {1..20}; do
  JOB=$(curl -fsS "$ORIGIN/api/jobs/$JOB_ID" \
    -H "origin: $ORIGIN" \
    -H "cookie: $COOKIE_HEADER")
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
  -H "cookie: $COOKIE_HEADER")

TEXT=$(printf '%s' "$TRANSCRIPT" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["text"]')
if [[ -z "$TEXT" ]]; then
  echo "Transcript was empty" >&2
  exit 1
fi

echo "recappi backend e2e ok"
