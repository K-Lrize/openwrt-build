#!/usr/bin/env bash
# 脚本职责：计算 OpenWrt 构建矩阵
#
# 输出 GHA outputs:
#   device_matrix: ["mt3600be"]              JSON 数组
#   arch_matrix:   ["aarch64_cortex-a53"]    JSON 数组（按 arch 去重）
#   device_meta:   {"mt3600be":{...}}        JSON 对象（compact 单行）
#   device_list:   "mt3600be"                人类可读
#   has_builds:    true/false
#
# device_meta 每条 device 的字段:
#   arch, target, profile,
#   packages          (override pkg names，BuildCustomPackages 的 override 路径)
#   device_packages   (device .config 启用的全部官方包名，Prepare 计算 missing 用)
#   extra_feeds (multiline), override_pairs (multiline), config_injections (multiline)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/extract-config.sh
source "$CONF_DIR/scripts/lib/extract-config.sh"
# shellcheck source=../lib/slugify.sh
source "$CONF_DIR/scripts/lib/slugify.sh"

cd "$CONF_DIR"

# 1. 自动发现设备
ALL_DEVICES=()
if [ -d "devices" ]; then
    for dir in devices/*/; do
        [ -d "$dir" ] || continue
        ALL_DEVICES+=("$(basename "$dir")")
    done
fi

if [ ${#ALL_DEVICES[@]} -eq 0 ]; then
    echo "::error::未在 devices/ 目录下找到任何设备配置。"
    exit 1
fi

echo "发现设备: ${ALL_DEVICES[*]}"

BUILD_LIST=()

# 2. 启发式增量决策
case "${GITHUB_EVENT_NAME:-workflow_dispatch}" in
    schedule|workflow_dispatch)
        echo "构建模式: 全量构建 (${GITHUB_EVENT_NAME:-manual})"
        BUILD_LIST=("${ALL_DEVICES[@]}")
        ;;
    push|pull_request)
        echo "构建模式: 变更检测 (${GITHUB_EVENT_NAME})"
        if [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
            BASE="${BASE_SHA:-}"
            HEAD="${HEAD_SHA:-}"
        else
            HEAD="HEAD"
            if git rev-parse HEAD^ >/dev/null 2>&1; then
                BASE="HEAD^"
            else
                BASE=""
            fi
        fi
        if [ -n "$BASE" ]; then
            CHANGED=$(git diff --name-only "$BASE" "$HEAD")
            echo "变更文件:"
            echo "$CHANGED"
            if echo "$CHANGED" | grep -qE "^(scripts/|common/|\.github/workflows/)"; then
                echo "检测到公共组件变更，执行全量构建。"
                BUILD_LIST=("${ALL_DEVICES[@]}")
            else
                for dev in "${ALL_DEVICES[@]}"; do
                    if echo "$CHANGED" | grep -q "^devices/$dev/"; then
                        BUILD_LIST+=("$dev")
                    fi
                done
            fi
        else
            echo "无对比基准，执行全量构建。"
            BUILD_LIST=("${ALL_DEVICES[@]}")
        fi
        ;;
    *)
        BUILD_LIST=("${ALL_DEVICES[@]}")
        ;;
esac

# 去重 + 排序
if [ "${#BUILD_LIST[@]}" -gt 0 ]; then
    IFS=$'\n' BUILD_LIST=($(printf '%s\n' "${BUILD_LIST[@]}" | sort -u)); unset IFS
fi

# 3. 空矩阵直接返回
if [ ${#BUILD_LIST[@]} -eq 0 ]; then
    echo "构建矩阵为空，无需构建。"
    {
        echo "device_matrix=[]"
        echo "arch_matrix=[]"
        echo "device_meta={}"
        echo "device_list="
        echo "has_builds=false"
    } >> "$GITHUB_OUTPUT"
    exit 0
fi

# 4. 构造 device_meta + 收集 arch & target 集合
device_meta='{}'
arch_set=()
target_set=()

for dev in "${BUILD_LIST[@]}"; do
    cfg="devices/${dev}/.config"
    feeds="devices/${dev}/feeds.conf"
    common_feeds="common/feeds.conf"

    arch=$(extract_arch "$cfg")
    target=$(extract_target "$cfg")
    profile=$(extract_profile "$cfg")
    target_slug=$(slugify "$target")

    [ -z "$arch" ] && { echo "::warning::device ${dev} 缺 # @arch 注释，arch 设为 unknown"; arch="unknown"; }

    dev_meta=$(jq -n \
        --arg arch "$arch" \
        --arg target "$target" \
        --arg target_slug "$target_slug" \
        --arg profile "$profile" \
        '{
            arch: $arch,
            target: $target,
            target_slug: $target_slug,
            profile: $profile
        }')

    device_meta=$(jq -c --arg dev "$dev" --argjson meta "$dev_meta" \
        '. + {($dev): $meta}' <<< "$device_meta")

    arch_set+=("$arch")
    target_set+=("$target")
done

# 5. arch & target 去重
mapfile -t arch_list < <(printf '%s\n' "${arch_set[@]}" | sort -u)
mapfile -t target_list < <(printf '%s\n' "${target_set[@]}" | sort -u)

# 6. 序列化 + 输出
device_matrix_json=$(printf '%s\n' "${BUILD_LIST[@]}" | jq -R . | jq -s -c .)
arch_matrix_json=$(printf '%s\n' "${arch_list[@]}" | jq -R . | jq -s -c .)
target_matrix_json=$(printf '%s\n' "${target_list[@]}" | jq -R . | jq -s -c .)
device_list=$(printf '%s, ' "${BUILD_LIST[@]}"); device_list="${device_list%, }"

{
    echo "device_matrix=${device_matrix_json}"
    echo "arch_matrix=${arch_matrix_json}"
    echo "target_matrix=${target_matrix_json}"
    echo "device_meta=${device_meta}"
    echo "device_list=${device_list}"
    echo "has_builds=true"
} >> "$GITHUB_OUTPUT"

echo "device_matrix: ${device_matrix_json}"
echo "arch_matrix:   ${arch_matrix_json}"
echo "target_matrix: ${target_matrix_json}"
echo "device_meta:   ${device_meta}"
echo "device_list:   ${device_list}"
