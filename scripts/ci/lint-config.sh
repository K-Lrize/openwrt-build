#!/usr/bin/env bash
# scripts/ci/lint-config.sh
#
# 静态校验 devices/<dev>/.config (v6 单一事实源):
#
#   - 顶部注释:
#       # arch: <name>                         (架构标识)
#       # ib-url: <https://...tar.{zst,xz,gz}> (IB tar 下载来源)
#       # sdk-url: <https://...tar.{zst,xz,gz}> (SDK tar 下载来源)
#   - target 三件套:
#       CONFIG_TARGET_<board>=y
#       CONFIG_TARGET_<board>_<sub>=y
#       CONFIG_TARGET_<board>_<sub>_DEVICE_<profile>=y
#   - feeds/local 包必须显式 enable: 每个 feeds/local/<pkg>/ 在某个 device .config
#     里至少有一处 CONFIG_PACKAGE_<pkg>=y (否则该自维护包永远不会被编, 浪费源码维护)
#
# 失败 exit 1, stdout 给可读报告.
#
# 用法:
#   bash scripts/ci/lint-config.sh [conf-dir]   # 缺省: <repo-root>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CONF_DIR="$(cd "$CONF_DIR" && pwd)"

# HTTPS tar URL 校验 (允许 .tar.zst / .tar.xz / .tar.gz)
_is_valid_tar_url() {
    [[ "$1" =~ ^https?://.+\.tar\.(zst|xz|gz)$ ]]
}

DEVICES_DIR="$CONF_DIR/devices"
LOCAL_FEED_DIR="$CONF_DIR/feeds/local"

errors=0

# ─────────────────────────────────────────────────────────────
# 校验每个 device 的 .config
# ─────────────────────────────────────────────────────────────
[ -d "$DEVICES_DIR" ] || { echo "::error::lint-config: $DEVICES_DIR 不存在"; exit 1; }

# 累计所有 device 启用的 feeds/local 包 (用于 orphan 检查)
declare -A enabled_local_pkgs=()

for dev_dir in "$DEVICES_DIR"/*/; do
    [ -d "$dev_dir" ] || continue
    dev="$(basename "$dev_dir")"
    cfg="$dev_dir/.config"

    if [ ! -f "$cfg" ]; then
        echo "::error file=devices/${dev}/::缺 .config (v6 单一事实源)"
        errors=$((errors + 1))
        continue
    fi

    # 顶部注释
    if ! grep -qE '^#[[:space:]]*arch:[[:space:]]+' "$cfg"; then
        echo "::error file=devices/${dev}/.config::缺顶部 '# arch: <name>' 注释"
        errors=$((errors + 1))
    fi

    ib_url=$(grep -E '^#[[:space:]]*ib-url:[[:space:]]+' "$cfg" \
              | head -1 | sed -E 's/^#[[:space:]]*ib-url:[[:space:]]+//' | awk '{print $1}') || true
    if [ -z "$ib_url" ]; then
        echo "::error file=devices/${dev}/.config::缺 '# ib-url: <https://....tar.{zst,xz,gz}>' (IB tar 下载来源)"
        errors=$((errors + 1))
    elif ! _is_valid_tar_url "$ib_url"; then
        echo "::error file=devices/${dev}/.config::非法 # ib-url '${ib_url}' (须 HTTPS 且以 .tar.{zst,xz,gz} 结尾)"
        errors=$((errors + 1))
    fi

    sdk_url=$(grep -E '^#[[:space:]]*sdk-url:[[:space:]]+' "$cfg" \
               | head -1 | sed -E 's/^#[[:space:]]*sdk-url:[[:space:]]+//' | awk '{print $1}') || true
    if [ -z "$sdk_url" ]; then
        echo "::error file=devices/${dev}/.config::缺 '# sdk-url: <https://....tar.{zst,xz,gz}>' (SDK tar 下载来源)"
        errors=$((errors + 1))
    elif ! _is_valid_tar_url "$sdk_url"; then
        echo "::error file=devices/${dev}/.config::非法 # sdk-url '${sdk_url}' (须 HTTPS 且以 .tar.{zst,xz,gz} 结尾)"
        errors=$((errors + 1))
    fi

    # CONFIG_TARGET 三件套
    if ! grep -qE '^CONFIG_TARGET_[a-zA-Z0-9]+=y$' "$cfg"; then
        echo "::error file=devices/${dev}/.config::缺 CONFIG_TARGET_<board>=y 行"
        errors=$((errors + 1))
    fi
    if ! grep -qE '^CONFIG_TARGET_.*_DEVICE_.+=y$' "$cfg"; then
        echo "::error file=devices/${dev}/.config::缺 CONFIG_TARGET_..._DEVICE_<profile>=y 行"
        errors=$((errors + 1))
    fi

    # 收集 device .config 中启用的所有包, 用于 feeds/local orphan 检查
    while IFS= read -r pkg; do
        enabled_local_pkgs["$pkg"]=1
    done < <(grep -E '^CONFIG_PACKAGE_[A-Za-z0-9._+-]+=[ym]$' "$cfg" \
              | sed -E 's/^CONFIG_PACKAGE_([A-Za-z0-9._+-]+)=[ym]$/\1/')

    pkg_count=$(grep -cE '^CONFIG_PACKAGE_[A-Za-z0-9._+-]+=[ym]$' "$cfg" || true)
    skip_count=$(grep -cE '^# CONFIG_PACKAGE_[A-Za-z0-9._+-]+ is not set$' "$cfg" || true)
    echo "  device ${dev}: ${pkg_count} 包启用 / ${skip_count} 排除"
done

# ─────────────────────────────────────────────────────────────
# feeds/local 孤儿检查: 每个 feeds/local/<pkg>/ 至少在一个 device .config 启用
# ─────────────────────────────────────────────────────────────
if [ -d "$LOCAL_FEED_DIR" ]; then
    for d in "$LOCAL_FEED_DIR"/*/; do
        [ -d "$d" ] || continue
        pkg=$(basename "$d")
        if [ -z "${enabled_local_pkgs[$pkg]:-}" ]; then
            echo "::warning file=feeds/local/${pkg}/Makefile::feeds/local/${pkg} 未被任何 device 启用 (CONFIG_PACKAGE_${pkg}=y), 永远不会被编"
        fi
    done
fi

if [ "$errors" -gt 0 ]; then
    echo "::error::lint-config: ${errors} 个问题"
    exit 1
fi
echo "lint-config: 全部通过"
