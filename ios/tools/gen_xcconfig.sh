#!/bin/bash
# Generates ios/Gen/ios.xcconfig (include paths, frameworks, the embedded-module segment protections).
# All paths can be overridden from the environment; the defaults use the repository layout:
#   third_party/MacNativeGames   the patched runtime checkout
#   work/                        the MacNativeGames build work directory (build/v143 tables, build/libs)
#   work/ios-deps                opus / libvpx cross-built for arm64-iphoneos
set -euo pipefail
M="$(cd "$(dirname "$0")/.." && pwd)"                       # ios/
ROOT="$(cd "$M/.." && pwd)"                                 # repository root
SRC="${TOTK_MNG_SRC:-$ROOT/third_party/MacNativeGames/games/totk}"
W="${TOTK_BUILD_WORK:-$ROOT/work}"
DEPS="${TOTK_IOS_DEPS:-$ROOT/work/ios-deps}"
VPX="${TOTK_LIBVPX_SRC:-$DEPS/libvpx-1.15.0}"
mkdir -p "$M/Gen"
if [ -f "$W/build/pso_manifest.tsv" ]; then cp "$W/build/pso_manifest.tsv" "$M/Gen/pso_manifest.tsv"; fi
printf '# TOTK control-code-sha256-v1\n' > "$M/Gen/shader-map.tsv"
cat > "$M/Gen/ios.xcconfig" <<XCC
HEADER_SEARCH_PATHS = \$(inherited) "$SRC/runtime" "$SRC/third_party/d2r_gfx/gfx/nvn" "$SRC/third_party/d2r_gfx/gfx/nvn/include" "$SRC/third_party/d2r_gfx/gfx/tex" "$W/build/v143" "$W/build" "$M/Gen" "$DEPS/prefix-ios/include" "$DEPS/prefix-ios/include/opus" "$VPX"
OTHER_CFLAGS = \$(inherited) -DTOTK_GAME_V143=1 -Wno-unused-parameter -Wno-unused-function
OTHER_LDFLAGS = \$(inherited) -framework UIKit -framework Foundation -framework QuartzCore -framework Metal -framework MetalFX -framework AudioToolbox -framework CoreAudio -framework CoreVideo -framework CoreText -framework CoreGraphics -framework GameController -framework CoreHaptics -framework CoreMotion -framework ImageIO -framework UniformTypeIdentifiers -framework AVFoundation "$DEPS/prefix-ios/lib/libopus.a" "$DEPS/prefix-ios/lib/libvpx.a" -Wl,-segprot,__TOTKmainW,rw,rw -Wl,-segprot,__TOTKsubsdk0W,rw,rw -Wl,-segprot,__TOTKsdkW,rw,rw -Wl,-segprot,__TOTKX,r-x,r-x
XCC
echo "wrote $M/Gen/ios.xcconfig"
