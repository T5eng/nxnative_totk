# macOS build (the same patch also fixes the Mac side)

The runtime patch in `patches/0001-ios-port.patch` is not iOS-only: three of its changes exist because macOS 27 broke
assumptions the original MacNativeGames build made. This page describes how to build and run the Mac version with the
patch applied, and which macOS-specific fixes it contains.

## macOS-specific fixes in the patch

1. **No fixed 64 GiB alias region at `0x70_0000_0000`.** macOS 27 (26A428) places a randomised multi-GiB reservation
   inside that range, so the fixed 64 GiB mapping fails. `runtime/services.c` now scans the 39-bit space from
   `0x70_0000_0000` for the largest GiB-aligned window and reserves stack/heap + alias in one `VM_FLAGS_FIXED` mapping,
   reporting the size actually obtained to the game. (`TOTK_ALIAS_GIB` caps the requested size.)
2. **No `CVDisplayLink`.** `CVDisplayLinkCreateWithActiveCGDisplays` fails on macOS 27; `runtime/frontend.m` falls back to
   a 60 Hz timer thread that signals the same vsync events.
3. **hactool signature noise.** `scripts/extract_update_romfs.py` ignores hactool's `Signature (FAIL)` lines for the
   NPDM / fixed-key signature blobs — they are expected on a dumped update; the six IVFC levels are the real integrity
   check. Without this, a perfectly valid RomFS extraction was rejected.

Everything else in the patch is shared with the iOS build (command channel, output-res data page, loader export).

## Build

```sh
git clone https://github.com/ly05010419/MacNativeGames
cd MacNativeGames
git apply /path/to/nxnative_totk/patches/0001-ios-port.patch

brew install opus libvpx
# build_app.py wants a python3.14 on /opt/homebrew/bin or /usr/local/bin; e.g.
uv python install 3.14 && ln -sf "$(uv python find 3.14)" /opt/homebrew/bin/python3.14

python3 build_app.py --game totk --version 1.4.3          # see the project README for the exact options
open "Tears of the Kingdom.app"
```

The first build also produces the data the iOS build consumes: `rewritten/v143/*.patched.bin`, `build/v143/*.h`,
`build/pso_manifest.tsv` and the RomFS extraction. Point `TOTK_BUILD_WORK` at that work directory for the iOS build
(see `ios/README.md`).

## Where things live on the Mac

| Path | Content |
|---|---|
| `~/Applications/Tears of the Kingdom.app` | the built application |
| `~/Library/Application Support/MacNativeGames/TOTK/` | profile, game slot, shader cache (`shader-cache/rt-totk-native-v4-unverified`) |
| `~/Library/Logs/MacNativeGames/totk.log` | the runtime's stderr (all diagnostics) |
| `<app>/Contents/Resources/totk/build/` | runtime binary, `totk_xlate` translator service, `spirv-cross` |

## Runtime environment

The Mac launcher (`app/launcher.m`) sets these by default; they are the same switches the iOS shell writes into
`Documents/env.txt`:

```
TOTK_PROFILE_DIR, TOTK_GAME_SLOT_DIR, TOTK_SHADER_CACHE
TOTK_ROMFS_PROOF_DIR        data directory (the app bundle stays read-only)
TOTK_GPU_ALLOW_SUBMIT=1     required: without it the graphics layer records but never submits
TOTK_GPU_WIDEN=1
TOTK_GPU_BLOCKRT=1
TOTK_GPU_MIDCLEAR=1
TOTK_GPU_BUDGET_MB=5000
```

Ad-hoc environment overrides can be injected through launchd before `open`:

```sh
launchctl setenv DM_NVN_PASSDUMP 600      # pass dump at frame 600
launchctl setenv DM_NVN_LIFELOG 1600x896  # lifetime log of the textures of that size
open -a "Tears of the Kingdom"
launchctl unsetenv DM_NVN_PASSDUMP
```

## Diagnostics channel

`~/Library/Application Support/MacNativeGames/TOTK/input.txt` accepts commands while the game runs (append a line):

```
shot <path with no spaces>      # the next presented frame as PNG
wshot <path>                   # the window picture including the FPS box
threads                        # every guest thread's wait state and guest return chain
passdump <n>                   # full attachment/draw dump for the next n frames
framestep <ms>                 # pin the frame step (0 = real time)
hletrace <0|1|2>               # count / log the host calls the game makes
```

## Mac vs iOS

| | macOS | iOS |
|---|---|---|
| Graphics | same Metal 4 replay | same, but `__TOTKX` must be `r-x` and modules are embedded in the app |
| Guest memory | dynamic fixed window from `0x70_0000_0000` | ANYWHERE reservations, 3 GiB heap + 3 GiB alias (`TOTK_ALIAS_GIB`) |
| Shaders | translated on demand by `totk_xlate` + `spirv-cross` | translated on the Mac, shipped as iphoneos metallibs |
| Pacing | `CVDisplayLink` or 60 Hz timer fallback | `CAMetalDisplayLink` on the layer |
| Input | keyboard + GameController | touch pad + GameController, `TOTK_AUTOLOAD` |
| Game data | inside the app bundle / support directory | `Documents/` (RomFS parts, fonts, shader cache) |
