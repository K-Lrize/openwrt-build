#!/usr/bin/env bash
# scripts/build/add-repo.sh
#
# 把本地 apk 源 **prepend 到 IB repositories 头部**. 关键: 不是 append.
# 同时从 SDK 拷贝 build key 到 IB, 解决 UNTRUSTED signature 问题.
#
# 用法:
#   build/add-repo.sh --ib-workdir <IB_ROOT> --local-feed <DIR> [--sdk-dir <SDK_ROOT>]

set -euo pipefail

WORKDIR=""
LOCAL_FEED=""
SDK_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ib-workdir) WORKDIR="$2"; shift 2 ;;
        --local-feed) LOCAL_FEED="$2"; shift 2 ;;
        --sdk-dir)    SDK_DIR="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) echo "::error::add-repo: 未知参数 $1" >&2; exit 2 ;;
    esac
done

[ -n "$WORKDIR"    ] || { echo "::error::add-repo: 缺 --ib-workdir" >&2; exit 2; }
[ -n "$LOCAL_FEED" ] || { echo "::error::add-repo: 缺 --local-feed" >&2; exit 2; }

WORKDIR="$(cd "$WORKDIR" && pwd)"
LOCAL_FEED="$(cd "$LOCAL_FEED" && pwd)"
REPO="$WORKDIR/repositories"

[ -f "$REPO" ] || { echo "::error::add-repo: $REPO 不存在 (24.10+ apk IB 才有)" >&2; exit 1; }

# 1. 拷贝公钥 (如果有 SDK_DIR)
if [ -n "$SDK_DIR" ] && [ -d "$SDK_DIR" ]; then
    echo "add-repo: 尝试从 SDK 同步 build key..."
    # 公钥通常在 SDK 根目录叫 key-build.pub, 或者在 etc/apk/keys/ 下
    # 我们把它们都拷进 IB 的 key 目录
    IB_KEYS="$WORKDIR/etc/apk/keys"
    mkdir -p "$IB_KEYS"

    # 查找并拷贝 .pub 结尾的 key
    find "$SDK_DIR" -maxdepth 2 -name "key-build.pub" -exec cp -v {} "$IB_KEYS/" \;
    find "$SDK_DIR" -path "*/etc/apk/keys/*.pub" -exec cp -v {} "$IB_KEYS/" \;

    # 如果 IB 是在 docker 里跑或者 apk 指向宿主, 
    # 有些版本的 IB 还会读 staging_dir/host/etc/apk/keys
    IB_HOST_KEYS="$WORKDIR/staging_dir/host/etc/apk/keys"
    if [ -d "$(dirname "$IB_HOST_KEYS")" ]; then
        mkdir -p "$IB_HOST_KEYS"
        cp -v "$IB_KEYS"/*.pub "$IB_HOST_KEYS/" 2>/dev/null || true
    fi
fi

# 2. 修改 repositories
INDEX="$LOCAL_FEED/packages.adb"
if [ ! -f "$INDEX" ]; then
    if [ -f "$LOCAL_FEED/index.json" ]; then
        INDEX="$LOCAL_FEED/index.json"
    else
        echo "add-repo: $LOCAL_FEED 下无 packages.adb / index.json, 跳过 (空 feed 安全)"
        exit 0
    fi
fi

LINE="file://$INDEX"

{
    echo "$LINE"
    grep -vxF "$LINE" "$REPO" || true
} > "$REPO.new"
mv "$REPO.new" "$REPO"

echo "add-repo: $REPO"
echo "  prepend: $LINE"
echo "--- 完整 repositories ---"
cat "$REPO"

