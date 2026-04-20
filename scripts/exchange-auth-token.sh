#!/bin/bash
set -euo pipefail

ORIGIN="${RECAPPI_TEST_BACKEND_URL:-https://recordmeet.ing}"

if [[ -n "${RECAPPI_TEST_AUTH_TOKEN:-}" ]]; then
  printf '%s' "$RECAPPI_TEST_AUTH_TOKEN"
  exit 0
fi

if [[ -z "${RECAPPI_TEST_COOKIE:-}" ]]; then
  echo "RECAPPI_TEST_COOKIE or RECAPPI_TEST_AUTH_TOKEN is required" >&2
  exit 1
fi

TMP_HEADERS="$(mktemp /tmp/recappi-auth-headers.XXXXXX)"
TMP_BODY="$(mktemp /tmp/recappi-auth-body.XXXXXX)"
trap 'rm -f "$TMP_HEADERS" "$TMP_BODY"' EXIT

curl -fsS -D "$TMP_HEADERS" \
  "$ORIGIN/api/auth/get-session" \
  -H "origin: $ORIGIN" \
  -H "cookie: __Secure-better-auth.session_token=${RECAPPI_TEST_COOKIE}" \
  -o "$TMP_BODY"

python3 - "$TMP_HEADERS" "$TMP_BODY" <<'PY'
import json
import sys
from pathlib import Path

headers = Path(sys.argv[1]).read_text().splitlines()
body = json.loads(Path(sys.argv[2]).read_text())

header_token = None
for line in headers:
    if line.lower().startswith("set-auth-token:"):
        header_token = line.split(":", 1)[1].strip()
        break

payload_token = ((body or {}).get("session") or {}).get("token")
token = header_token or payload_token
if not token:
    raise SystemExit("failed to derive bearer token from get-session response")

print(token, end="")
PY
