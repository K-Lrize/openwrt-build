#!/usr/bin/env bash
# scripts/build/prepare-feeds.sh
#
# 在 OpenWrt 源码/SDK 根目录运行。
# 职责：按顺序拼接 common + device 的 feeds 配置。
#
# 用法:
#   bash <build-config>/scripts/build/prepare-feeds.sh [device_id]

set -euo pipefail

DEVICE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ ! -x "./scripts/feeds" ]]; then
    echo "::error::prepare-feeds.sh 必须在 OpenWrt 源码或 SDK 根目录运行。"
    exit 1
fi

echo "::group::生成 feeds.conf"
# 1. 写入公共配置 (包含 local feed 和官方基础源)
if [[ -f "${CONF_DIR}/common/feeds.conf" ]]; then
    echo "写入公共 Feeds..."
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^src-link[[:space:]]+local[[:space:]]+ ]]; then
            printf 'src-link local %s\n' "${CONF_DIR}/feeds/local"
        else
            printf '%s\n' "$line"
        fi
    done < "${CONF_DIR}/common/feeds.conf" > feeds.conf
else
    # 兜底：如果公共配置不存在，则使用官方默认
    cp feeds.conf.default feeds.conf
fi

# 1.5 自动检测并注入“固化”的 Base 源 (针对打包进镜像的 SDK)
if [[ -d "./base-packages" ]]; then
    echo "检测到预装的 Base 源，自动注入本地路径..."
    # 将其放在第一行，确保优先级
    sed -i "1i src-link base $(pwd)/base-packages" feeds.conf
fi

# 2. 追加设备特定配置 (如 passwall 等第三方插件源)
if [[ -n "$DEVICE" && "$DEVICE" != "__all__" ]]; then
    DEVICE_FEEDS="${CONF_DIR}/devices/${DEVICE}/feeds.conf"
    if [[ -f "$DEVICE_FEEDS" ]]; then
        echo "追加设备特定 Feeds: ${DEVICE}"
        cat "$DEVICE_FEEDS" >> feeds.conf
    fi
elif [[ "$DEVICE" == "__all__" ]]; then
    # 合并所有设备的 feeds.conf (用于全量包编译场景)
    find "${CONF_DIR}/devices" -mindepth 2 -maxdepth 2 -name feeds.conf -type f -exec cat {} + >> feeds.conf 2>/dev/null || true
fi

# 3. 最终清理：去重并保持顺序
awk '!seen[$0]++' feeds.conf > feeds.conf.tmp && mv feeds.conf.tmp feeds.conf

echo "最终生成的 feeds.conf 内容如下:"
cat feeds.conf
echo "::endgroup::"

echo "::group::更新并安装 Feeds"
./scripts/feeds update -a
# 若调用方传入包名文件（第 2 参数），则只安装指定包，避免 feeds install -a
# 将 base-packages/ 等全量包注册进构建系统，进而被 make defconfig 的 default m
# 逻辑大量展开，导致 SDK 编译时把几百个无关包全部编译（llvm/chicken-scheme 等）。
if [[ -n "${2:-}" && -f "$2" ]]; then
    echo "按需安装 Feeds（仅限指定包清单）..."
    xargs ./scripts/feeds install < "$2"
else
    ./scripts/feeds install -a
fi
echo "::endgroup::"
