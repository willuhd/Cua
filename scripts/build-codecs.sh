#!/bin/bash
#
# Builds the two codec libraries dz links, into .agents/tools.
#
# Everything lands under .agents/tools so nothing is installed system-wide and
# a clean checkout can reproduce the exact build. Re-running is cheap: each
# step is skipped once its result exists.
#
#   ./scripts/build-codecs.sh            # build whatever is missing
#   ./scripts/build-codecs.sh --force    # rebuild everything
#
# Tools used, none of them required in advance:
#   ninja  - fetched as a release binary
#   meson  - a Python module, installed with pip --target
#   cmake  - taken from PATH if present (SVT-AV1 only needs it)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$ROOT/.agents/tools"
PROXY="https://gh-proxy.com"

DAV1D_VER="1.5.1"
SVT_VER="3.1.2"
NINJA_VER="1.13.1"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$T"
cd "$T"

note() { printf '  %s\n' "$*"; }

# --- ninja -----------------------------------------------------------------
if [ "$FORCE" = 1 ] || [ ! -x ./ninja ]; then
  note "fetching ninja $NINJA_VER"
  curl -sSL -o ninja.zip "$PROXY/https://github.com/ninja-build/ninja/releases/download/v$NINJA_VER/ninja-mac.zip"
  unzip -oq ninja.zip && rm ninja.zip && chmod +x ninja
fi
export PATH="$T:$PATH"

# --- meson -----------------------------------------------------------------
if [ "$FORCE" = 1 ] || ! PYTHONPATH="$T/pylib" python3 -c 'import mesonbuild' 2>/dev/null; then
  note "installing meson into $T/pylib"
  python3 -m pip install --quiet --target "$T/pylib" meson
fi
meson() { PYTHONPATH="$T/pylib" python3 -m mesonbuild.mesonmain "$@"; }
# dav1d's build re-invokes meson for its version header, so it must be importable.
export PYTHONPATH="$T/pylib"

# --- dav1d -----------------------------------------------------------------
if [ "$FORCE" = 1 ] || [ ! -f "dav1d-$DAV1D_VER/build/src/libdav1d.dylib" ]; then
  note "building dav1d $DAV1D_VER"
  [ -d "dav1d-$DAV1D_VER" ] || {
    curl -sSL -o dav1d.tar.gz "$PROXY/https://github.com/videolan/dav1d/archive/refs/tags/$DAV1D_VER.tar.gz"
    tar xzf dav1d.tar.gz && rm dav1d.tar.gz
  }
  ( cd "dav1d-$DAV1D_VER"
    rm -rf build
    # 8-bit only, no tests: we have a client and no test suite to satisfy.
    CC=clang meson setup build --buildtype=release -Denable_tests=false \
      -Denable_tools=false -Dbitdepths=8 >/dev/null
    ninja -C build >/dev/null )
fi

# --- SVT-AV1 ---------------------------------------------------------------
if [ "$FORCE" = 1 ] || [ ! -f "SVT-AV1-$SVT_VER/Bin/Release/libSvtAv1Enc.dylib" ]; then
  note "building SVT-AV1 $SVT_VER"
  [ -d "SVT-AV1-$SVT_VER" ] || {
    curl -sSL -o svt.tar.gz "$PROXY/https://github.com/AOMediaCodec/SVT-AV1/archive/refs/tags/v$SVT_VER.tar.gz"
    tar xzf svt.tar.gz && rm svt.tar.gz
  }
  ( cd "SVT-AV1-$SVT_VER"
    rm -rf build
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
      -DBUILD_APPS=OFF -DENABLE_AVX512=OFF >/dev/null
    ninja -C build >/dev/null )
fi

echo
echo "codecs ready in $T"
note "dav1d:   dav1d-$DAV1D_VER"
note "SVT-AV1: SVT-AV1-$SVT_VER"
echo
echo "compile flags for a local build:"
echo "  -I $T/dav1d-$DAV1D_VER/include"
echo "  -I $T/SVT-AV1-$SVT_VER/Source/API"
echo "  -L $T/dav1d-$DAV1D_VER/build/src -ldav1d"
echo "  -L $T/SVT-AV1-$SVT_VER/Bin/Release -lSvtAv1Enc"
