# Porting notes

This file describes how the iOS application is put together and which runtime changes were needed. It is written as
documentation for maintaining the port, not as a build log.

## Data flow

```
 game modules (embedded in the app, remapped to guest addresses)
        │  guest code executes NN/NVN calls through an HLE switch
        ▼
 MacNativeGames runtime (Metal 4 replay) ──► CAMetalLayer
        ▲
 iOS shell: UIScene + UIView + game thread; env.txt; touch pad
```

* **Module embedding.** The three game modules (`main`, `subsdk0`, `sdk`) are stored in the executable as Mach-O
  sections (`__TOTKX,__<name>x0`, `__TOTK<name>W,__img`, `__TOTKX,__<name>x1`) and their SHA-256 digests are in
  `ios/Gen/ios_embed.h`. At startup the loader `vm_remap`s the text part, the writable data and the patch area back to
  the addresses the game expects, and verifies the digests. The `__TOTKX` segment must be mapped `r-x`; the linker flag
  `-Wl,-segprot,__TOTKX,r-x,r-x` does that.
* **Patches at build time.** iOS cannot write executable pages, so the game patches (real-time frame step, 60 FPS
  controller, 2K output) are applied to the rewritten modules on the Mac before they are embedded, and the iOS build
  only verifies their words (see `patches/0001-ios-port.patch`, `game_patches_v143.c`).
* **Shaders.** There is no translator on the phone. Variants the Mac has translated are shipped as `.metal` + `.json`
  plus a precompiled `arm64-iphoneos` `.metallib`; the `.variants` index of each shader lists the variants the runtime
  may reuse. A draw whose variant is missing is skipped and its request is written to
  `Documents/shader-requests/<variant>.json`; `ios/tools/fill_shaders.py` translates it on the Mac, compiles the
  metallib, updates the index and pushes the four files to the device.

## iOS-specific fixes (all in `patches/0001-ios-port.patch`)

1. **UIScene adoption.** iOS 26+ requires the scene lifecycle; without it UIKit stops the process at launch.
2. **`__TOTKX` segment protection.** A writable executable segment fails the loader's permission check after remapping.
3. **Guest address space.** iOS 27 keeps only about 6 GiB of usable virtual address space above `0x7000_0000_0000`
   (the lower 4–64 GiB window belongs to the system, a GPU/IOMMU reservation starts higher). The stack/heap block is
   therefore 3 GiB and the alias region 3 GiB, both taken with `VM_FLAGS_ANYWHERE` reservations (`services.c`).
   `TOTK_ALIAS_GIB` can lower the alias size further; `TOTK_APP_POOL` can lower the game's main heap.
4. **Output-resolution data page.** The build-time 2K output patch makes the game ask for a 2560×1440 swapchain and read
   its canvas size from a data page appended to the module image. The export did not initialise that page, so the game
   read a zero canvas, produced empty scissors and the screen stayed black. `patch_output_res()` initialises it at
   startup (`1920×1080` canvas, null renderer), the same state the Mac patch starts in.
5. **Precompiled iOS metallibs.** `newArgumentEncoderWithBufferIndex:` returns a zero-length encoder for MSL compiled
   on the device, which the runtime treats as a layout error. Shipping `arm64-iphoneos` metallibs for every variant
   avoids runtime MSL compilation entirely. `ios/tools/fill_shaders.py` recompiles them whenever a variant is added.
6. **`shader-requests` and the variants index.** A filled variant must also be added to `<shader>.variants`
   (`{"variant", "deps"}` entries); without that entry the runtime keeps treating it as missing and the phone asks for
   it again on every start.
7. **No background pipeline warm-up on iOS.** It reads `.metal` sources for variants that may only have a metallib and
   crashed; the iOS shell disables it (`DM_PSO_MANIFEST=off`, `TOTK_WARM_LIGHT=0`) and keeps the small startup pass
   that compiles the filled requests (`warm_filled`).
8. **Env-file timing.** The shell loads `Documents/env.txt` before starting the services that read their configuration
   once (input command channel, remote command queue, autoload); the process constructors run before any env file
   could be read.
9. **Input.** The Mac keyboard path is replaced by an on-screen pad (`Sources/touch_controls.m`) that feeds
   `runtime_touch_pad_set()`; physical controllers keep using GameController. `runtime_input_key_synthetic()` is what
   `TOTK_AUTOLOAD` uses to press A.
10. **Mac-side only fixes kept in the patch:** the 60 Hz timer fallback when `CVDisplayLink` is unavailable on macOS 27,
    and the hactool `Signature (FAIL)` filtering in `extract_update_romfs.py` (the six IVFC levels are the real check).

## Remote diagnostics

The shell (iOS build) reads command files from `Documents/cmds/*.txt` (executed and deleted; add `runtime/input.c`'s
`TOTK_CMD_DIR` support is part of the patch) and supports `threads`, `wshot <png>`, `shot <png>`, `passdump <n>`,
`hletrace <0|1|2>` and `framestep <ms>`. `Documents/input.txt` additionally takes `key <mac-keycode> <ms>` and
`down`/`up` lines. These are development aids; they are compiled in but cost nothing while unused.
