#!/usr/bin/env bash
# scripts/ci/select-chunk.sh
#
# 从 common/presets/*.list (G2 套餐) union 后,取第 <chunk_id>/<total> 片包名,
# 输出到文件。Pool 工作流 (_pool-build.yml) 用,GHA runner 顶层执行 (不依赖 SDK)。
#
# 信息源 (架构不变量 #5):
#   common/presets/*.list 是 pool 编什么的唯一来源。
#   下划线开头的 preset (如 _extras.list) 也被 union — 游离包同样要编。
#
# kmod 守门: preset 里出现 kmod-* 视为配置错,exit 1。kmod 必须在
# common/base-config 用 CONFIG_PACKAGE_kmod-xxx=m 声明,由完整 buildroot 阶段处理。
#
# 用法:
#   ci/select-chunk.sh \
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
            echo "::error::ci/select-chunk: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$CHUNK_ID"    ] || { echo "::error::ci/select-chunk: 缺少 --chunk-id"    >&2; exit 2; }
[ -n "$CHUNK_COUNT" ] || { echo "::error::ci/select-chunk: 缺少 --chunk-count" >&2; exit 2; }
[ -n "$OUTPUT"      ] || { echo "::error::ci/select-chunk: 缺少 --output"      >&2; exit 2; }

CONF_DIR="$(cd "$CONF_DIR" && pwd)"
PRESETS_DIR="$CONF_DIR/common/presets"

if [ ! -d "$PRESETS_DIR" ]; then
    echo "::warning::ci/select-chunk: 未找到 $PRESETS_DIR,本片为空。" >&2
    : > "$OUTPUT"
    exit 0
fi

mkdir -p "$(dirname "$OUTPUT")"

# 1. union 所有 *.list (含 _ 开头的 _extras.list),通过 pkg_filter_clean error 守 kmod
# 2. pkg_list_merge_unique 按首次出现顺序去重 (chunk 切分依赖顺序稳定)
# 3. 切第 N 片
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat "$PRESETS_DIR"/*.list > "$tmp"
if [ ! -s "$tmp" ]; then
    echo "::warning::ci/select-chunk: $PRESETS_DIR 下所有 *.list 加起来为空,本片为空。" >&2
    : > "$OUTPUT"
    exit 0
fi

pkg_filter_clean error < "$tmp" \
    | pkg_list_merge_unique /dev/stdin \
    | pkg_list_chunk "$CHUNK_ID" "$CHUNK_COUNT" > "$OUTPUT"

count="$(wc -l < "$OUTPUT" | tr -d ' ')"
echo "ci/select-chunk: chunk ${CHUNK_ID}/${CHUNK_COUNT} -> ${OUTPUT} (${count} 个包)"
