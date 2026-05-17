#!/usr/bin/env bash
# scripts/ci/calculate-matrix.sh
#
# 计算 firmware.yml 的 device 矩阵. v5 架构 (单轨 IB-only) 下只需要两件事:
#   device_matrix  ["mt3600be", ...]  本次该编哪些设备
#   has_builds     true|false         有没有要编的
#
# 增量策略:
#   - schedule / workflow_dispatch → 全部设备
#   - push / pull_request:
#       动了 common/ scripts/ .github/workflows/ → 全部设备
#       仅动 devices/<X>/         → 只编 <X>
#
# 不再产出: target_matrix, device_meta, source_slug, pool_*, indexer_sdk_*
# (per-device 数据由下游 job 自己读 devices/<dev>/.config 现取)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$CONF_DIR"

# 1. 自动发现设备
ALL_DEVICES=()
if [ -d devices ]; then
    for dir in devices/*/; do
        [ -d "$dir" ] || continue
        ALL_DEVICES+=("$(basename "$dir")")
    done
fi
[ "${#ALL_DEVICES[@]}" -gt 0 ] || { echo "::error::devices/ 下未发现任何设备"; exit 1; }
echo "发现设备: ${ALL_DEVICES[*]}"

BUILD_LIST=()
case "${GITHUB_EVENT_NAME:-workflow_dispatch}" in
    schedule|workflow_dispatch)
        echo "构建模式: 全量 (${GITHUB_EVENT_NAME:-manual})"
        BUILD_LIST=("${ALL_DEVICES[@]}")
        ;;
    push|pull_request)
        if [ "${GITHUB_EVENT_NAME}" = pull_request ]; then
            BASE="${BASE_SHA:-}"
            HEAD="${HEAD_SHA:-}"
        else
            HEAD=HEAD
            BASE=""
            git rev-parse HEAD^ >/dev/null 2>&1 && BASE=HEAD^
        fi
        if [ -n "$BASE" ]; then
            CHANGED=$(git diff --name-only "$BASE" "$HEAD" || true)
            echo "变更文件:"; echo "$CHANGED"
            if echo "$CHANGED" | grep -qE "^(scripts/|common/|\.github/workflows/)"; then
                echo "公共组件变更, 全量构建"
                BUILD_LIST=("${ALL_DEVICES[@]}")
            else
                for dev in "${ALL_DEVICES[@]}"; do
                    echo "$CHANGED" | grep -q "^devices/$dev/" && BUILD_LIST+=("$dev")
                done
            fi
        else
            echo "无对比基准, 全量构建"
            BUILD_LIST=("${ALL_DEVICES[@]}")
        fi
        ;;
    *) BUILD_LIST=("${ALL_DEVICES[@]}") ;;
esac

if [ "${#BUILD_LIST[@]}" -gt 0 ]; then
    IFS=$'\n' BUILD_LIST=($(printf '%s\n' "${BUILD_LIST[@]}" | sort -u)); unset IFS
fi

if [ "${#BUILD_LIST[@]}" -eq 0 ]; then
    echo "矩阵为空"
    {
        echo "device_matrix=[]"
        echo "has_builds=false"
    } >> "$GITHUB_OUTPUT"
    exit 0
fi

DEVICE_MATRIX_JSON=$(printf '%s\n' "${BUILD_LIST[@]}" | jq -R . | jq -s -c .)
{
    echo "device_matrix=${DEVICE_MATRIX_JSON}"
    echo "has_builds=true"
} >> "$GITHUB_OUTPUT"

echo "device_matrix: ${DEVICE_MATRIX_JSON}"
