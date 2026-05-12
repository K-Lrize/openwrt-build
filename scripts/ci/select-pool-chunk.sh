#!/usr/bin/env bash
# scripts/ci/select-pool-chunk.sh
#
# 从 common/custom-packages.txt 取第 <chunk_id>/<total> 片包名，
# 按 “行号 % total == chunk_id” 切分，向 stdout 输出 “package/<name>/compile” 行，
# 供 scripts/build/compile-in-sdk.sh 经管道消费。
#
# 注意：pool 轨在 SDK 容器里运行，不编译任何内核模块——in-tree kmod 没有
# package/kmod-xxx/compile 这种粒度，且 SDK 的内核 .config 固定，符号没编进去
# 就编不出来。所以 kmod-* 条目一律跳过（并打印一条提示），需要的 kmod 请在
# common/base-config 里以 =m 声明，由完整 buildroot 编进 ImageBuilder。
#
# 用法:
#   bash select-pool-chunk.sh <build_config_dir> <chunk_id> <total>

set -euo pipefail

CONF_DIR="${1:?用法: $0 <build_config_dir> <chunk_id> <total>}"
CHUNK_ID="${2:?缺少 chunk id}"
TOTAL="${3:?缺少 total}"

LIST_FILE="$CONF_DIR/common/custom-packages.txt"
if [ ! -f "$LIST_FILE" ]; then
    echo "::warning::未找到 $LIST_FILE，本片无任务。" >&2
    exit 0
fi

i=0
while IFS= read -r pkg || [ -n "$pkg" ]; do
    # 去掉行内首尾空白后跳过空行与注释
    pkg="${pkg#"${pkg%%[![:space:]]*}"}"   # ltrim
    pkg="${pkg%"${pkg##*[![:space:]]}"}"   # rtrim
    case "$pkg" in ''|\#*) continue ;; esac
    # pool 不编译内核模块：遇到 kmod-* 一律跳过并提示
    case "$pkg" in
        kmod-*)
            echo "::warning::skipping kmod package: $pkg" >&2
            continue
            ;;
    esac
    if [ "$((i % TOTAL))" -eq "$CHUNK_ID" ]; then
        printf 'package/%s/compile\n' "$pkg"
    fi
    i=$((i + 1))
done < "$LIST_FILE"
