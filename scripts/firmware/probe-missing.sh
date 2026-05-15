#!/usr/bin/env bash
# scripts/firmware/probe-missing.sh
#
# 在已解压的 ImageBuilder workdir 里跑 `make manifest` dry-run,把 IB 算依赖
# 闭包时报的 `(no such package)` / `conflicts:` 反向解析成结构化清单。
#
# 这是 manifest sidecar diff (scripts/firmware/analyze-diff.sh) 的取代方案 —
# IB 才是依赖闭包的权威:
#   - sidecar manifest 只有包名列表,看不到 depends/conflicts 反向依赖,
#     无法发现 libatomic1 / iptables 这类被反向依赖拉进来的缺包。
#   - device profile 的 DEVICE_PACKAGES 是 makefile 字段而非 .config 行,
#     manifest 看不见。
#   - DEFAULT_PACKAGES 的冲突包(wpad-basic-mbedtls vs wpad-openssl)只能在
#     IB apk add 时才暴露。
#
# `make manifest` (上游 target/imagebuilder/files/Makefile:366-372) 跑完整
# package_install (apk add) 但跳过 prepare_rootfs / build_image,缺包冲突
# 都会触发 apk 报错。
#
# 用法:
#   firmware/probe-missing.sh \
#       --workdir <IB_ROOT>          必填,已解压(且 prepare-repo 完毕)的 IB 根
#       --device-config <FILE>       必填,device 种子 .config
#       --output <FILE>              必填,JSON 数组:missing 包名清单
#       [--conflicts <FILE>]         可选,文本清单:冲突包名 (去版本)
#
# 退出码:
#   0   探测完成 (可能 missing=0,也可能 missing>0 — 都算正常)
#   1   make manifest 失败且未抓到 missing/conflict (真错,需排查)
#   2   参数错

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/extract-config.sh
source "$SCRIPT_DIR/../lib/extract-config.sh"

WORKDIR=""
DEVICE_CONFIG=""
OUTPUT=""
CONFLICTS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)        WORKDIR="$2"; shift 2 ;;
        --device-config)  DEVICE_CONFIG="$2"; shift 2 ;;
        --output)         OUTPUT="$2"; shift 2 ;;
        --conflicts)      CONFLICTS="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::firmware/probe-missing: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$WORKDIR"       ] || { echo "::error::probe-missing: 缺 --workdir"       >&2; exit 2; }
[ -n "$DEVICE_CONFIG" ] || { echo "::error::probe-missing: 缺 --device-config" >&2; exit 2; }
[ -n "$OUTPUT"        ] || { echo "::error::probe-missing: 缺 --output"        >&2; exit 2; }

WORKDIR="$(cd "$WORKDIR" && pwd)"
DEVICE_CONFIG="$(cd "$(dirname "$DEVICE_CONFIG")" && pwd)/$(basename "$DEVICE_CONFIG")"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
[ -n "$CONFLICTS" ] && { mkdir -p "$(dirname "$CONFLICTS")"; CONFLICTS="$(cd "$(dirname "$CONFLICTS")" && pwd)/$(basename "$CONFLICTS")"; }

[ -f "$WORKDIR/Makefile" ] || { echo "::error::probe-missing: $WORKDIR 不像 IB 根 (缺 Makefile)" >&2; exit 1; }
[ -f "$DEVICE_CONFIG"    ] || { echo "::error::probe-missing: $DEVICE_CONFIG 不存在" >&2; exit 1; }

PROFILE=$(extract_profile "$DEVICE_CONFIG")
PACKAGES=$(extract_packages "$DEVICE_CONFIG" | tr '\n' ' ')

[ -n "$PROFILE" ] || { echo "::error::probe-missing: 无法从 $DEVICE_CONFIG 提取 PROFILE" >&2; exit 1; }

echo "::group::probe-missing: make manifest PROFILE=$PROFILE"
echo "PROFILE:  $PROFILE"
echo "PACKAGES: $PACKAGES"
echo "::endgroup::"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "$WORKDIR"
set +e
make manifest PROFILE="$PROFILE" PACKAGES="$PACKAGES" \
    1> "$tmp/manifest.txt" 2> "$tmp/err.log"
rc=$?
set -e

echo "::group::make manifest exit code: $rc"
echo "--- stdout 前 20 行 (apk query 结果或为空):"
head -20 "$tmp/manifest.txt" 2>/dev/null || true
echo "--- stderr 中的错误片段:"
grep -E '\(no such package\)|conflicts:|unable to select' "$tmp/err.log" 2>/dev/null \
    | head -30 || echo "(stderr 中无 apk 关键错误)"
echo "::endgroup::"

# 解析 missing.
# apk-tools 错误格式样例:
#   ERROR: unable to select packages:
#     kmod-hwmon-pwmfan (no such package):
#       required by: world[kmod-hwmon-pwmfan]
#     libatomic1 (no such package):
#       required by: libusb-1.0-0-1.0.29-r1[libatomic1]
: > "$tmp/missing.txt"
grep '(no such package)' "$tmp/err.log" 2>/dev/null \
    | sed -E 's/^[[:space:]]+([^[:space:]]+) \(no such package\).*/\1/' \
    | grep -vE '^[[:space:]]*$|[[:space:]]' \
    | sort -u > "$tmp/missing.txt" || true

missing_n="$(wc -l < "$tmp/missing.txt" | tr -d ' ')"
echo "probe-missing: IB 报缺 $missing_n 个包"
[ "$missing_n" -gt 0 ] && sed 's/^/  - /' "$tmp/missing.txt"

# JSON 产出
if [ "$missing_n" -gt 0 ]; then
    jq -R . < "$tmp/missing.txt" | jq -s -c . > "$OUTPUT"
else
    echo "[]" > "$OUTPUT"
fi
echo "missing JSON: $(cat "$OUTPUT")"

# 解析 conflicts (可选).
# apk-tools conflict 格式样例:
#   wpad-basic-mbedtls-2026.04.02~b004de0b-r1:
#     conflicts: wpad-openssl-2026.04.02~b004de0b-r1[hostapd=...]
#     satisfies: world[wpad-basic-mbedtls]
conflict_n=0
if [ -n "$CONFLICTS" ]; then
    : > "$CONFLICTS"
    awk '
        # "<pkg-with-version>:" 单独成行 (前可有空格)
        /^[[:space:]]+[^[:space:]]+:[[:space:]]*$/ {
            cur = $0
            sub(/^[[:space:]]+/, "", cur)
            sub(/:[[:space:]]*$/, "", cur)
            next
        }
        # 下一行是 "conflicts:" 才认定 cur 为 conflict 主体
        /^[[:space:]]+conflicts:[[:space:]]/ && cur != "" {
            print cur
        }
    ' "$tmp/err.log" \
    | sed -E 's/-[0-9].*$//' \
    | sort -u > "$CONFLICTS" || true
    conflict_n="$(wc -l < "$CONFLICTS" | tr -d ' ')"
fi
if [ "$conflict_n" -gt 0 ]; then
    echo "probe-missing: 检测到 $conflict_n 个 conflict 包 (应在 device .config 用 '# is not set' 排除):"
    sed 's/^/  - /' "$CONFLICTS"
fi

# make manifest 失败但什么都没抓到 → 真错
if [ $rc -ne 0 ] && [ "$missing_n" -eq 0 ] && [ "$conflict_n" -eq 0 ]; then
    echo "::error::probe-missing: make manifest 失败但未抓到 missing/conflict — 见 stderr 上方,排查 IB 状态"
    sed -n '1,80p' "$tmp/err.log" >&2
    exit 1
fi

exit 0
