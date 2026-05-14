#!/usr/bin/env bash
# scripts/firmware/analyze-diff.sh
#
# 计算「设备需要 - (Tier1 IB 内置 ∪ Tier2 Pool 已有)」的缺失包名集合。
# 取代旧 scripts/ci/analyze-diff.sh:不再 docker run,改为从 workflow 已下载到
# 本地的 manifest 文件读取。下载 manifest 的职责放在 workflow (gh release
# download / curl),这里只做纯 diff,跨 workflow 复用更稳。
#
# 用法:
#   firmware/analyze-diff.sh \
#       --config <DEVICE_CONFIG>      必填,设备 .config 路径
#       --ib-manifest <FILE>          必填,Tier1 已装包名清单 (一行一包)
#       [--pool-manifest <FILE>]      可选,Tier2 已编包名清单;不传 = 按空处理
#       --output <FILE>               必填,产出 JSON 数组路径
#
# kmod 守门: 全部 kmod-* 一律剔除 (SDK 容器无法补编内核符号),
# 复用 lib/pkg-filter.sh strip 模式,与 select-chunk 共享同一过滤实现。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg-filter.sh
source "$SCRIPT_DIR/../lib/pkg-filter.sh"

CONFIG_FILE=""
IB_MANIFEST=""
POOL_MANIFEST=""
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config)          CONFIG_FILE="$2"; shift 2 ;;
        --ib-manifest)     IB_MANIFEST="$2"; shift 2 ;;
        --pool-manifest)   POOL_MANIFEST="$2"; shift 2 ;;
        --output)          OUTPUT="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::firmware/analyze-diff: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$CONFIG_FILE" ] || { echo "::error::firmware/analyze-diff: 缺少 --config"       >&2; exit 2; }
[ -n "$IB_MANIFEST" ] || { echo "::error::firmware/analyze-diff: 缺少 --ib-manifest"  >&2; exit 2; }
[ -n "$OUTPUT"      ] || { echo "::error::firmware/analyze-diff: 缺少 --output"       >&2; exit 2; }

[ -f "$CONFIG_FILE" ] || { echo "::error::firmware/analyze-diff: $CONFIG_FILE 不存在" >&2; exit 1; }
[ -f "$IB_MANIFEST" ] || { echo "::error::firmware/analyze-diff: $IB_MANIFEST 不存在" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Tier1 + Tier2 已有清单 (清洗 + 去重)
pkg_filter_clean strip < "$IB_MANIFEST" | sort -u > "$tmp/available.txt"
if [ -n "$POOL_MANIFEST" ] && [ -f "$POOL_MANIFEST" ]; then
    pkg_filter_clean strip < "$POOL_MANIFEST" | sort -u > "$tmp/pool.txt"
    sort -u -o "$tmp/available.txt" "$tmp/available.txt" "$tmp/pool.txt"
fi

# 2. 设备需要清单 (从 .config 提取 =y/=m 的包名)
grep -E '^CONFIG_PACKAGE_.+=[ym]' "$CONFIG_FILE" \
    | sed -E 's/^CONFIG_PACKAGE_(.+)=[ym].*/\1/' \
    | sort -u > "$tmp/required.txt"

# 3. Required - Available
comm -23 "$tmp/required.txt" "$tmp/available.txt" > "$tmp/missing_raw.txt"

# 4. 过滤 kmod-* (SDK 容器无法补编)
pkg_filter_clean strip < "$tmp/missing_raw.txt" > "$tmp/missing.txt"

missing_n="$(wc -l < "$tmp/missing.txt" | tr -d ' ')"
skipped_kmod="$(grep -c '^kmod-' "$tmp/missing_raw.txt" || true)"
echo "firmware/analyze-diff: ${missing_n} 用户态包需补编;跳过 kmod ${skipped_kmod} 个 (应在 base-config 处理)。"

# 5. 产出 JSON 数组
if [ "$missing_n" -gt 0 ]; then
    jq -R . < "$tmp/missing.txt" | jq -s -c . > "$OUTPUT"
else
    echo "[]" > "$OUTPUT"
fi

echo "缺失包 JSON: $(cat "$OUTPUT")"
