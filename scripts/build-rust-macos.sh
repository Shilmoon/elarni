#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_LOCK=""
DOMAIN_HEADER_TMP=""
PACKET_HEADER_TMP=""
cleanup() {
  [ -z "$DOMAIN_HEADER_TMP" ] || rm -f "$DOMAIN_HEADER_TMP"
  [ -z "$PACKET_HEADER_TMP" ] || rm -f "$PACKET_HEADER_TMP"
  [ -z "$BUILD_LOCK" ] || rmdir "$BUILD_LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
RUN_ID=${1:-}
DEV_MODE=0
PROFILE=release
if [ "$RUN_ID" = "--dev" ] || [ "$RUN_ID" = "--dev-release" ]; then
  DEV_MODE=1
  [ "$RUN_ID" != "--dev" ] || PROFILE=native-dev
  RUN_ID=""
fi
if [ "$#" -gt 1 ]; then
  printf '%s\n' "usage: $0 [--dev|--dev-release|RUN_ID]" >&2
  exit 2
fi
case "$RUN_ID" in
  *[!A-Za-z0-9._-]*) printf '%s\n' "invalid artifact run id" >&2; exit 2 ;;
esac
if [ "$DEV_MODE" -eq 1 ]; then
  DEV_ROOT="$ROOT/.build/rust-macos"
elif [ -n "$RUN_ID" ]; then
  RUN_ROOT="$ROOT/artifacts/runs/$RUN_ID"
  DOMAIN_OUTPUT="$RUN_ROOT/elarni-domain/ElarniDomain.xcframework"
  PACKET_OUTPUT="$RUN_ROOT/elarni-packet-bridge/ElarniPacketBridge.xcframework"
else
  DOMAIN_OUTPUT="$ROOT/artifacts/elarni-domain/ElarniDomain.xcframework"
  PACKET_OUTPUT="$ROOT/artifacts/elarni-packet-bridge/ElarniPacketBridge.xcframework"
fi

BUILD_LOCK_PATH="$ROOT/.build/.rust-macos-dev.lock"
mkdir -p "$ROOT/.build"
if ! mkdir "$BUILD_LOCK_PATH"; then
  printf '%s\n' "Rust build is already running" >&2
  exit 2
fi
BUILD_LOCK="$BUILD_LOCK_PATH"

if [ "$DEV_MODE" -eq 0 ] && { [ -e "$DOMAIN_OUTPUT" ] || [ -e "$PACKET_OUTPUT" ]; }; then
  printf '%s\n' "immutable artifact output already exists" >&2
  exit 2
fi

cd "$ROOT"
DOMAIN_HEADER_TMP=$(mktemp "$ROOT/include/.elarni_ffi.XXXXXX")
PACKET_HEADER_TMP=$(mktemp "$ROOT/include/.elarni_packet_bridge.XXXXXX")
"$ROOT/.toolchains/cbindgen/bin/cbindgen" \
  --config native/elarni-domain/cbindgen.toml \
  --crate elarni-domain \
  --output "$DOMAIN_HEADER_TMP"
"$ROOT/.toolchains/cbindgen/bin/cbindgen" \
  --config native/elarni-packet-bridge/cbindgen.toml \
  --crate elarni-packet-bridge \
  --output "$PACKET_HEADER_TMP"
cargo build --profile "$PROFILE" --locked --target aarch64-apple-darwin \
  --target-dir "$ROOT/target" -p elarni-domain -p elarni-packet-bridge
if cmp -s "$DOMAIN_HEADER_TMP" include/elarni_ffi.h; then
  rm -f "$DOMAIN_HEADER_TMP"
else
  mv "$DOMAIN_HEADER_TMP" include/elarni_ffi.h
fi
if cmp -s "$PACKET_HEADER_TMP" include/elarni_packet_bridge.h; then
  rm -f "$PACKET_HEADER_TMP"
else
  mv "$PACKET_HEADER_TMP" include/elarni_packet_bridge.h
fi
DOMAIN_HEADER_TMP=""
PACKET_HEADER_TMP=""

[ "$(lipo -archs "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_domain.a")" = arm64 ]
[ "$(lipo -archs "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_packet_bridge.a")" = arm64 ]

if [ "$DEV_MODE" -eq 1 ]; then
  DOMAIN_HASH=$(shasum -a 256 "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_domain.a" | awk '{print $1}')
  PACKET_HASH=$(shasum -a 256 "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_packet_bridge.a" | awk '{print $1}')
  GENERATION=$(printf '%s%s' "$DOMAIN_HASH" "$PACKET_HASH" | shasum -a 256 | awk '{print $1}')
  GENERATION_ROOT="$DEV_ROOT/generations/$GENERATION"
  mkdir -p "$DEV_ROOT/generations"
  if [ ! -d "$GENERATION_ROOT" ]; then
    STAGING_ROOT=$(mktemp -d "$DEV_ROOT/generations/.build.XXXXXX")
    cp "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_domain.a" "$STAGING_ROOT/libelarni_domain.a"
    cp "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_packet_bridge.a" "$STAGING_ROOT/libelarni_packet_bridge.a"
    mv "$STAGING_ROOT" "$GENERATION_ROOT"
  fi
  cmp "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_domain.a" "$GENERATION_ROOT/libelarni_domain.a"
  cmp "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_packet_bridge.a" "$GENERATION_ROOT/libelarni_packet_bridge.a"
  if [ "$(readlink "$DEV_ROOT/current" 2>/dev/null || true)" != "generations/$GENERATION" ]; then
    NEXT_LINK="$DEV_ROOT/.current.$$"
    ln -s "generations/$GENERATION" "$NEXT_LINK"
    # Xcode pre-creates the declared output directory in a fresh checkout; mv would nest the link inside it.
    [ -L "$DEV_ROOT/current" ] || [ ! -d "$DEV_ROOT/current" ] || rmdir "$DEV_ROOT/current"
    mv -fh "$NEXT_LINK" "$DEV_ROOT/current"
  fi
  printf '%s\n' "built $DEV_ROOT/current"
  exit 0
fi

mkdir -p "$(dirname "$DOMAIN_OUTPUT")" "$(dirname "$PACKET_OUTPUT")"
xcodebuild -create-xcframework \
  -library "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_domain.a" \
  -headers "$ROOT/include" \
  -output "$DOMAIN_OUTPUT"
xcodebuild -create-xcframework \
  -library "$ROOT/target/aarch64-apple-darwin/$PROFILE/libelarni_packet_bridge.a" \
  -headers "$ROOT/include" \
  -output "$PACKET_OUTPUT"

[ "$(lipo -archs "$DOMAIN_OUTPUT/macos-arm64/libelarni_domain.a")" = arm64 ]
[ "$(lipo -archs "$PACKET_OUTPUT/macos-arm64/libelarni_packet_bridge.a")" = arm64 ]

printf '%s\n' "built $DOMAIN_OUTPUT"
printf '%s\n' "built $PACKET_OUTPUT"
