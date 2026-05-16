#!/usr/bin/env bash
# scripts/ci/validate-config.sh
#
# 校验 defconfig 后的 .config 是否严格保留了"种子要求内置 (=y)"的包。
#
# 种子来源 (G2 套餐方案后):
#   1. devices/<dev>/target.conf  → CONFIG_TARGET_*=y 必须保留
#   2. common/base-config         → CONFIG_PACKAGE_<pkg>=y 必须保留 (=m 不强制)
#   3. devices/<dev>/packages.list → @preset 展开后 +pkg 必须 =y
#
# 失败说明: 通常是依赖冲突 / target 不支持 / feed 缺包 / 被降级为 =m。
# 失败 exit 1。

set -euo pipefail

DEVICE="${1:?用法: $0 <device_id>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

TARGET_CONF="${CONF_DIR}/devices/${DEVICE}/target.conf"
PKG_LIST="${CONF_DIR}/devices/${DEVICE}/packages.list"
BASE_CONFIG="${CONF_DIR}/common/base-config"
PRESETS_DIR="${CONF_DIR}/common/presets"

if [[ ! -f "$TARGET_CONF" ]]; then
    echo "::error::未找到 $TARGET_CONF"
    exit 1
fi
if [[ ! -f "$PKG_LIST" ]]; then
    echo "::error::未找到 $PKG_LIST"
    exit 1
fi
if [[ ! -f .config ]]; then
    echo "::error::未找到当前目录下的 .config 文件,请先运行 make defconfig。"
    exit 1
fi

echo "::group::验证配置完整性 [${DEVICE}]"

SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
MISSING_LIST=()

check_y_kept() {
    local key="$1"
    if ! grep -qE "^${key}=y$" .config; then
        MISSING_LIST+=("$key")
    fi
}

# 1. target.conf 中 =y 的 CONFIG_TARGET_* 必须保留
while IFS= read -r line; do
    if [[ "$line" =~ ^(CONFIG_TARGET_[A-Za-z0-9_+.-]+)=y$ ]]; then
        check_y_kept "${BASH_REMATCH[1]}"
    fi
done < "$TARGET_CONF"

# 2. base-config 中 =y 的 PACKAGE 必须保留 (=m 不校验)
while IFS= read -r line; do
    if [[ "$line" =~ ^(CONFIG_PACKAGE_[A-Za-z0-9_+.-]+)=y$ ]]; then
        check_y_kept "${BASH_REMATCH[1]}"
    fi
done < "$BASE_CONFIG"

# 3. packages.list 展开后 + 的包必须 =y
# shellcheck source=../lib/expand-packages.sh
source "${SCRIPT_DIR}/../lib/expand-packages.sh"

while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
        +*) check_y_kept "CONFIG_PACKAGE_${entry#+}" ;;
        -*) : ;;  # 排除项不校验 (IB 阶段语义, buildroot defconfig 不识别)
    esac
done < <(expand_packages "$PKG_LIST" "$PRESETS_DIR")

if [[ "${#MISSING_LIST[@]}" -gt 0 ]]; then
    {
        echo "### 配置验证失败 [${DEVICE}]"
        echo "以下选项未以内置 (=y) 形式保留在最终 .config 中"
        echo "(依赖冲突 / target 不支持 / feed 缺失 / 被降级为 =m)。"
        echo ""
        echo "| 配置项 |"
        echo "| --- |"
        for item in "${MISSING_LIST[@]}"; do
            echo "| \`${item}\` |"
        done
    } >> "$SUMMARY_FILE"
    echo "::error::配置验证失败:${#MISSING_LIST[@]} 个选项未以内置形式保留。"
    for item in "${MISSING_LIST[@]}"; do
        echo "  - $item"
    done
    echo "::endgroup::"
    exit 1
fi

{
    echo "### 配置验证通过 [${DEVICE}]"
    echo "种子配置中的 =y 选项均已在 defconfig 后保留。"
} >> "$SUMMARY_FILE"
echo "配置验证通过:种子 =y 选项均保留。"
echo "::endgroup::"
