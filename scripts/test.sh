#!/usr/bin/env bash
# Run luacheck and the SmartThings integration tests for every driver.
# Used both locally and in CI.
#
# Requirements: lua5.3, curl, sha256sum (or shasum), tar. luacheck is optional locally, required in CI.
#
# The SmartThings Lua libraries are pinned to a specific release and verified by checksum.
# To upgrade: set LUA_LIBS_TAG / LUA_LIBS_ASSET / LUA_LIBS_SHA256 below to the new release
# (https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers/releases) and run this script.
set -euo pipefail

LUA_LIBS_TAG="apiv21_62"
LUA_LIBS_ASSET="lua_libs-api_v21_62X.tar.gz"
LUA_LIBS_SHA256="6956bb74f8a2e08f6fc513d9239717885f0f9fb03beee8339be8e5b1bcaa2b0d"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBS_DIR="$ROOT/.cache/lua_libs/$LUA_LIBS_TAG"
LUA="${LUA:-lua5.3}"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [ ! -f "$LIBS_DIR/.ok" ]; then
  echo "Downloading SmartThings Lua libraries $LUA_LIBS_TAG"
  mkdir -p "$LIBS_DIR"
  archive="$LIBS_DIR/$LUA_LIBS_ASSET"
  curl -fsSL -o "$archive" \
    "https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers/releases/download/$LUA_LIBS_TAG/$LUA_LIBS_ASSET"
  actual="$(sha256 "$archive")"
  if [ "$actual" != "$LUA_LIBS_SHA256" ]; then
    echo "Checksum mismatch for $LUA_LIBS_ASSET: expected $LUA_LIBS_SHA256, got $actual" >&2
    exit 1
  fi
  tar -xf "$archive" -C "$LIBS_DIR" --strip-components=1 --wildcards '*.lua'
  touch "$LIBS_DIR/.ok"
fi

if command -v luacheck >/dev/null; then
  echo "== luacheck"
  (cd "$ROOT" && luacheck drivers)
elif [ "${CI:-}" = "true" ]; then
  echo "luacheck is required in CI" >&2
  exit 1
else
  echo "== luacheck not installed, skipping lint"
fi

status=0
for driver_src in "$ROOT"/drivers/*/src; do
  for test_file in "$driver_src"/test/test_*.lua; do
    [ -e "$test_file" ] || continue
    echo "== $(basename "$(dirname "$driver_src")"): $(basename "$test_file")"
    output="$(cd "$driver_src" && \
      LUA_PATH="$LIBS_DIR/?.lua;$LIBS_DIR/?/init.lua;./?.lua;./?/init.lua;;" \
      "$LUA" "test/$(basename "$test_file")" 2>&1)" || true
    summary="$(printf '%s\n' "$output" | grep -E '^Passed [0-9]+ of [0-9]+ tests' | tail -1 || true)"
    echo "   ${summary:-no summary}"
    if ! printf '%s' "$summary" | awk '{ exit !($2 == $4 && $4 > 0) }'; then
      printf '%s\n' "$output" | grep -E -B2 -A15 'FAILED|rror' | head -80 >&2 || true
      status=1
    fi
  done
done

exit $status
