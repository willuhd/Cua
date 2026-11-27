# dmgbuild settings for the dz distributable DMG.
# Values decoded from the design build (~/Downloads/Disk Image.dmg, mounted
# at /Volumes/dz) — ground truth is the built image's .DS_Store, not the
# DMG Canvas document (documents drift from what ships).
#
# Decode notes:
# - .background/dmgcanvas_bg.tiff: 1328x848 @144dpi = 664x424 pt.
# - Iloc (top-origin Finder coords): dz.app (146,171), Applications (459,171).
#   dmgbuild measures y from the bottom: 360 - 171 = 189.
# - icvo blob 'nonebotm' -> label position bottom; trailing icon size 128.
# - icvt (shor) = 13 -> label font size.
# - fwi0 (120,200,480,800) -> window 600x360. Size window_rect to match the
#   design (the bg bleeds past it; that is how the design build looks).

import os

_here = defines.get("assets_dir")  # noqa: F821  (defined by dmgbuild)
if not _here:
    raise SystemExit(
        "error: run dmgbuild with -D assets_dir=/path/to/.github/release"
    )

# Injected by make-dmg.sh as -D app_path=/path/to/App.app
app_path = defines.get("app_path")  # noqa: F821  (defined by dmgbuild)
if not app_path:
    raise SystemExit(
        "error: run dmgbuild with -D app_path=/path/to/App.app"
    )

app_name = os.path.basename(app_path)

# ---------------------------------------------------------------------------
# Contents
# ---------------------------------------------------------------------------
files = [app_path]

symlinks = {"Applications": "/Applications"}

# ---------------------------------------------------------------------------
# Finder window (decoded from the built design image)
# ---------------------------------------------------------------------------
window_rect = ((200, 100000), (600, 360))  # ((x, y), (w, h)); y is bottom-origin idiom

default_view = "icon-view"
icon_size = 128     # from icvo (design build)
text_size = 13      # from icvt (design build)
label_pos = "bottom"  # 'botm' in icvo

icon_locations = {  # from Iloc, raw Finder coords (dmgbuild stores them verbatim)
    app_name: (146, 171),
    "Applications": (459, 171),
}

# ---------------------------------------------------------------------------
# Background (flattened composite extracted from the design build)
# ---------------------------------------------------------------------------
background = os.path.join(_here, "dmg-background.tiff")

# Deliberately left at dmgbuild defaults (HFS+/UDZO, universally readable).
