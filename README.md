# Tears of the Kingdom v1.4.3 — iOS native port

Run **The Legend of Zelda: Tears of the Kingdom (Switch, v1.4.3)** natively on iPhone.
The graphics translation layer is [MacNativeGames](https://github.com/ly05010419/MacNativeGames) (MIT): it replays the
game's NVN command streams on Metal. This repository contains the **iOS application shell**, the **runtime patches** that
make that layer work on iOS/iPhone hardware, and the tooling to prepare the shader cache.

Status: playable on iPhone Air (iPhone18,4), iOS 27.0.1 — boot, title screen, save load, in-game rendering, audio,
touch controls. Frame rate follows the game's own present interval (60 FPS in light scenes, 30 FPS in heavy scenes, which
is the original Switch target).

**This repository contains no game data.** No ROM/ XCI, no extracted RomFS, no fonts, no shaders and no keys are
distributed here; you need your own legally obtained copy of the game and its update, and you must dump it yourself.

## Layout

| Path | What it is |
|---|---|
| `ios/` | The Xcode application (Sources, project.yml, generated-file tooling) |
| `patches/0001-ios-port.patch` | Changes to MacNativeGames that are required on iOS (applied to a checkout of it) |
| `docs/PORTING.md` | How the port works: architecture and the iOS-specific fixes |
| `docs/MACOS.md` | Building/running the macOS version with the same patch (and its macOS 27 fixes) |
| `docs/TECHNICAL.md` | Key technical points: module embedding, NVN→Metal replay, shader variants, pacing, address space, async replay |
| `docs/PERFORMANCE.md` | Measured frame times on Mac/iPhone, bottlenecks and the A/B optimisation plan |
| `ios/README.md` | Full iOS build and device-setup instructions |

## How it works (short version)

* The game's executable modules are **embedded into the iOS app** as Mach-O sections and remapped to their original
  guest addresses by the loader (`__TOTKX`/`__TOTK*W` segments).
* The MacNativeGames runtime turns every NVN call into a Metal 4 replay: render passes, buffers, textures, compute.
* iOS has no on-device shader translator, so the game's shader variants are translated on the Mac, compiled to
  **arm64-iphoneos metallibs**, and copied to the phone (`ios/tools/fill_shaders.py`).
* The iOS shell provides what UIKit needs (UIScene, CAMetalLayer), a game thread with a large stack, the on-screen
  touch controls, and an env-file based configuration channel.

See `docs/PORTING.md` for the details.

The same runtime patch also repairs the **macOS** build (macOS 27 guest-address-space and display-link changes); see
`docs/MACOS.md`.

## Requirements

* macOS 26/27 with Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen)
* A checkout of MacNativeGames (patched, see `patches/`) that has already produced the Mac build data:
  rewritten game modules, extracted RomFS, and the build tables
* `opus` and `libvpx` cross-compiled for `arm64-apple-ios` (instructions in `ios/README.md`)
* Your own game files: the v1.4.3 update applied to the base game, dumped RomFS, and the shared fonts

## Configuration on the device

`Documents/env.txt` (one `KEY=VALUE` per line) is read at launch; `/` marks the useful ones:

```
TOTK_ALIAS_GIB=3        # guest alias size in GiB (iOS 27 leaves ~6 GiB of high VA)
TOTK_OPERATION_MODE=docked
DM_PRESENT_HZ=60        # display link rate
TOTK_ASYNC_REPLAY=1     # replay on a separate thread (needed for 60 FPS)
TOTK_AUTOLOAD=1         # press A at the title and load the newest save automatically
TOTK_TOUCH_UI=0         # hide the on-screen controls (they are on by default)
TOTK_IOS_CANVAS=1280x720  # iOS only: game canvas size (default 1920x1080); lower = cheaper GPU
TOTK_MFX=interp30       # optional: render at the game's 30 FPS, MetalFX interpolates to 60
```

## Touch controls

Left half of the screen = left stick (move), right half = right stick (camera); A/B/X/Y at the bottom right,
L/ZL and R/ZR at the top corners, +/− at the top centre, d-pad at the bottom left. Physical controllers (MFi/Bluetooth)
work at the same time through GameController.

## Credits and license

* Runtime: [MacNativeGames](https://github.com/ly05010419/MacNativeGames) (MIT).
* iOS application shell, runtime patches and tooling in this repository: MIT, see `LICENSE`.
* The Legend of Zelda: Tears of the Kingdom is a trademark of Nintendo. This project is not affiliated with Nintendo and
  ships no game code or assets.
