#!/usr/bin/env python3
"""Translate the variants an iOS session recorded under Documents/shader-requests.

The phone has no shader translator: a missing variant skips its draws and writes the complete translation request
(<variant>.json with the guest Maxwell code as hex) for this script, which runs the Mac translator service
(totk_xlate --service) into the cache, compiles the IPHONEOS metallib the iOS runtime loads, and can push all three
files back to the device with afcclient.

  python3 fill_shaders.py --requests /tmp/reqs --cache ~/Library/.../rt-totk-native-v4-unverified \
      [--xlate <totk_xlate>] [--spirv-cross <spirv-cross>] [--chain totk-native-v4-unverified] [--push --udid UDID]
"""
import argparse, json, os, subprocess, sys, tempfile

MAC_APP = os.environ.get("TOTK_MAC_APP", os.path.expanduser("~/Applications/Tears of the Kingdom.app/Contents/Resources/totk/build"))
DEFAULT_XLATE = os.path.join(MAC_APP, "shader-service/totk_xlate")
DEFAULT_SPIRV = os.path.join(MAC_APP, "spirv-cross/spirv-cross")


def compile_metallib(metal: str, out: str) -> bool:
    with tempfile.TemporaryDirectory() as t:
        air = os.path.join(t, "x.air")
        r = subprocess.run(["xcrun", "-sdk", "iphoneos", "metal", "-c", metal, "-o", air],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(f"metal failed {os.path.basename(metal)}: {r.stderr[:300]}\n")
            return False
        r = subprocess.run(["xcrun", "-sdk", "iphoneos", "metallib", air, "-o", out],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(f"metallib failed {os.path.basename(out)}: {r.stderr[:300]}\n")
            return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--requests", required=True, help="directory with the <variant>.json requests")
    ap.add_argument("--cache", required=True, help="runtime shader cache (rt-<chain>) on the Mac")
    ap.add_argument("--xlate", default=DEFAULT_XLATE)
    ap.add_argument("--spirv-cross", default=DEFAULT_SPIRV)
    ap.add_argument("--chain", default="totk-native-v4-unverified")
    ap.add_argument("--push", action="store_true", help="copy the three files of every filled variant to the device")
    ap.add_argument("--udid", default=os.environ.get("TOTK_DEVICE_UDID"))
    ap.add_argument("--bundle", default=os.environ.get("TOTK_BUNDLE_ID", "com.example.totkios"))
    a = ap.parse_args()

    reqs = sorted(f for f in os.listdir(a.requests) if f.endswith(".json"))
    if not reqs:
        print("no requests")
        return 0
    proc = subprocess.Popen([a.xlate, "--service", "--spirv-cross", a.spirv_cross,
                             "--out", a.cache, "--chain", a.chain],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    filled, failed = [], []
    for name in reqs:
        req = json.load(open(os.path.join(a.requests, name)))
        variant = req["variant"]
        code = os.path.join(a.cache, variant + ".code")
        with open(code, "wb") as f:          # the guest Maxwell code, as bytes (the service reads it raw)
            f.write(bytes.fromhex(req.get("code_hex", "")))
        job = {k: req[k] for k in ("variant", "stage", "c1", "tex", "img", "attr", "fout", "local", "depth_minus_w") if k in req}
        if req.get("stage") == "cs" and "local" not in job:
            job["local"] = [1, 1, 1]
        job["code"] = code
        proc.stdin.write(json.dumps(job) + "\n")
        proc.stdin.flush()
        reply = json.loads(proc.stdout.readline())
        if not reply.get("ok"):
            failed.append((variant, reply.get("error")))
            continue
        metal = os.path.join(a.cache, variant + "_b.metal")
        lib = os.path.join(a.cache, variant + "_b.metallib")
        if not compile_metallib(metal, lib):
            failed.append((variant, "iphoneos metallib"))
            continue
        # The runtime finds variants through <shader>.variants (totk_shader_rt.m variants_of): [{variant, deps}]. Without
        # the entry the phone requests the same variant on every start even though all three files are in the cache.
        shader = variant.rsplit("-", 1)[0]
        try:
            with open(os.path.join(a.cache, variant + "_b.json")) as f:
                deps = json.load(f).get("deps", {})
        except (OSError, ValueError):
            deps = {}
        idx_path = os.path.join(a.cache, shader + ".variants")
        try:
            with open(idx_path) as f:
                idx = json.load(f)
            if not isinstance(idx, list):
                idx = []
        except (OSError, ValueError):
            idx = []
        idx = [e for e in idx if e.get("variant") != variant]
        idx.append({"variant": variant, "deps": deps})
        with open(idx_path, "w") as f:
            json.dump(idx, f, sort_keys=True, separators=(",", ":"))
        filled.append(variant)
    proc.stdin.close()
    proc.wait()

    print(f"filled {len(filled)}, failed {len(failed)}")
    for v, e in failed:
        print("  FAIL", v, e)

    if a.push and not a.udid:
        raise SystemExit("--push needs the device UDID (--udid or TOTK_DEVICE_UDID)")
    if a.push and filled:
        stage = "/tmp/fillpush"           # afcclient splits arguments on spaces, and the cache path has one
        os.makedirs(stage, exist_ok=True)
        lines = []
        shutil = __import__("shutil")
        for v in filled:
            for suffix in ("_b.metal", "_b.json", "_b.metallib"):
                src = os.path.join(a.cache, v + suffix)
                dst = os.path.join(stage, v + suffix)
                if os.path.exists(src):
                    shutil.copyfile(src, dst)
                    lines.append(f"put -f {dst} Documents/shader-cache/rt-{a.chain}/{v}{suffix}")
            idx = os.path.join(a.cache, v.rsplit("-", 1)[0] + ".variants")
            if os.path.exists(idx):
                dst = os.path.join(stage, "idx-" + v.rsplit("-", 1)[0] + ".variants")
                shutil.copyfile(idx, dst)
                lines.append(f"put -f {dst} Documents/shader-cache/rt-{a.chain}/{v.rsplit('-', 1)[0]}.variants")
        lines.append("quit")
        r = subprocess.run(["afcclient", "--udid", a.udid, "--container", a.bundle],
                           input="\n".join(lines) + "\n", text=True, capture_output=True)
        errs = [l for l in (r.stdout + r.stderr).splitlines() if "Error" in l]
        print(f"pushed {len(filled)} variants, afc errors {len(errs)}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
