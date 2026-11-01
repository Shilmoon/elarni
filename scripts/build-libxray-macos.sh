#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GO="${ELARNI_GO:-$ROOT/.toolchains/go/bin/go}"
TOOLCHAIN=auto
[ -z "${ELARNI_GO:-}" ] || TOOLCHAIN=local
SOURCE="$ROOT/Vendor/libXray"
BUILD="$ROOT/.build/libxray-macos-arm64"
OUTPUT="$ROOT/artifacts/libxray/LibXray.xcframework"
DEV_MODE=0
TAGS=darwin
case "${1:-}" in
  --dev) DEV_MODE=1 ;;
  --diagnostics) DEV_MODE=1; BUILD="$BUILD-diagnostics"; TAGS=darwin,elarni_diagnostics ;;
  "") ;;
  *) printf '%s\n' "usage: $0 [--dev|--diagnostics]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2
# A build made with the connection recording option (ELARNI_RECORDING=1) compiles the recorder.
[ "${ELARNI_RECORDING:-}" != 1 ] || TAGS="$TAGS,elarni_recording"

if [ "$DEV_MODE" -eq 0 ] && [ -d "$OUTPUT" ]; then
  printf '%s\n' "existing immutable artifact: $OUTPUT"
  exit 0
fi

mkdir -p "$BUILD"
LOCK="$ROOT/.build/.libxray-macos.lock"
if ! mkdir "$LOCK"; then
  printf '%s\n' "development Go build is already running" >&2
  exit 2
fi
STAGING=""
cleanup() {
  [ -z "$STAGING" ] || rm -rf "$STAGING"
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
STAGING=$(mktemp -d "$BUILD/.build.XXXXXX")
SDK=$(xcrun --sdk macosx --show-sdk-path)
FLAGS="-isysroot $SDK -mmacosx-version-min=13.0 -arch arm64"

(
  cd "$SOURCE"
  GOWORK="$ROOT/go.work" \
  GOTOOLCHAIN="$TOOLCHAIN" \
  GOOS=darwin \
  GOARCH=arm64 \
  GOFLAGS="-tags=$TAGS" \
  CC='xcrun --sdk macosx --toolchain macosx clang' \
  CXX='xcrun --sdk macosx --toolchain macosx clang++' \
  CGO_CFLAGS="$FLAGS" \
  CGO_CXXFLAGS="$FLAGS" \
  CGO_LDFLAGS="$FLAGS -Wl,-Bsymbolic-functions" \
  CGO_ENABLED=1 \
  DARWIN_SDK=macosx \
  "$GO" build -mod=readonly -trimpath -ldflags '-s -w -buildid=' \
    -buildmode=c-archive -o "$STAGING/libXray.a" ./cgo_bridge
)

GOWORK="$ROOT/go.work" GOTOOLCHAIN="$TOOLCHAIN" GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 GOFLAGS="-tags=$TAGS" \
  "$GO" build -mod=readonly -trimpath -ldflags '-s -w -buildid=' \
    -o "$STAGING/elarni-core" "$SOURCE/cmd/elarni-core"

for file in libXray.a libXray.h elarni-core; do
  if ! cmp -s "$STAGING/$file" "$BUILD/$file"; then
    mv "$STAGING/$file" "$BUILD/$file"
  fi
done

if [ "$DEV_MODE" -eq 1 ]; then
  printf '%s\n' "built $BUILD/libXray.a"
  exit 0
fi

mkdir -p "$ROOT/artifacts/libxray"

xcodebuild -create-xcframework \
  -library "$BUILD/libXray.a" \
  -headers "$BUILD" \
  -output "$OUTPUT"

printf '%s\n' "built $OUTPUT"
