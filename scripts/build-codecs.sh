#!/bin/bash
#
# Builds the two codec libraries dz links, as universal binaries.
#
# This script installs nothing. It needs cmake, ninja, meson, nasm and curl on
# PATH and says so plainly when one is missing, because which package manager
# provides them is a property of the machine, not of this repository.
#
#   ./scripts/build-codecs.sh            # universal (arm64 + x86_64)
#   ./scripts/build-codecs.sh --native   # just this machine, much faster
#   ./scripts/build-codecs.sh --force    # rebuild everything
#
# Sources are fetched into .agents/tools, which is ignored by git. If fetching
# from GitHub directly does not work, point DZ_MIRROR at a prefix:
#   DZ_MIRROR=https://gh-proxy.com/ ./scripts/build-codecs.sh

set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/.agents/tools"
MIRROR="$DZ_MIRROR"

DAV1D_VER="1.5.1"
SVT_VER="3.1.2"

FORCE=0
UNIVERSAL=1
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --native) UNIVERSAL=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

note() { echo "  $*"; }

missing=""
for tool in cmake ninja meson curl tar; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ "$UNIVERSAL" = 1 ] && ! command -v nasm >/dev/null 2>&1; then
  missing="$missing nasm"
fi
if [ -n "$missing" ]; then
  echo "error: missing build tools:$missing" >&2
  echo >&2
  echo "Install them however this machine does that. On macOS with Homebrew:" >&2
  echo "  brew install cmake ninja meson nasm" >&2
  exit 1
fi

mkdir -p "$T"
cd "$T"

build_dav1d_slice() {
  arch="$1"
  ( cd "dav1d-$DAV1D_VER"
    rm -rf "build-$arch"
    if [ "$arch" = "x86_64" ]; then
      # meson cannot take two -arch flags in one invocation, so the second
      # slice is described by a cross file instead.
      cat > cross-x86_64.txt <<'CROSS'
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
CROSS
      CC=clang meson setup "build-$arch" --buildtype=release \
        --cross-file cross-x86_64.txt \
        -Denable_tests=false -Denable_tools=false -Dbitdepths=8 >/dev/null
    else
      CC=clang meson setup "build-$arch" --buildtype=release \
        -Denable_tests=false -Denable_tools=false -Dbitdepths=8 >/dev/null
    fi
    ninja -C "build-$arch" >/dev/null )
}

if [ "$FORCE" = 1 ] || [ ! -f "dav1d-$DAV1D_VER/build/src/libdav1d.dylib" ]; then
  note "building dav1d $DAV1D_VER"
  if [ ! -d "dav1d-$DAV1D_VER" ]; then
    curl -sSL -o dav1d.tar.gz "$MIRROR""https://github.com/videolan/dav1d/archive/refs/tags/$DAV1D_VER.tar.gz"
    tar xzf dav1d.tar.gz && rm dav1d.tar.gz
  fi
  # Slices are built before the installed library is replaced, so a failed
  # slice cannot take a working one with it.
  rm -rf "dav1d-$DAV1D_VER/build-arm64" "dav1d-$DAV1D_VER/build-x86_64"
  if [ "$UNIVERSAL" = 1 ]; then
    note "  arm64"
    build_dav1d_slice arm64
    note "  x86_64"
    build_dav1d_slice x86_64
    mkdir -p "dav1d-$DAV1D_VER/build/src"
    lipo -create "dav1d-$DAV1D_VER/build-arm64/src/libdav1d.7.dylib" \
                 "dav1d-$DAV1D_VER/build-x86_64/src/libdav1d.7.dylib" \
                 -output "dav1d-$DAV1D_VER/build/src/libdav1d.7.dylib.new"
  else
    build_dav1d_slice arm64
    mkdir -p "dav1d-$DAV1D_VER/build/src"
    cp "dav1d-$DAV1D_VER/build-arm64/src/libdav1d.7.dylib" \
       "dav1d-$DAV1D_VER/build/src/libdav1d.7.dylib.new"
  fi
  mv -f "dav1d-$DAV1D_VER/build/src/libdav1d.7.dylib.new" \
        "dav1d-$DAV1D_VER/build/src/libdav1d.7.dylib"
  ln -sf libdav1d.7.dylib "dav1d-$DAV1D_VER/build/src/libdav1d.dylib"
  rm -rf "dav1d-$DAV1D_VER/build-arm64" "dav1d-$DAV1D_VER/build-x86_64"
fi

if [ "$FORCE" = 1 ] || [ ! -f "SVT-AV1-$SVT_VER/Bin/Release/libSvtAv1Enc.3.dylib" ]; then
  note "building SVT-AV1 $SVT_VER"
  if [ ! -d "SVT-AV1-$SVT_VER" ]; then
    curl -sSL -o svt.tar.gz "$MIRROR""https://github.com/AOMediaCodec/SVT-AV1/archive/refs/tags/v$SVT_VER.tar.gz"
    tar xzf svt.tar.gz && rm svt.tar.gz
  fi
  archs="arm64"
  [ "$UNIVERSAL" = 1 ] && archs="arm64;x86_64"
  ( cd "SVT-AV1-$SVT_VER"
    rm -rf build
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON -DBUILD_APPS=OFF -DENABLE_AVX512=OFF \
      -DCMAKE_OSX_ARCHITECTURES="$archs" >/dev/null
    ninja -C build >/dev/null )
fi

echo
echo "codecs ready in $T"
note "dav1d:   $(lipo -archs "dav1d-$DAV1D_VER/build/src/libdav1d.7.dylib")"
note "SVT-AV1: $(lipo -archs "SVT-AV1-$SVT_VER/Bin/Release/libSvtAv1Enc.3.dylib")"
