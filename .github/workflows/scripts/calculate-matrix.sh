#!/usr/bin/env bash
# 脚本职责：计算 OpenWrt 构建矩阵
set -euo pipefail

# 1. 自动发现设备 (扫描 devices/ 目录)
ALL_DEVICES=()
if [ -d "devices" ]; then
    for dir in devices/*/; do
        [ -d "$dir" ] || continue
        dev_name=$(basename "$dir")
        ALL_DEVICES+=("$dev_name")
    done
fi

if [ ${#ALL_DEVICES[@]} -eq 0 ]; then
    echo "::error::未在 devices/ 目录下找到任何设备配置。"
    exit 1
fi

echo "发现设备配置: ${ALL_DEVICES[*]}"

BUILD_LIST=()

# 2. 分析变动逻辑
# 手动触发或定时任务：全量编译
if [[ "${GITHUB_EVENT_NAME}" == "schedule" ]] || [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then
    echo "构建模式: 全量构建 (${GITHUB_EVENT_NAME})"
    BUILD_LIST=("${ALL_DEVICES[@]}")

# 提交触发或 PR：智能增量分析
elif [[ "${GITHUB_EVENT_NAME}" == "push" ]] || [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
    echo "构建模式: 变更检测 (${GITHUB_EVENT_NAME})"

    if [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
        BASE_SHA="${BASE_SHA:-}"
        HEAD_SHA="${HEAD_SHA:-}"
    else
        # 处理 Push 的边界情况
        if git rev-parse HEAD^ >/dev/null 2>&1; then
            BASE_SHA="HEAD^"
        else
            BASE_SHA=""
        fi
        HEAD_SHA="HEAD"
    fi

    if [ -n "$BASE_SHA" ]; then
        # 获取变动文件清单
        CHANGED_FILES=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA")
        echo "变更文件:"
        echo "$CHANGED_FILES"

        # 判断是否修改了全局组件 (脚本、公共配置、工作流)
        if echo "$CHANGED_FILES" | grep -qE "^(scripts/|common/|\.github/workflows/)"; then
            echo "检测到公共组件变更，执行全量构建。"
            BUILD_LIST=("${ALL_DEVICES[@]}")
        else
            # 否则，仅加入受影响的特定设备
            for dev in "${ALL_DEVICES[@]}"; do
                if echo "$CHANGED_FILES" | grep -q "^devices/$dev/"; then
                    echo "设备变更: $dev"
                    BUILD_LIST+=("$dev")
                fi
            done
        fi
    else
        echo "未找到可用的对比基准，执行全量构建。"
        BUILD_LIST=("${ALL_DEVICES[@]}")
    fi
fi

# 3. 输出 GitHub Matrix 所需的 JSON
# 去重并排序
IFS=$'\n' BUILD_LIST=($(sort -u <<<"${BUILD_LIST[*]}")) ; unset IFS

if [ ${#BUILD_LIST[@]} -eq 0 ]; then
    echo "matrix=[]" >> "$GITHUB_OUTPUT"
    echo "has_builds=false" >> "$GITHUB_OUTPUT"
    echo "构建矩阵为空，无需构建。"
else
    JSON_ARRAY=$(printf '%s\n' "${BUILD_LIST[@]}" | jq -R . | jq -s -c .)
    DEVICE_LIST=$(printf '%s, ' "${BUILD_LIST[@]}")
    DEVICE_LIST="${DEVICE_LIST%, }"
    echo "matrix=$JSON_ARRAY" >> "$GITHUB_OUTPUT"
    echo "device_list=$DEVICE_LIST" >> "$GITHUB_OUTPUT"
    echo "has_builds=true" >> "$GITHUB_OUTPUT"
    echo "构建矩阵: $JSON_ARRAY"
fi
