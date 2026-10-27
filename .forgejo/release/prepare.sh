#!/bin/sh
# Release prepare hook for this repository.
#
# Called by the generic release Action from the tagged checkout.  Writes the
# absolute paths of the release assets to RELEASE_ASSETS_FILE.
set -eu

: "${GITHUB_WORKSPACE:?prepare.sh: GITHUB_WORKSPACE 未设置}"
: "${RELEASE_VERSION:?prepare.sh: RELEASE_VERSION 未设置}"
: "${RELEASE_ASSETS_FILE:?prepare.sh: RELEASE_ASSETS_FILE 未设置}"
FORGEJO_DIR="${FORGEJO_DIR:-$GITHUB_WORKSPACE/.forgejo}"

cd "$GITHUB_WORKSPACE"
version="$RELEASE_VERSION"

ensure_tools() {
  packages="$1"
  [ -n "$packages" ] || return 0
  if command -v node >/dev/null 2>&1 && [ -f "$FORGEJO_DIR/scripts/run.mjs" ]; then
    RELEASE_JOB_PACKAGES="$packages" node "$FORGEJO_DIR/scripts/run.mjs" ensure-tools
  fi
}

emit_asset() {
  asset="$1"
  if [ ! -s "$asset" ]; then
    echo "[ERROR] 产物不存在或为空：$asset" >&2
    exit 1
  fi
  printf '%s\n' "$asset" >> "$RELEASE_ASSETS_FILE"
  echo "  - $(basename "$asset")  $(wc -c < "$asset") bytes"
}


ensure_tools "perl zip"

echo "[prepare] ./build.sh --no-test"
./build.sh --no-test

: > "$RELEASE_ASSETS_FILE"
echo "[prepare] 资产清单（$RELEASE_ASSETS_FILE）："
emit_asset "$GITHUB_WORKSPACE/dist/PlayVideo-$version.zip"
emit_asset "$GITHUB_WORKSPACE/dist/PlayVideo-$version.tar.gz"
