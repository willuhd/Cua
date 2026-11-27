//
//  CodecBridge.h
//  dz
//
//  One C surface for the two codec libraries dz links. Swift reaches these
//  through the bridging header; nothing else in the app includes them.
//
//  Both are built from source by scripts/build-codecs.sh so the whole app is
//  reproducible from a clean checkout, and both are pinned there.
//

#pragma once

#include <dav1d/data.h>
#include <dav1d/dav1d.h>
#include <EbSvtAv1.h>
#include <EbSvtAv1Enc.h>
