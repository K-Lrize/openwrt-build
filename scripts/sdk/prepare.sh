#!/usr/bin/env bash
# scripts/sdk/prepare.sh
#
# 对一个「已解压的 SDK / OpenWrt 源码 workdir」做 feeds 拼装与 install。
# 取代旧的 scripts/build/prepare-feeds.sh,主要差异:
#   - 不再被假定在 docker 容器内运行(挂载点 /build-config 字面量),改为
#     显式 --workdir + --conf-dir。
#   - 新增 --feed-overlay,把 pool 解压目录作为 src-link 注册,使 tier3
#     补编时 feeds install 能优先解析到 pool 已有包(但 pool 只有 ipk
#     没 Makefile,会被 feeds install 跳过,这正是我们想要的)。
#
# 用法:
#   sdk/prepare.sh \
#       --workdir <SDK_ROOT>            必填,已解压的 SDK / OpenWrt 源码根
#       [--conf-dir <BUILD_CONFIG_DIR>] build-config 仓库根,缺省自推断
#       [--device <slug|__all__>]       拼接 device 特定 feeds;__all__ 合并所有
#       [--feed-overlay <DIR>]          注册为 src-link pool,优先级紧次于 base
#       [--packages <FILE>]             只 install 这些包(节省 base-packages 等
#                                       全量包通过 default=m 被 defconfig 展开)
#
# 设计:
#   1. base-packages/ 自动注入 src-link (优先级最高) — 兼容 SDK tar 内嵌 base 源
#   2. feed-overlay 注入紧次于 base-packages,优先级高于 common 远程源
#   3. common/feeds.conf 的 src-link local 行被替换为绝对路径,避免 cd 后失效
#   4. 去重保序:awk '!seen[$0]++'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORKDIR=""
CONF_DIR="$CONF_DIR_DEFAULT"
DEVICE=""
FEED_OVERLAY=""
PACKAGES_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)        WORKDIR="$2"; shift 2 ;;
        --conf-dir)       CONF_DIR="$2"; shift 2 ;;
        --device)         DEVICE="$2"; shift 2 ;;
        --feed-overlay)   FEED_OVERLAY="$2"; shift 2 ;;
        --packages)       PACKAGES_FILE="$2"; shift 2 ;;
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
[ -n "$FEED_OVERLAY" ] && FEED_OVERLAY="$(cd "$FEED_OVERLAY" && pwd)"

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

# 3. feed-overlay 注入 (pool 解压目录) — 紧次于 base
if [ -n "$FEED_OVERLAY" ]; then
    echo "注入 feed-overlay 为 src-link pool: $FEED_OVERLAY"
    if [ -d ./base-packages ]; then
        # base 在第 1 行,overlay 插入第 2 行
        sed -i.bak "2i\\
src-link pool $FEED_OVERLAY
" feeds.conf && rm -f feeds.conf.bak
    else
        sed -i.bak "1i\\
src-link pool $FEED_OVERLAY
" feeds.conf && rm -f feeds.conf.bak
    fi
fi

# 4. 设备特定 feeds
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

# 5. 去重保序
awk '!seen[$0]++' feeds.conf > feeds.conf.tmp && mv feeds.conf.tmp feeds.conf

echo "最终 feeds.conf:"
cat feeds.conf
echo "::endgroup::"

echo "::group::feeds update -a"
./scripts/feeds update -a
echo "::endgroup::"

echo "::group::feeds install"
if [ -n "$PACKAGES_FILE" ] && [ -f "$PACKAGES_FILE" ]; then
    echo "按包清单精准 install (避免 base-packages 全量 default=m 展开)"
    # xargs 兼容空文件
    if [ -s "$PACKAGES_FILE" ]; then
        xargs ./scripts/feeds install < "$PACKAGES_FILE"
    else
        echo "::warning::packages 清单为空,跳过 install。"
    fi
else
    ./scripts/feeds install -a
fi
echo "::endgroup::"
