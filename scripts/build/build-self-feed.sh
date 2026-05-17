#!/usr/bin/env bash
# scripts/build/build-self-feed.sh
#
# 用已解压的官方 SDK 编 feeds/local/* 下所有自维护包, 输出到一个独立的
# local-feed 目录 (含 SDK 原生生成的 packages.adb 索引).
#
# 假设: OpenWrt 24.10+ apk 制式. 不做 opkg 兼容.
#
# 用法:
#   build/build-self-feed.sh \
#       --sdk <SDK_ROOT>          已解压的 SDK 根
#       --feeds-local-dir <DIR>   feeds/local 目录绝对路径
#       --out <DIR>               输出目录 (会 mkdir, 内含 ipk/apk + 索引)
#
# 退出码:
#   0 = 成功 (空 feed 也算成功, 留空目录)
#   1 = 编译或索引失败
#   2 = 参数错

set -euo pipefail

SDK=""
FEEDS_LOCAL_DIR=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --sdk)              SDK="$2"; shift 2 ;;
        --feeds-local-dir)  FEEDS_LOCAL_DIR="$2"; shift 2 ;;
        --out)              OUT="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) echo "::error::build-self-feed: 未知参数 $1" >&2; exit 2 ;;
    esac
done

[ -n "$SDK"             ] || { echo "::error::build-self-feed: 缺 --sdk" >&2; exit 2; }
[ -n "$FEEDS_LOCAL_DIR" ] || { echo "::error::build-self-feed: 缺 --feeds-local-dir" >&2; exit 2; }
[ -n "$OUT"             ] || { echo "::error::build-self-feed: 缺 --out" >&2; exit 2; }

SDK="$(cd "$SDK" && pwd)"
FEEDS_LOCAL_DIR="$(cd "$FEEDS_LOCAL_DIR" && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

[ -f "$SDK/Makefile"      ] || { echo "::error::build-self-feed: $SDK 不像 SDK 根" >&2; exit 1; }
[ -x "$SDK/scripts/feeds" ] || { echo "::error::build-self-feed: $SDK/scripts/feeds 不存在" >&2; exit 1; }

# 空 feed 优雅跳过
mapfile -t PKGS < <(find "$FEEDS_LOCAL_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
if [ "${#PKGS[@]}" -eq 0 ]; then
    echo "build-self-feed: $FEEDS_LOCAL_DIR 为空, 跳过"
    echo "$OUT"
    exit 0
fi
echo "::group::build-self-feed: ${#PKGS[@]} 个包"
printf "  - %s\n" "${PKGS[@]}"
echo "::endgroup::"

# 在 SDK 内追加 src-link 行 (幂等)
# 关键: 保留 SDK 默认 feeds.conf (含 packages/base/luci/routing 等上游标准 feed),
# 在末尾加 local_self. 上游 feed 是自维护包的 build deps 来源:
#   sing-box 需要 packages feed 的 lang/golang/golang-package.mk + golang/host
#   sing-box 需要 base feed 的 ca-bundle 包定义
# 只装 local_self → 上游 deps 找不到 → "please fix Makefile" 报错.
SDK_FEEDS_CONF="$SDK/feeds.conf"
[ ! -f "$SDK_FEEDS_CONF" ] && cp -f "$SDK/feeds.conf.default" "$SDK_FEEDS_CONF"
grep -vE "^src-link[[:space:]]+local_self[[:space:]]" "$SDK_FEEDS_CONF" > "$SDK_FEEDS_CONF.tmp" || true
echo "src-link local_self $FEEDS_LOCAL_DIR" >> "$SDK_FEEDS_CONF.tmp"
mv "$SDK_FEEDS_CONF.tmp" "$SDK_FEEDS_CONF"

echo "::group::build-self-feed: scripts/feeds update + install (all feeds)"
# update -a / install -a: 所有 feed (标准 + local_self) 都装. install -a 只创建
# package/ 下的符号链接 (让 deps 可解析), 不会让所有包都编 — 我们的 .config
# 只有 CONFIG_PACKAGE_<我们的包>=m, 实际编译列表由它决定.
(cd "$SDK" && ./scripts/feeds update -a && ./scripts/feeds install -a)
echo "::endgroup::"

echo "::group::build-self-feed: compose .config"
: > "$SDK/.config"
for pkg in "${PKGS[@]}"; do
    echo "CONFIG_PACKAGE_${pkg}=m" >> "$SDK/.config"
done
(cd "$SDK" && make defconfig)
echo "::endgroup::"

echo "::group::build-self-feed: 编译"
RC=0
for pkg in "${PKGS[@]}"; do
    echo "--- package/$pkg/compile ---"
    if ! (cd "$SDK" && make "package/$pkg/compile" -j"$(nproc 2>/dev/null || echo 2)"); then
        echo "::error::build-self-feed: $pkg 编译失败 (重试 V=s 收集详细日志)" >&2
        (cd "$SDK" && make "package/$pkg/compile" -j1 V=s) || true
        RC=1
    fi
done
echo "::endgroup::"
[ $RC -eq 0 ] || exit 1

echo "::group::build-self-feed: make package_index"
(cd "$SDK" && make package_index)
echo "::endgroup::"

# 收集 local_self feed 产物 (含 SDK 原生生成的 packages.adb)
echo "::group::build-self-feed: 收集 → $OUT"
SRC_PKGS_DIR="$SDK/bin/packages"
[ -d "$SRC_PKGS_DIR" ] || { echo "::error::build-self-feed: $SRC_PKGS_DIR 不存在" >&2; exit 1; }

found=0
for arch_dir in "$SRC_PKGS_DIR"/*/; do
    arch="$(basename "$arch_dir")"
    feed_dir="$arch_dir/local_self"
    [ -d "$feed_dir" ] || continue
    echo "  $arch/local_self → $OUT/"
    find "$feed_dir" -maxdepth 1 -type f \
        \( -name '*.apk' -o -name '*.ipk' \
           -o -name 'packages.adb' -o -name 'index.json' \
           -o -name 'Packages*' \) \
        -exec cp -n {} "$OUT/" \;
    found=1
done

[ $found -eq 1 ] || { echo "::error::build-self-feed: 未在 bin/packages/*/local_self/ 找到产物" >&2; exit 1; }
echo "::endgroup::"

echo "build-self-feed: 完成, OUT=$OUT"
echo "$OUT"
