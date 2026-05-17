#!/usr/bin/env bash
# scripts/build/fetch.sh
#
# 下载 OpenWrt IB / SDK tar 并解压. 一个工具同时管 IB 和 SDK — 都是 curl + tar.
#
# 用法:
#   build/fetch.sh --url <URL> --out <DIR>
#
# 输出:
#   stdout: 解压后的 workdir 绝对路径
#
# 说明:
#   - 自动识别 .tar.zst / .tar.xz / .tar.gz / .tar
#   - 假设 tar 解出来只有一个顶级目录, 输出该目录的绝对路径
#   - 适用于 OpenWrt 24.10+ 的 IB / SDK tar (apk 制式)

set -euo pipefail

URL=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --url) URL="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)  echo "::error::fetch: 未知参数 $1" >&2; exit 2 ;;
    esac
done

[ -n "$URL" ] || { echo "::error::fetch: 缺 --url" >&2; exit 2; }
[ -n "$OUT" ] || { echo "::error::fetch: 缺 --out" >&2; exit 2; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

FNAME="$(basename "$URL")"
TAR_PATH="$OUT/$FNAME"

echo "fetch: GET $URL" >&2
curl -sSL --fail -o "$TAR_PATH" "$URL"
[ -s "$TAR_PATH" ] || { echo "::error::fetch: 产物为空 $TAR_PATH" >&2; exit 1; }
echo "fetch: 已下载 $(du -h "$TAR_PATH" | awk '{print $1}')" >&2

echo "fetch: extracting..." >&2
case "$TAR_PATH" in
    *.tar.zst) tar --use-compress-program=unzstd -xf "$TAR_PATH" -C "$OUT" ;;
    *.tar.xz)  tar -xJf "$TAR_PATH" -C "$OUT" ;;
    *.tar.gz)  tar -xzf "$TAR_PATH" -C "$OUT" ;;
    *.tar)     tar -xf  "$TAR_PATH" -C "$OUT" ;;
    *) echo "::error::fetch: 不识别的 tar 格式 $TAR_PATH" >&2; exit 1 ;;
esac

# 解出来唯一的顶级目录就是 workdir; tar 删, 不留 ~500MB 垃圾
WORKDIR="$(find "$OUT" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$WORKDIR" ] || { echo "::error::fetch: 解压后未找到顶级目录" >&2; exit 1; }
rm -f "$TAR_PATH"

echo "$WORKDIR"
