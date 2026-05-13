#!/usr/bin/env bash
# scripts/ci/select-pool-chunk.sh
#
# 从 common/custom-packages.txt 取第 <chunk_id>/<total> 片包名（按行号 mod 切分），
# 向 stdout 输出「裸包名」一行一个，供 scripts/build/compile-in-sdk.sh 经管道消费。
#
# 设计约束:
#   - pool 轨用 SDK 容器，只编用户态；kmod 必须在 common/base-config 里 =m，由
#     完整 buildroot 编进 ImageBuilder。pool 清单出现 kmod-* 视为配置错（这里直接
#     退出 1，让 CI 早红；上游另有 scripts/ci/lint-custom-packages.sh 做更早的静态校验）。
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
errors=0
while IFS= read -r line || [ -n "$line" ]; do
    # 剥行尾注释与首尾空白
    pkg="${line%%#*}"
    pkg="${pkg#"${pkg%%[![:space:]]*}"}"
    pkg="${pkg%"${pkg##*[![:space:]]}"}"
    case "$pkg" in
        '') continue ;;
    esac

    if [[ "$pkg" == kmod-* ]]; then
        echo "::error::pool 清单禁止 kmod：'$pkg' (应在 common/base-config 用 CONFIG_PACKAGE_${pkg}=m 声明)" >&2
        errors=$((errors + 1))
        continue
    fi

    if [ "$((i % TOTAL))" -eq "$CHUNK_ID" ]; then
        printf '%s\n' "$pkg"
    fi
    i=$((i + 1))
done < "$LIST_FILE"

if [ "$errors" -gt 0 ]; then
    exit 1
fi
