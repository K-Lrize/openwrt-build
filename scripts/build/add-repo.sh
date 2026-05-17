#!/usr/bin/env bash
# scripts/build/add-repo.sh
#
# 把本地 apk 源 **prepend 到 IB repositories 头部**. 关键: 不是 append.
# 同时从 SDK 拷贝 build key 到 IB 和宿主环境, 解决 UNTRUSTED signature 问题.
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
    # 查找公钥
    PUB_KEY=$(find "$SDK_DIR" -maxdepth 2 -name "key-build.pub" | head -n 1)
    if [ -z "$PUB_KEY" ]; then
        PUB_KEY=$(find "$SDK_DIR" -path "*/etc/apk/keys/*.pub" | head -n 1)
    fi

    if [ -n "$PUB_KEY" ]; then
        echo "add-repo: 找到公钥: $PUB_KEY"
        
        # A. 拷贝到 IB 内部路径 (供 IB 内部 make 逻辑使用)
        # 支持多种可能的 IB key 路径
        TARGET_DIRS=(
            "$WORKDIR/etc/apk/keys"
            "$WORKDIR/staging_dir/host/etc/apk/keys"
        )
        for d in "${TARGET_DIRS[@]}"; do
            mkdir -p "$d"
            cp -v "$PUB_KEY" "$d/"
        done

        # B. 拷贝到宿主系统路径 (最重要: 供 runner 环境下的 apk 直接读)
        # GitHub Runner 允许免密 sudo
        if command -v sudo >/dev/null; then
            echo "add-repo: 注入宿主系统信任目录 /etc/apk/keys/ ..."
            sudo mkdir -p /etc/apk/keys/
            sudo cp -v "$PUB_KEY" /etc/apk/keys/
        fi
    else
        echo "::warning::add-repo: 未在 SDK 目录中找到公钥 (*.pub), UNTRUSTED 风险依然存在"
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

