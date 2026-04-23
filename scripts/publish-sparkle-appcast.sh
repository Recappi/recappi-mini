#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST_SOURCE="${1:-}"
if [ -z "$APPCAST_SOURCE" ]; then
    echo "Usage: $0 <appcast.xml>" >&2
    exit 1
fi

APPCAST_BRANCH="${APPCAST_BRANCH:-sparkle-appcast}"
APPCAST_FILENAME="${APPCAST_FILENAME:-appcast.xml}"
RELEASE_TAG="${RELEASE_TAG:-manual}"
WORKTREE_DIR="$(mktemp -d)"

cleanup() {
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT

git -C "$ROOT_DIR" fetch origin "$APPCAST_BRANCH" >/dev/null 2>&1 || true

if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$APPCAST_BRANCH"; then
    git -C "$ROOT_DIR" worktree add -B "$APPCAST_BRANCH" "$WORKTREE_DIR" "origin/$APPCAST_BRANCH" >/dev/null
else
    git -C "$ROOT_DIR" worktree add --detach "$WORKTREE_DIR" >/dev/null
    git -C "$WORKTREE_DIR" checkout --orphan "$APPCAST_BRANCH" >/dev/null
    git -C "$WORKTREE_DIR" rm -rf . >/dev/null 2>&1 || true
    find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
fi

cp "$APPCAST_SOURCE" "$WORKTREE_DIR/$APPCAST_FILENAME"
cat > "$WORKTREE_DIR/README.md" <<EOF
# Sparkle Appcast

This branch is updated by the release workflow and serves the Sparkle appcast
for Recappi Mini.
EOF

git -C "$WORKTREE_DIR" add "$APPCAST_FILENAME" README.md
if git -C "$WORKTREE_DIR" diff --cached --quiet; then
    echo "No Sparkle appcast changes to publish."
    exit 0
fi

git -C "$WORKTREE_DIR" \
    -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -m "docs(appcast): publish $RELEASE_TAG" >/dev/null

git -C "$WORKTREE_DIR" push origin "$APPCAST_BRANCH" >/dev/null
