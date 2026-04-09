#!/usr/bin/env bash
# 脚本职责：验证最终生成的 .config 是否严格保留种子文件中的内置 PACKAGE 选项
set -euo pipefail

DEVICE="${1:?用法: $0 <device_id>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SEED="${CONF_DIR}/devices/${DEVICE}/.config"

if [[ ! -f "$SEED" ]]; then
    echo "::error::未找到该设备的种子配置: $SEED"
    exit 1
fi

if [[ ! -f .config ]]; then
    echo "::error::未找到当前目录下的 .config 文件，请先运行 make defconfig。"
    exit 1
fi

echo "::group::验证配置完整性 [${DEVICE}]"

SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
MISSING_LIST=()

# 1. 扫描种子文件，检查所有要求内置进固件的 PACKAGE 选项。
while IFS= read -r line; do
    if [[ "$line" =~ ^(CONFIG_PACKAGE_[A-Za-z0-9_+.-]+)=y$ ]]; then
        key="${BASH_REMATCH[1]}"
        if ! grep -qE "^${key}=y$" .config; then
            MISSING_LIST+=("$key")
        fi
    fi
done < "$SEED"

# 2. 扫描 feeds.conf 中的 @config 注入项。
COMMON_FEEDS="${CONF_DIR}/common/feeds.conf"
DEVICE_FEEDS="${CONF_DIR}/devices/${DEVICE}/feeds.conf"

for feeds_file in "$COMMON_FEEDS" "$DEVICE_FEEDS"; do
    [[ -f "$feeds_file" ]] || continue

    while IFS= read -r line; do
        if [[ "$line" =~ ^#\ @config\ (CONFIG_PACKAGE_[A-Za-z0-9_+.-]+)=y$ ]]; then
            key="${BASH_REMATCH[1]}"
            if ! grep -qE "^${key}=y$" .config; then
                MISSING_LIST+=("$key (来自 @config)")
            fi
        fi
    done < "$feeds_file"
done

if [[ "${#MISSING_LIST[@]}" -gt 0 ]]; then
    {
        echo "### 配置验证失败 [${DEVICE}]"
        echo "以下 PACKAGE 选项未以内置形式保留在最终 .config 中，通常由依赖冲突、目标平台不支持、Feed 缺失或被降级为模块导致。"
        echo ""
        echo "| 配置项 |"
        echo "| --- |"
        for item in "${MISSING_LIST[@]}"; do
            echo "| \`${item}\` |"
        done
    } >> "$SUMMARY_FILE"
    echo "::error::配置验证失败：${#MISSING_LIST[@]} 个 PACKAGE 选项未以内置形式保留。"
    echo "::endgroup::"
    exit 1
else
    {
        echo "### 配置验证通过 [${DEVICE}]"
        echo "种子配置中的 PACKAGE 选项均已以内置形式保留在最终 .config 中。"
    } >> "$SUMMARY_FILE"
    echo "配置验证通过：PACKAGE 选项均已以内置形式保留。"
    echo "::endgroup::"
fi
