# Building the iOS app

The app links the patched MacNativeGames runtime statically and embeds the game's three modules as Mach-O sections.
Everything under `Gen/` except `TOTK.entitlements` is generated from your own copy of the game; it is not in the
repository.

## Expected repository layout

```
third_party/MacNativeGames/     # git checkout + ../../patches/0001-ios-port.patch applied
work/                           # MacNativeGames build work directory (see below)
work/ios-deps/                  # opus / libvpx for arm64-iphoneos
ios/                            # this directory
```

## 1. Patched runtime checkout

```sh
git clone https://github.com/ly05010419/MacNativeGames third_party/MacNativeGames
cd third_party/MacNativeGames
git apply ../../patches/0001-ios-port.patch
```

## 2. Mac build data (done once on the Mac)

Follow MacNativeGames' own instructions (`build_app.py`, README there) to build the Mac application for
**The Legend of Zelda: Tears of the Kingdom v1.4.3**. That produces the inputs used here; point `TOTK_BUILD_WORK` at the
resulting work directory. Required artifacts:

* `rewritten/v143/main.patched.bin`, `subsdk0.patched.bin`, `sdk.patched.bin` — patched guest modules
* `build/v143/runtime_tables.h`, `build/v143/romfs_config.h` — module table used by the loader
* `build/shared_fonts_config.h`, `build/pso_manifest.tsv`
* an **iOS export directory** with `<name>.x0.bin` / `<name>.x1.bin` for each module; these are produced by the runtime's
  `export-ios` command (the patch makes `loader.c` write the live patch area as `<name>.x1.bin` as well)

## 3. iOS dependencies

Cross-compile `libopus` and `libvpx` for `arm64-apple-ios` (no assembly needed) and install them into
`work/ios-deps/prefix-ios`; keep the libvpx source tree at `work/ios-deps/libvpx-1.15.0` for its headers. The linker
line in `Gen/ios.xcconfig` expects `prefix-ios/lib/libopus.a`, `prefix-ios/lib/libvpx.a`, `prefix-ios/include`, and the
libvpx source directory. Override the paths with `TOTK_IOS_DEPS` / `TOTK_LIBVPX_SRC` if you keep them elsewhere.

## 4. Generate and build

```sh
cd ios
TOTK_BUILD_WORK=../work ./tools/gen_xcconfig.sh

python3 tools/gen_embed.py \
    "$TOTK_BUILD_WORK/build/v143/runtime_tables.h" \
    "$TOTK_BUILD_WORK/rewritten/v143" \
    "$TOTK_BUILD_WORK/export-ios" \
    Gen

xcodegen generate
xcodebuild -project TOTK.xcodeproj -scheme TOTK -configuration Release \
    -sdk iphoneos -destination generic/platform=iOS -allowProvisioningUpdates build
```

`xcodegen` regenerates `TOTK.xcodeproj` from `project.yml`, so re-run it when files are added. Set your own
`PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` in `project.yml` (or in Xcode) before building for a device.

Install and launch:

```sh
xcrun devicectl device install app --device <UDID> <DerivedData>/Build/Products/Release-iphoneos/TOTK.app
xcrun devicectl device process launch --console --device <UDID> com.example.totkios
```

## 5. Data on the device

The app reads everything relative to its own `Documents` directory; the game files are your responsibility:

```
Documents/
  env.txt                       # see the repository README
  extracted/v143/romfs/         # runtime-index.bin + romfs.bin or romfs.bin.000…
  shared-fonts/                 # the six .bfttf files
  shader-cache/rt-<chain>/      # .metal, .json, .metallib, .variants
```

`romfs.bin` can be split into `romfs.bin.000`, `romfs.bin.001`, … with a 2 GiB part size (`split -b 2048m -d -a 3`);
every part except the last must have the same size. The runtime verifies the RomFS image on first start.

`afcclient` from libimobiledevice is convenient for large trees:

```sh
afcclient --udid <UDID> --container <bundle-id>   # interactive: put -rf <local> Documents/<path>
```

## 6. Shader cache

The phone has no translator: a missing variant skips its draws and writes `Documents/shader-requests/<variant>.json`.
Translate and push them from the Mac:

```sh
python3 tools/fill_shaders.py --requests <dir with the request JSONs> \
    --cache "$HOME/Library/Application Support/MacNativeGames/TOTK/shader-cache/rt-<chain>" \
    --push --udid <UDID> --bundle <bundle-id>
```

The script runs the Mac translator service (`totk_xlate` + `spirv-cross`, by default from the Mac app bundle), compiles
the `arm64-iphoneos` metallib, updates the shader's `.variants` index and pushes all four files. Relaunch the app so the
startup pass imports them. Repeat until `shader-requests` stays empty.
