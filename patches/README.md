# Runtime patch

`0001-ios-port.patch` applies to a clean checkout of
[MacNativeGames](https://github.com/ly05010419/MacNativeGames) (`git apply patches/0001-ios-port.patch` from the
checkout root). It contains everything the iOS build needs from the runtime side:

| File | Change |
|---|---|
| `runtime/services.c` | iOS 27 guest address space: ANYWHERE reservations for a 3 GiB stack/heap block + 3 GiB alias region; macOS 27 dynamic window fallback |
| `runtime/game_patches_v143.c` | Initialises the 2K output patch's data page on iOS (black-screen fix); verifies build-time patched words |
| `runtime/loader.c` | iOS export also writes the live patch area as `<name>.x1.bin` |
| `runtime/input.c` | Env-file independent start of the command channel; remote command queue (`TOTK_CMD_DIR`); reopen support for a file replaced over AFC |
| `runtime/autoload.c` | `runtime_autoload_start()` for shells that read their env file after the constructors |
| `runtime/runtime.h` | Declarations for the two entry points above |
| `runtime/frontend.m` | 60 Hz timer fallback when `CVDisplayLink` is unavailable (macOS 27) |
| `third_party/d2r_gfx/gfx/nvn/nvn_mtl.m` | MSL 3.0 for on-device compilation; does not crash on a warm-up shader without source; pass-without-targets accounting |
| `scripts/extract_update_romfs.py` | Ignores hactool's `Signature (FAIL)` lines; the six IVFC levels are the integrity check |

Apply, then build MacNativeGames' Mac application once to produce the work directory used by the iOS build
(see `ios/README.md`).
