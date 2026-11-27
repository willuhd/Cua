#!/bin/bash
#
# Builds the two codec libraries dz links, into .agents/tools.
#
# Everything lands under .agents/tools so nothing is installed system-wide and a
# clean checkout reproduces the same build. Results are universal by default:
# the Intel client is half the product, so an arm64-only library is a build that
# runs on one machine and not the other.
#
#   ./scripts/build-codecs.sh            # universal (arm64 + x86_64)
#   ./scripts/build-codecs.sh --native   # just this machine, much faster
#   ./scripts/build-codecs.sh --force    # rebuild everything
#
# Tooling, none of it required in advance except cmake:
#   ninja  - release binary
#   meson  - Python module, installed with pip --target
#   nasm   - needed for the x86_64 slice's assembly

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/.agents/tools"
PROXY="https://gh-proxy.com"

DAV1D_VER="1.5.1"
SVT_VER="3.1.2"
NINJA_VER="1.13.1"
NASM_VER="2.16.03"

FORCE=0
UNIVERSAL=1
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --native) UNIVERSAL=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$T"
cd "$T"

note() { echo "  $*"; }

if [ "$FORCE" = 1 ] || [ ! -x ./ninja ]; then
  note "fetching ninja $NINJA_VER"
  curl -sSL -o ninja.zip "$PROXY/https://github.com/ninja-build/ninja/releases/download/v$NINJA_VER/ninja-mac.zip"
  unzip -oq ninja.zip && rm ninja.zip && chmod +x ninja
fi
export PATH="$T:$PATH"

if [ "$FORCE" = 1 ] || ! PYTHONPATH="$T/pylib" python3 -c 'import mesonbuild' 2>/dev/null; then
  note "installing meson into .agents/tools/pylib"
  python3 -m pip install --quiet --target "$T/pylib" meson
fi
meson() { PYTHONPATH="$T/pylib" python3 -m mesonbuild.mesonmain "$@"; }
export PYTHONPATH="$T/pylib"

if [ "$UNIVERSAL" = 1 ]; then
  if [ "$FORCE" = 1 ] || [ ! -x ./nasm ]; then
    note "fetching nasm $NASM_VER for the x86_64 slice"
    curl -sSL -o nasm.zip "https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VER/macosx/nasm-$NASM_VER-macosx.zip"
    unzip -oq nasm.zip && rm nasm.zip
    found="$(find . -maxdepth 2 -name nasm -type f | head -1)"
    cp "$found" ./nasm && chmod +x ./nasm
  fi
fi

build_dav1d_slice() {
  arch="$1"
  ( cd "dav1d-$DAV1D_VER"
    rm -rf "build-$arch"
    if [ "$arch" = "x86_64" ]; then
      # meson cannot take two -arch flags on one invocation, so the second
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
      CC=clang meson setup "build-$arch" --buildtype=release         --cross-file cross-x86_64.txt         -Denable_tests=false -Denable_tools=false -Dbitdepths=8 >/dev/null
    else
      CC=clang meson setup "build-$arch" --buildtype=release         -Denable_tests=false -Denable_tools=false -Dbitdepths=8 >/dev/null
    fi
    ninja -C "build-$arch" >/dev/null )
}

if [ "$FORCE" = 1 ] || [ ! -f "dav1d-$DAV1D_VER/build/src/libdav1d.dylib" ]; then
  note "building dav1d $DAV1D_VER"
  [ -d "dav1d-$DAV1D_VER" ] || {
    curl -sSL -o dav1d.tar.gz "$PROXY/https://github.com/videolan/dav1d/archive/refs/tags/$DAV1D_VER.tar.gz"
    tar xzf dav1d.tar.gz && rm dav1d.tar.gz
  }
  # Build the slices first and only replace the installed library once they
  # have both succeeded. A failed slice must not take the working one with it.
  rm -rf "dav1d-$DAV1D_VER/build-arm64" "dav1d-$DAV1D_VER/build-x86_64"
  if [ "$UNIVERSAL" = 1 ]; then
    for arch in arm64 x86_64; do
      note "  dav1d slice: $arch"
      build_dav1d_slice "$arch"
    done
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
  [ -d "SVT-AV1-$SVT_VER" ] || {
    curl -sSL -o svt.tar.gz "$PROXY/https://github.com/AOMediaCodec/SVT-AV1/archive/refs/tags/v$SVT_VER.tar.gz"
    tar xzf svt.tar.gz && rm svt.tar.gz
  }
  archs="arm64"
  [ "$UNIVERSAL" = 1 ] && archs="arm64;x86_64"
  ( cd "SVT-AV1-$SVT_VER"
    rm -rf build
    PATH="$T:$PATH" cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON -DBUILD_APPS=OFF -DENABLE_AVX512=OFF \
      -DCMAKE_OSX_ARCHITECTURES="$archs" >/dev/null
    PATH="$T:$PATH" ninja -C build >/dev/null )
fi

echo
echo "codecs ready in $T"
note "dav1d:   $(lipo -archs "dav1d-$DAV1D_VER/build/src/libdav1d.7.dylib")"
note "SVT-AV1: $(lipo -archs "SVT-AV1-$SVT_VER/Bin/Release/libSvtAv1Enc.3.dylib")"
