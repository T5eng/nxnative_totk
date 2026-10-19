#!/bin/bash
# A/B performance series on a connected iPhone.
#
# configs.txt: one line per candidate, "NAME|KEY=VALUE;KEY=VALUE" (an empty config is the baseline):
#   baseline|
#   canvas720|TOTK_IOS_CANVAS=1280x720
#   mfx30|TOTK_MFX=interp30
#
# usage: perf_ab.sh configs.txt [udid] [bundle-id]
# Needs: afcclient (libimobiledevice) for Documents access, devicectl for launch.
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:$PATH
CONFIGS="${1:?usage: perf_ab.sh configs.txt [udid] [bundle-id]}"
UDID="${2:-${TOTK_DEVICE_UDID:-}}"
BUNDLE="${3:-${TOTK_BUNDLE_ID:-com.example.totkios}}"
[ -n "$UDID" ] || { echo "need the device UDID (arg 2 or TOTK_DEVICE_UDID)"; exit 2; }
OUT="${TOTK_PERF_OUT:-$(pwd)/perf-results}"
mkdir -p "$OUT"
CSV="$OUT/results.csv"
[ -f "$CSV" ] || echo "config,frame_p50_ms,frame_p95_ms,submit_p50_ms,gpu_p50_ms,replay_cpu_ms,draws_per_frame,drops_of_300,footprint_mib" > "$CSV"

afc() { afcclient --udid "$UDID" --container "$BUNDLE" "$@"; }

while IFS='|' read -r name envs; do
    [ -z "${name:-}" ] && continue
    [ "${name:0:1}" = "#" ] && continue
    echo "=== $name ==="
    tmp=$(mktemp)
    printf 'TOTK_ALIAS_GIB=3\nTOTK_OPERATION_MODE=docked\nDM_PRESENT_HZ=60\nTOTK_ASYNC_REPLAY=1\nTOTK_AUTOLOAD=1\n' > "$tmp"
    [ -n "${envs:-}" ] && printf '%s\n' "$envs" | tr ';' '\n' >> "$tmp"
    printf 'rm Documents/env.txt\nput %s Documents/env.txt\nquit\n' "$tmp" | afc >/dev/null 2>&1
    rm -f "$tmp"
    xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE" >/dev/null 2>&1
    sleep 75   # boot + autoload (presses A until the save loads) + settle
    log="$OUT/$name.log"
    xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source Documents/log.txt --destination "$log" >/dev/null 2>&1
    frame=$(grep -a "计时 至帧" "$log" | tail -1)
    p50=$(printf '%s' "$frame" | sed -n 's/.*帧时间 p50 \([0-9.]*\).*/\1/p')
    p95=$(printf '%s' "$frame" | sed -n 's/.*p50 [0-9.]* \/ p95 \([0-9.]*\).*/\1/p')
    submit=$(printf '%s' "$frame" | sed -n 's/.*NVN 提交+出图 p50 \([0-9.]*\).*/\1/p')
    gpu=$(printf '%s' "$frame" | sed -n 's/.*GPU p50 \([0-9.]*\).*/\1/p')
    trans=$(grep -a "翻译 至帧" "$log" | tail -1)
    rcpu=$(printf '%s' "$trans" | sed -n 's/.*CPU \([0-9.]*\) ms.*/\1/p')
    draws=$(printf '%s' "$trans" | sed -n 's/.*每帧绘制 \([0-9]*\).*/\1/p')
    pres=$(grep -a "上屏 至帧" "$log" | tail -1)
    drops=$(printf '%s' "$pres" | sed -n 's/.*掉帧 \([0-9]*\).*/\1/p')
    fp=$(printf '%s' "$pres" | sed -n 's/.*footprint \([0-9]*\) MiB.*/\1/p')
    echo "$name,$p50,$p95,$submit,$gpu,$rcpu,$draws,$drops,$fp" >> "$CSV"
    echo "  frame $p50 / submit $submit / gpu $gpu / replay $rcpu ms / drops $drops"
done < "$CONFIGS"
echo "results: $CSV"
