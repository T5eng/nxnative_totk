# Frame rate, stability and performance budget

This page collects the measurements taken during the port and the optimisation candidates in priority order. All numbers
come from the runtime's own per-300-frame statistics (`[nvn] 计时 …`, `翻译 …`, `上屏 …`) and from the Metal 4 replay.

## 1. How the numbers are produced

Every 300 presented frames the runtime logs one line each for:

* **frame time / work time** – p50 / p95 / max of the game frame, in ms;
* **NVN submit + present** – the game thread's recording and queue time;
* **GPU** – Metal command-buffer duration for the same window;
* **translation** – instructions per draw, instructions per frame, replay CPU time per frame, draws per frame;
* **on-screen** – presented frame count, dropped frames, p99, footprint.

On the iPhone the shell can additionally take the window picture (`Documents/cmds/wshot`), dump pass attachments
(`passdump`), or dump guest thread states (`threads`) while the game runs.

## 2. Baselines (same runtime, same save)

| Scenario | frame p50 | p95 | submit+present p50 | GPU p50 | replay CPU p50 | draws/frame | drops/300 |
|---|---|---|---|---|---|---|---|
| **Mac** M3 Pro, in-game, warm off, MFX off (uncapped) | **8.31 ms** (≈120 FPS) | 10.1 ms | 2.6 ms | 4.9 ms | 2.7 ms | 736 | — |
| **iPhone** light scene (title / light area) | **16.68 ms** (60 FPS) | 18.0 ms | 5.3 ms | 5.5 ms | 4.7 ms | 217 | 14 |
| **iPhone** heavy scene (in-game world) | **32.3–33.3 ms** (30 FPS) | 33.9 ms | 10.5–11.7 ms | ~9 ms | 11.6–12.1 ms | 1017–1021 | 166–227 |

Notes:

* The Mac has roughly a 2× headroom against 60 FPS; uncapped it runs at the display rate (120 Hz). With MetalFX frame
  interpolation enabled (key 2 / `TOTK_MFX`) the Mac measured 31 ms game frames and 20 ms GPU in the same area — the
  interpolated presentation is not free at the 2K output size.
* The iPhone's GPU is **not** the wall in the heavy scene (9 ms < 16.7 ms). The wall is the replay: ~11.6 ms CPU per
  frame plus ~10.5 ms submit/present on the game thread, serialised enough to miss the 16.7 ms budget, so the game
  itself switches to its 30 FPS interval.
* Replay cost per draw is ~11.4 µs on iPhone vs ~3.7 µs on the Mac (736 vs 1021 draws in different scenes). The
  translator reports ~0.46 cycles/instruction, i.e. the cost is per-draw state and argument encoding, not raw
  instruction interpretation.
* iPhone memory footprint stays at 2.1–2.4 GiB; the Mac footprint with MFX and 2K output reached ~3.5 GiB.
* Present stability follows frame time: at 60 FPS only ~5 % of presents are dropped; at 30 FPS the count rises because
  every late frame misses a vice tick (p99 50 ms).

## 3. Optimisation candidates, in priority order

### A. Canvas resolution on iPhone (`TOTK_IOS_CANVAS=<w>x<h>`)
The iOS shell writes the canvas size into the output data page (default 1920×1080). Lowering it to e.g. **1600×900** or
**1280×720** cuts the GPU pass cost roughly linearly (9 ms → ~5.5 / ~4 ms) while the host still upscales to the
drawable. This is the cheapest way to give the replay headroom for 60 FPS in heavy scenes; it is a visual trade-off and
must be A/B tested (see §4).

### B. MetalFX interpolation on iPhone (`TOTK_MFX=interp30`)
Render the game at its native 30 FPS and let MetalFX produce the intermediate frame, presenting 60. The heavy scene's
11.6 ms replay then has a 33 ms budget, the GPU stays at ~9 ms + interpolation, and presentation becomes smooth — the
same approach the Mac uses. It also removes the frame-rate/speed coupling, because the game stays in one mode. Risk: the
implementation requires `MTLFXFrameInterpolatorDescriptor supportsMetal4FX`; if the GPU rejects it the runtime stops with
an error. Test with `TOTK_MFX=interp30` and fall back to off.

### C. Replay CPU cost (both platforms, iPhone most)
The runtime exposes A/B switches for the expensive parts of the replay; each needs a same-save run:

| Switch | What it changes | Default |
|---|---|---|
| `TOTK_CHUNK_DRAWS=<n>` | draws per encoder chunk (75) — larger chunks mean fewer encoder state switches | 75 |
| `TOTK_ARG_EPOCH=1` | reuse argument blocks whose bindings did not change | off |
| `TOTK_DEFERRED_BINDS=1` | defer pipeline/state binds to the first draw that needs them | off |
| `TOTK_DISPATCH_REUSE=1` | reuse compute dispatch state | off |
| `TOTK_BARRIER_NARROW=1` / `TOTK_BARRIER_VIS` | narrow barrier scopes | on/varies |
| `TOTK_ACQ_SYNC=old` | fence the acquire to the newest submission (was slower on Mac) | new |

Measure `翻译 CPU` and `submit+present` per candidate. A 25–30 % replay reduction is enough for 60 FPS in the heavy
scene at 1080p.

### D. Present pacing and stability
* `DM_PRESENT_HZ=60` (iPhone default in our env) versus the display's 120 Hz: 120 Hz halves the submit-period budget
  but lets the game present more often; A/B this with the same save.
* `DM_PRESENT_INTERVAL=display` forces one present per tick — deviates from the original timing (game time would run
  fast) and is only for measurement.
* The dropped-present count is a direct function of frame time; after A/C this should drop by itself.

### E. macOS startup warm-up
The Mac warms ~19 000 items (8 925 shaders, 1 176 pipelines) at launch. With a cold Metal shader cache this took minutes
in our measurement, while `DM_PSO_MANIFEST=off TOTK_WARM_LIGHT=0` gives the first frame in **1.7 s** (shaders then
compile lazily during play). Candidates: keep the priority list warm but make the background warm opt-in, ship a
pre-warmed cache, or start with warm off and enable it once the session is idle. This is a startup-time, not a frame-time,
issue.

### F. Power and thermals (both)
Uncapped 120 FPS on the Mac and 60 FPS on the iPhone both draw much more power than the original 30 FPS target. For
handheld play the sensible default is the game's own interval (30 FPS in heavy areas) with the display link sized to the
content, or `TOTK_MFX=interp30` for smooth 60 at 30 FPS simulation cost.

## 4. How to run an A/B series

The iPhone is driven entirely through `Documents/env.txt` and the autoload path, so a series is:

1. write a config file with one `NAME|KEY=VALUE;KEY=VALUE` line per candidate;
2. `ios/tools/perf_ab.sh configs.txt <udid> <bundle-id>` — for each line it writes `env.txt`, launches the app, waits
   for autoload to enter the save, pulls `Documents/log.txt`, extracts the last `计时/翻译/上屏` lines into `results.csv`;
3. compare `frame p50`, `submit+present p50`, `GPU p50`, `replay CPU` and `drops/300`.

The script needs `afcclient` (libimobiledevice) for file push/pull and `devicectl` for installation/launch.

## 5. Status

The measurements above were taken before the device went offline for this analysis round; the iPhone A/B series
(canvas size, MetalFX, replay switches) is prepared but not executed. The `TOTK_IOS_CANVAS` switch itself is implemented
in the runtime patch.
