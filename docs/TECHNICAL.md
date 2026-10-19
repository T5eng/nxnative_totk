# Key technical points

This is the condensed engineering record of the port: how the pieces fit and which details matter when changing it.

## 1. Structure

```
 iOS app (this repo)                          MacNativeGames runtime (patched)
 ┌─────────────────────────────┐              ┌────────────────────────────────────┐
 │ UIKit: UIScene, UIView,     │   guest      │ HLE: NN/NVN calls -> command       │
 │ CAMetalLayer, touch pad     │   modules    │ records -> MTL4 replay -> CAMetal- │
 │ game thread (64 MiB stack)  │ ───────────► │ Layer; audio; input; fs; services  │
 │ loader: remap + verify      │              │ Mac: translates shaders on demand  │
 └─────────────────────────────┘              └────────────────────────────────────┘
```

The game's own code executes; nothing is reimplemented. Only the platform below it is translated.

## 2. Guest modules inside the app

* Three modules (`main`, `subsdk0`, `sdk`) are embedded as Mach-O sections:
  `__TOTKX,__<name>x0` (text, `r-x`), `__TOTK<name>W,__img` (writable data and patch area, `rw`),
  `__TOTKX,__<name>x1` (the live patch area inside the text range, `r-x`).
* Layout per module (from `runtime_tables.h`): `x0 = page_up(text_end)`, `w` starts at `patch_off`, the image ends at
  `page_up(file_size)`, and a 16 KiB **data page** (`page_up(file_size)`, `page_up+0x4000`) is appended for the runtime
  patches (frame step, output resolution).
* The loader (`loader.c`) `vm_remap`s the parts back to their original offsets and checks SHA-256 digests from
  `ios_embed.h`. The linker flags `-Wl,-segprot,__TOTKX,r-x,r-x` and `…W,rw,rw` give the sections the protections the
  verification expects.
* The modules are exported by the Mac runtime with `export-ios` (`TOTK_EXPORT_IOS=<dir>`); game patches are applied
  **before** the export, because iOS cannot make text pages writable.

## 3. NVN → Metal 4 replay

* Every guest NVN call is recorded into a command buffer; the replay thread interprets it against Metal 4
  (`MTL4CommandQueue`, `MTL4CommandBuffer`, `MTL4RenderCommandEncoder`).
* Render passes: attachments are resolved from the guest render-target state; views, levels/slices, clears, layered
  passes, occlusion queries and conditional rendering are reproduced. The render target is a real Metal texture that
  guest code can also sample later.
* Shader constants: the game's c0/c1/c2 driver segments are scanned per shader; the replay fills the storage-buffer
  table, uniform table, thread-group counts, point size and texture/sampler handles from the command state.
* Argument buffers: the reflection (`.json`) says which argument block (`abi`) a function uses; the replay builds the
  block contents directly from the guest bindings and hands them over as a Metal buffer, rather than going through an
  `MTLArgumentEncoder` for every draw.
* Residency, deferred releases and a GPU budget (`TOTK_GPU_BUDGET_MB`) keep the working set bounded; textures are
  uploaded from guest memory lazily and re-uploaded when the guest writes to them.

## 4. Shaders: variants, cache and the iOS toolchain

* A **variant** is identified by `<shader sha256>-<sha256(answers)[0..6]>_b`. The answers are the draw state that changes
  the translation: texture types per slot (`tex`), image types/formats (`img`), vertex attribute types (`attr`),
  fragment output types (`fout`), optionally thread-group size (`local`), and `depth_minus_w`.
* Cache files per variant: `.metal` (MSL), `.json` (reflection: chain, entry, bindings, deps, c1), `.metallib`
  (precompiled), and per shader `<shader>.variants` (array of `{variant, deps}` — the lookup table the runtime uses).
* The Mac runtime translates on demand through `totk_xlate --service` + `spirv-cross`. The phone has neither, so:
  * a missing variant skips its draws and writes `shader-requests/<variant>.json` (contains the guest Maxwell code as
    `code_hex`, the c1 bytes and all answers);
  * `ios/tools/fill_shaders.py` replays the request through the Mac service, compiles
    `xcrun -sdk iphoneos metal/metallib`, appends the variant to the `.variants` index and pushes the four files.
* **Why precompiled metallibs are mandatory:** MSL compiled on the device yields a zero-length argument encoder for these
  argument-buffer shaders (`newArgumentEncoderWithBufferIndex:` → `encodedLength = 0`), which the runtime rejects as a
  layout error. Offline `arm64-iphoneos` metallibs carry the reflection the runtime expects.
* **Why the `.variants` index matters:** without the entry the runtime never considers the variant present, even when
  all its files are on disk — it requests it again on every start.

## 5. Frame pacing and game time

* Presentation goes through `CAMetalDisplayLink` on the layer; presents are paced by display ticks. The game's own
  `nvnWindowSetPresentInterval` value changes the ticks per frame (`1` = every tick, `2` = every second tick). The Mac
  defaults to the game's interval (`DM_PRESENT_INTERVAL=game`); `display` forces one frame per tick (deviates from the
  original timing semantics).
* The real-time frame-step patch replaces seven guarded instructions and a producer veneer: the veneer feeds the game a
  step value from the module data page instead of the nominal `60/FPS` interval. The runtime samples the wall clock on
  every present (mean of the last five deltas, clamped to 1/120…1/15 s) and stores the step in three unit conventions
  (`×30`, `×1`, `×60`) used by different consumers. `TOTK_REALTIME=0` disables the patch, `framestep <ms>` pins the step.
* **MetalFX interpolation (30 FPS game + one interpolated frame).** The runtime needs, per game frame, the scene colour,
the UI layer, the G-buffer depth and the camera. Scene completion is normally detected by a fixed list of UI vertex-shader
key prefixes (`mfx_ui_vs`). Areas that use different UI shaders made detection stop, which is why interpolation only
covered ~50% of frames in the castle-underground area. `TOTK_MFX_UIDIAG=1` logs the vertex/fragment keys and draw state
of the canvas draws that fail detection, and a state-based fallback now also accepts "a blended draw with depth testing
off after the canvas has already been drawn into several times this frame" as the start of the UI
(`TOTK_MFX_UI_FALLBACK=0` turns it off).
* **Open issue:** the game keeps a `0.5 / 1.0` half-step selector that it applies after this value, depending on its
  internal 60/30 fps mode bit. Because the runtime feeds a real per-frame delta, the selector makes world time advance at
  `delta × selector` when the game switches modes, so character/animation speed fluctuates with the frame rate. The
  fix direction is to remove the selector compensation in the build-time veneer and re-export the modules; it is not
  done in this revision.

## 5b. HDR / EDR output (prototype)

The game renders internally in HDR: the scene target is `RG11B10Float`, the UI layer is `RGBA16Float` (the MFX path
already captures both), and the game's own tone-map shader PQ-encodes the composite through a 32³ LUT into 8-bit SDR.
The port presents that SDR picture.

`TOTK_HDR=1` switches the iOS present path to an extended-range (EDR) drawable:

* the `CAMetalLayer` is created with `pixelFormat = RGBA16Float`, `wantsExtendedDynamicRangeContent = YES` and the
  extended linear sRGB colour space;
* the present pipeline gets an HDR variant (`present_pipeline_hdr`): the game's sRGB picture is converted to linear light
  and multiplied by `TOTK_HDR_GAIN` (default 1.8), so SDR white maps to 1.8× white and the display's HDR headroom is
  actually used. The same selection is made in the MTL4 present encoder (mixing a BGRA8 pipeline with a 16F drawable
  crashed the GPU driver).

This is the container half of HDR: the content is still the game's SDR tone-mapped picture, brightness-expanded. True HDR
needs the present stage to consume the game's HDR scene (`RG11B10Float`) and UI (`RGBA16Float`) and tone-map them itself
(ACES/PQ with exposure) instead of the game's 8-bit output; the MFX path already has both textures, and the exposure hook
(`dm_bright_k()`, `TOTK_BRIGHT`) is in place. With interpolation on, the EDR path adds no GPU cost in the tested scene
(MFX GPU p50 unchanged at ~8.5 ms, frame p50 33.4 ms).

## 6. iOS address space and guest memory

Measured on iOS 27 / iPhone Air:

* The usable high virtual-address window is only about **6 GiB above `0x7000_0000_0000`**. The `4…64 GiB` range is
  occupied by the system and the process's frameworks, and from roughly `0x7180_0000_0000` upward a GPU/IOMMU
  reservation blocks large mappings.
* The guest address limit for HIPC is `2^39` (`0x8000_0000_0000`), so the 6 GiB window is usable but nothing above it.
* Layout: one contiguous reservation holds a **3 GiB stack/heap block** (stack 256 MiB, heap at `+0x3000_0000`, heap cap
  4 GiB reported) and a **3 GiB alias region** (`TOTK_ALIAS_GIB=3`; smaller sizes are tried in 1 GiB steps). The
  reservation is taken with `VM_FLAGS_ANYWHERE` and checked against `2^39`; fixed mappings in the low window fail with
  `KERN_NO_SPACE`/`KERN_INVALID_ADDRESS` on iOS 27.
* The game's main heap is `APP_POOL − program − VAM`; with `TOTK_APP_POOL` at the retail 3.2 GiB it is ~2.13 GiB.
  `TOTK_APP_POOL` can lower it if the phone runs out of memory.

## 7. The black screen post-mortem (worth knowing before changing the output path)

The exported `main` had the **2K output patch applied at build time** (2560×1440 swapchain immediates and a
display-config veneer), but the data page the veneer reads was zero. The game therefore published a canvas of size
`0×0`, every draw's scissor came out empty, and only clears and the post-processing chain ran — the engine kept
presenting black frames at full speed. Fix (`game_patches_v143.c`, iOS branch): initialise
`page + DP_OUTPUT_SIZE = pack_size(1920, 1080)` and `page + DP_RENDERER = 0` at load time, the state the Mac patch starts
with in auto mode. The data page layout: `+0` step (×30 units), `+8` interval (×60 units), `+32` output size (packed
`h<<32|w`), `+40` renderer pointer.

## 8. Async replay (the 60 FPS switch)

`TOTK_ASYNC_REPLAY=1` queues submits and presents to a dedicated translation thread; the game thread records and returns,
so game logic of the next frame overlaps replay + Metal encoding of the current one. Fences become "translated and GPU
done"; destroys/reads that need Metal state drain the queue first; the thread is raised to a real-time constraint for the
present period. Measured in the same scene: frame time p50 22.9 ms (≈43 FPS) → **16.67 ms (60 FPS)**; NVN submit p50
14.0 → ~6–10 ms. The iOS shell enables it by default.

## 9. Verification tooling

* `Documents/cmds/*.txt` command queue (executed and deleted): `threads`, `wshot <png>`, `shot <png>`,
  `passdump <n>`, `hletrace 0|1|2`, `framestep <ms>`.
* `Documents/input.txt`: `key <mac-keycode> <ms>` / `down` / `up`; `TOTK_AUTOLOAD=1` uses the same synthetic key path.
* Runtime diagnostics used during the bring-up (environment variables, on the Mac too): `DM_NVN_PASSDUMP`,
  `DM_NVN_LIFELOG`, `DM_NVN_REGLUM`, `DM_NVN_TEXPNG(_FS)`, `DM_NVN_SHOT(_FRAME)`, `DM_NVN_UB`, `TOTK_TRACE_SVC`,
  `TOTK_MEM_LOG`, `TOTK_SHMAP`.
* `shader-requests/` plus `done/` is the shader work queue: `done/` means the startup pass compiled it successfully.

## 10. Known limitations

* World speed is tied to the game's internal frame-rate mode (section 5) — the next fix.
* Present pacing jitters: the heavy scenes drop presents (p99 ~50 ms); the game itself asks for 30 FPS in heavy areas
  (the Switch original targets 30 FPS), light scenes hold 60.
* The touch pad is functional but ergonomics are basic (fixed layout, no per-device scaling/opacity settings).
* Save data lives under `Documents/user-data/save/<slot>` and `Documents/profile/save`; there is no iCloud/export path.
