#!/usr/bin/env bash
# scripts/pool/select-chunk.sh
#
# 从 common/custom-packages.txt 取第 <chunk_id>/<total> 片包名,输出到文件。
# 取代 scripts/ci/select-pool-chunk.sh:主要差异是写文件而非 stdout 管道,
# 让上下游耦合显式化。
#
# kmod 守门: pool 清单出现 kmod-* 视为配置错,exit 1。kmod 必须在
# common/base-config 用 CONFIG_PACKAGE_kmod-xxx=m 声明,由完整 buildroot 阶段处理。
#
# 用法:
#   pool/select-chunk.sh \
#       --conf-dir <BUILD_CONFIG_DIR>   build-config 仓库根,缺省自推断
#       --chunk-id <N>                  必填,0-based
#       --chunk-count <M>               必填,总片数
#       --output <FILE>                 必填,产出包清单的目标文件

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/pkg-filter.sh
source "$SCRIPT_DIR/../lib/pkg-filter.sh"
# shellcheck source=../lib/pkg-list.sh
source "$SCRIPT_DIR/../lib/pkg-list.sh"

CONF_DIR="$CONF_DIR_DEFAULT"
CHUNK_ID=""
CHUNK_COUNT=""
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --conf-dir)     CONF_DIR="$2"; shift 2 ;;
        --chunk-id)     CHUNK_ID="$2"; shift 2 ;;
        --chunk-count)  CHUNK_COUNT="$2"; shift 2 ;;
        --output)       OUTPUT="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::pool/select-chunk: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$CHUNK_ID"    ] || { echo "::error::pool/select-chunk: 缺少 --chunk-id"    >&2; exit 2; }
[ -n "$CHUNK_COUNT" ] || { echo "::error::pool/select-chunk: 缺少 --chunk-count" >&2; exit 2; }
[ -n "$OUTPUT"      ] || { echo "::error::pool/select-chunk: 缺少 --output"      >&2; exit 2; }

CONF_DIR="$(cd "$CONF_DIR" && pwd)"
LIST_FILE="$CONF_DIR/common/custom-packages.txt"

if [ ! -f "$LIST_FILE" ]; then
    echo "::warning::pool/select-chunk: 未找到 $LIST_FILE,本片为空。" >&2
    : > "$OUTPUT"
    exit 0
fi

mkdir -p "$(dirname "$OUTPUT")"

# 清洗 (kmod=error 守门) → 切片 → 落盘
pkg_filter_clean error < "$LIST_FILE" | pkg_list_chunk "$CHUNK_ID" "$CHUNK_COUNT" > "$OUTPUT"

count="$(wc -l < "$OUTPUT" | tr -d ' ')"
echo "pool/select-chunk: chunk ${CHUNK_ID}/${CHUNK_COUNT} -> ${OUTPUT} (${count} 个包)"
