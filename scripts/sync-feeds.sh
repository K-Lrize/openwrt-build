#!/usr/bin/env bash
# 脚本职责：同步 Feeds 列表并准备设备编译配置
set -euo pipefail

DEVICE="${1:?用法: $0 <device_id>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVICE_DIR="${CONF_DIR}/devices/${DEVICE}"
COMMON_FEEDS="${CONF_DIR}/common/feeds.conf"
DEVICE_FEEDS="${DEVICE_DIR}/feeds.conf"

FEEDS_CONF="feeds.conf"
SEED_CONFIG="${DEVICE_DIR}/.config"

if [[ ! -x "./scripts/feeds" || ! -f "feeds.conf.default" ]]; then
    echo "::error::sync-feeds.sh 必须在 OpenWrt 源码根目录运行。"
    exit 1
fi

if [[ ! -f "$SEED_CONFIG" ]]; then
    echo "::error::未找到设备种子配置: $SEED_CONFIG"
    exit 1
fi

# 1. 初始化 feeds.conf。
echo "::group::准备 Feeds 配置"
cp feeds.conf.default "$FEEDS_CONF"

# 2. 注入自定义 Feeds 声明。
{
    [[ -f "$COMMON_FEEDS" ]] && cat "$COMMON_FEEDS"
    [[ -f "$DEVICE_FEEDS" ]] && cat "$DEVICE_FEEDS"
} | while read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! grep -qF "$line" "$FEEDS_CONF"; then
        echo "$line" >> "$FEEDS_CONF"
        echo "添加自定义 Feed: $line"
    fi
done
echo "::endgroup::"

# 3. 更新 Feeds 索引。
echo "::group::更新 Feeds 索引"
./scripts/feeds update -a
echo "::endgroup::"

# 4. 安装官方 Feed 软件包索引。
echo "::group::准备官方 Feed 基础环境"
OFFICIAL_FEEDS=$(grep '^src-' feeds.conf.default | awk '{print $2}')
for f in $OFFICIAL_FEEDS; do
    echo "链接官方 Feed: $f"
    ./scripts/feeds install -a -p "$f" >/dev/null || true
done
echo "::endgroup::"

# 5. 应用第三方 Feed 覆盖。
echo "::group::应用第三方覆盖"
{
    [[ -f "$COMMON_FEEDS" ]] && cat "$COMMON_FEEDS"
    [[ -f "$DEVICE_FEEDS" ]] && cat "$DEVICE_FEEDS"
} | while read -r line; do
    if [[ "$line" =~ ^#\ @override\ ([a-zA-Z0-9_-]+)\ ([a-zA-Z0-9_-]+) ]]; then
        feed="${BASH_REMATCH[1]}"
        pkg="${BASH_REMATCH[2]}"
        echo "  - 覆盖: $pkg [来源: $feed]"
        ./scripts/feeds uninstall "$pkg" >/dev/null || true
        ./scripts/feeds install -p "$feed" "$pkg" >/dev/null
    fi
done
echo "::endgroup::"

# 6. 准备最终 .config。
echo "::group::准备 .config 配置文件"
cp "$SEED_CONFIG" .config
echo "已从 $SEED_CONFIG 复制种子配置到当前目录"

while IFS= read -r line; do
    if [[ "$line" =~ ^#\ @config\ (CONFIG_.*) ]]; then
        config_line="${BASH_REMATCH[1]}"
        if ! grep -qF "$config_line" .config; then
            echo "  - 注入配置: $config_line"
            echo "$config_line" >> .config
        fi
    fi
done < <(
    [[ -f "$COMMON_FEEDS" ]] && cat "$COMMON_FEEDS"
    [[ -f "$DEVICE_FEEDS" ]] && cat "$DEVICE_FEEDS"
)
echo "::endgroup::"

# 7. 根据最终 .config 补充安装已选择的软件包及其依赖。
echo "::group::补全软件包依赖"
PKGS=$(grep -E '^CONFIG_PACKAGE_.*=[ym]$' .config | sed -E 's/^CONFIG_PACKAGE_(.*)=[ym]$/\1/' || true)
if [[ -n "$PKGS" ]]; then
    printf '%s\n' $PKGS | xargs -r ./scripts/feeds install || true
fi

rm -rf tmp
echo "::endgroup::"

