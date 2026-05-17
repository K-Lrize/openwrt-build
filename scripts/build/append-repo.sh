#!/usr/bin/env bash
# scripts/build/append-repo.sh
#
# 追加本地 apk 源到 IB 的 repositories 文件. IB 自带的其他行完全不动.
#
# 假设: OpenWrt 24.10+ apk 制式 (文件名 `repositories`, 每行一个 packages.adb URL).
#
# 用法:
#   build/append-repo.sh --ib-workdir <IB_ROOT> --local-feed <DIR>
#
# 退出码:
#   0 = 成功 (或 local-feed 空目录 → 优雅跳过)
#   1 = IB 不像 IB 根 / local-feed 不存在
#   2 = 参数错

set -euo pipefail

WORKDIR=""
LOCAL_FEED=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ib-workdir) WORKDIR="$2"; shift 2 ;;
        --local-feed) LOCAL_FEED="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) echo "::error::append-repo: 未知参数 $1" >&2; exit 2 ;;
    esac
done

[ -n "$WORKDIR"    ] || { echo "::error::append-repo: 缺 --ib-workdir" >&2; exit 2; }
[ -n "$LOCAL_FEED" ] || { echo "::error::append-repo: 缺 --local-feed" >&2; exit 2; }

WORKDIR="$(cd "$WORKDIR" && pwd)"
LOCAL_FEED="$(cd "$LOCAL_FEED" && pwd)"
REPO="$WORKDIR/repositories"

[ -f "$REPO" ] || { echo "::error::append-repo: $REPO 不存在 (24.10+ apk IB 才有)" >&2; exit 1; }

INDEX="$LOCAL_FEED/packages.adb"
if [ ! -f "$INDEX" ]; then
    # apk 制式可能用 index.json (snapshot 后的新名), 优先 packages.adb
    if [ -f "$LOCAL_FEED/index.json" ]; then
        INDEX="$LOCAL_FEED/index.json"
    else
        echo "append-repo: $LOCAL_FEED 下无 packages.adb / index.json, 跳过 (空 feed 安全)"
        exit 0
    fi
fi

LINE="file://$INDEX"

# 幂等: 已含同 URL 行则不重复
if ! grep -qxF "$LINE" "$REPO"; then
    echo "$LINE" >> "$REPO"
fi

echo "append-repo: $REPO"
echo "  追加: $LINE"
