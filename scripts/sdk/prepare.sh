#!/usr/bin/env bash
# scripts/sdk/prepare.sh
#
# 对一个「已解压的 SDK / OpenWrt 源码 workdir」做 feeds 拼装与 install。
# 跨 GHA 各工作流统一入口,显式 --workdir + --conf-dir,不假设容器挂载点。
#
# 用法:
#   sdk/prepare.sh \
#       --workdir <SDK_ROOT>            必填,已解压的 SDK / OpenWrt 源码根
#       [--conf-dir <BUILD_CONFIG_DIR>] build-config 仓库根,缺省自推断
#       [--device <slug|__all__>]       拼接 device 特定 feeds;__all__ 合并所有
#       [--packages <FILE>]             只 install 这些包(节省 base-packages 等
#                                       全量包通过 default=m 被 defconfig 展开)
#
# 设计:
#   1. base-packages/ 自动注入 src-link (优先级最高) — 兼容 SDK tar 内嵌 base 源
#   2. common/feeds.conf 的 src-link local 行被替换为绝对路径,避免 cd 后失效
#   3. 去重保序:awk '!seen[$0]++'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORKDIR=""
CONF_DIR="$CONF_DIR_DEFAULT"
DEVICE=""
PACKAGES_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)   WORKDIR="$2"; shift 2 ;;
        --conf-dir)  CONF_DIR="$2"; shift 2 ;;
        --device)    DEVICE="$2"; shift 2 ;;
        --packages)  PACKAGES_FILE="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::sdk/prepare: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$WORKDIR" ] || { echo "::error::sdk/prepare: 缺少 --workdir" >&2; exit 2; }
WORKDIR="$(cd "$WORKDIR" && pwd)"
CONF_DIR="$(cd "$CONF_DIR" && pwd)"

# PACKAGES_FILE 必须在 cd $WORKDIR 之前规范化为绝对路径,否则相对路径(如 chunk.txt
# 由调用方写在 $GITHUB_WORKSPACE)在 cd 后会找不到,使下文 [ -f ] 检测失败,静默
# 落入 'feeds install -a' 分支 — 即 ee73a8c 修过的"全量展开"故障复现。
if [ -n "$PACKAGES_FILE" ]; then
    if [ ! -f "$PACKAGES_FILE" ]; then
        echo "::error::sdk/prepare: --packages 文件不存在: $PACKAGES_FILE" >&2
        exit 1
    fi
    PACKAGES_FILE="$(cd "$(dirname "$PACKAGES_FILE")" && pwd)/$(basename "$PACKAGES_FILE")"
fi

cd "$WORKDIR"

if [ ! -x ./scripts/feeds ]; then
    echo "::error::sdk/prepare: $WORKDIR 看起来不是 OpenWrt SDK / 源码根(缺 scripts/feeds)" >&2
    exit 1
fi

echo "::group::生成 feeds.conf"

# 1. 公共配置: src-link local 行替换为绝对路径,其余照搬
if [ -f "$CONF_DIR/common/feeds.conf" ]; then
    awk -v local_path="$CONF_DIR/feeds/local" '
        /^src-link[[:space:]]+local[[:space:]]+/ { print "src-link local " local_path; next }
        { print }
    ' "$CONF_DIR/common/feeds.conf" > feeds.conf
else
    # 兜底:用 SDK 自带默认
    cp feeds.conf.default feeds.conf
fi

# 2. base-packages/ 自动注入 (SDK tar 内嵌的 base 源) — 优先级最高
if [ -d ./base-packages ]; then
    echo "检测到 ./base-packages,注入为最高优先级 src-link..."
    sed -i.bak "1i\\
src-link base $(pwd)/base-packages
" feeds.conf && rm -f feeds.conf.bak
fi

# 3. 设备特定 feeds
if [ -n "$DEVICE" ] && [ "$DEVICE" != "__all__" ]; then
    DEV_FEEDS="$CONF_DIR/devices/$DEVICE/feeds.conf"
    if [ -f "$DEV_FEEDS" ]; then
        echo "追加 device feeds: $DEVICE"
        cat "$DEV_FEEDS" >> feeds.conf
    fi
elif [ "$DEVICE" = "__all__" ]; then
    echo "合并所有 device feeds (__all__ 模式)"
    find "$CONF_DIR/devices" -mindepth 2 -maxdepth 2 -name feeds.conf -type f \
        -exec cat {} + >> feeds.conf 2>/dev/null || true
fi

# 4. 去重保序
awk '!seen[$0]++' feeds.conf > feeds.conf.tmp && mv feeds.conf.tmp feeds.conf

echo "最终 feeds.conf:"
cat feeds.conf
echo "::endgroup::"

echo "::group::feeds update -a"
./scripts/feeds update -a
echo "::endgroup::"

echo "::group::feeds install"
if [ -n "$PACKAGES_FILE" ]; then
    # 调用方明确给了清单 → 必须按清单 install。绝不退化到 -a,
    # 否则 base-packages/ 全量包通过 default=m 被 defconfig 展开
    # (ee73a8c 修过的同款故障)。
    echo "按包清单精准 install: $PACKAGES_FILE"
    if [ -s "$PACKAGES_FILE" ]; then
        xargs ./scripts/feeds install < "$PACKAGES_FILE"
    else
        echo "::warning::packages 清单为空,跳过 install。"
    fi
else
    ./scripts/feeds install -a
fi
echo "::endgroup::"
