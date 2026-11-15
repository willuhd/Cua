#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $(basename "$0") <App.app> <output.dmg>" >&2
    exit 2
fi

DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-Cua}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT_DIR="$(cd "$(dirname "$2")" && pwd)"
OUT="$OUT_DIR/$(basename "$2")"

[ -d "$APP" ] || { echo "error: app bundle not found: $APP" >&2; exit 1; }
[ -f "$HERE/dmg-background.tiff" ] || {
    echo "error: missing background: $HERE/dmg-background.tiff" >&2
    exit 1
}

find_dmgbuild() {
    local c p
    for c in dmgbuild "$HOME/.local/bin/dmgbuild" \
             /opt/homebrew/bin/dmgbuild /usr/local/bin/dmgbuild; do
        if command -v "$c" >/dev/null 2>&1; then
            command -v "$c"
            return 0
        fi
    done
    for p in "$HOME"/Library/Python/*/bin/dmgbuild; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

DMGBUILD="$(find_dmgbuild)" || {
    echo "error: dmgbuild not found. Install it with: pipx install dmgbuild" >&2
    exit 1
}

echo "using dmgbuild: $DMGBUILD"
echo "app:            $APP"
echo "output:         $OUT"

rm -f "$OUT"

"$DMGBUILD" \
    -s "$HERE/dmgbuild_settings.py" \
    -D "app_path=$APP" \
    -D "assets_dir=$HERE" \
    "$DMG_VOLUME_NAME" \
    "$OUT"

codesign --force --sign - "$OUT"
codesign --verify --verbose=2 "$OUT" || true

echo "built: $OUT"
ls -lh "$OUT"
