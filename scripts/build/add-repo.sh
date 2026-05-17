#!/usr/bin/env bash
# scripts/build/add-repo.sh
#
# 把本地 apk 源 **prepend 到 IB repositories 头部**. 关键: 不是 append.
#
# 为什么是 prepend:
#   apk 选包规则: 版本号高的优先; 同版本时 repositories 中靠前的源优先.
#   我们自维护的 sing-box 跟上游 packages feed 同名, 版本号未必更高,
#   如果加在末尾 → 同版本时上游赢 → 装的不是我们的版本.
#   必须放头部, 保证同名同版本时我们赢.
#
# 假设: OpenWrt 24.10+ apk 制式 (文件名 `repositories`, 每行一个 URL).
#
# 用法:
#   build/add-repo.sh --ib-workdir <IB_ROOT> --local-feed <DIR>
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
        *) echo "::error::add-repo: 未知参数 $1" >&2; exit 2 ;;
    esac
done

[ -n "$WORKDIR"    ] || { echo "::error::add-repo: 缺 --ib-workdir" >&2; exit 2; }
[ -n "$LOCAL_FEED" ] || { echo "::error::add-repo: 缺 --local-feed" >&2; exit 2; }

WORKDIR="$(cd "$WORKDIR" && pwd)"
LOCAL_FEED="$(cd "$LOCAL_FEED" && pwd)"
REPO="$WORKDIR/repositories"

[ -f "$REPO" ] || { echo "::error::add-repo: $REPO 不存在 (24.10+ apk IB 才有)" >&2; exit 1; }

# IB 24.10+ apk 制式: repositories 每行 **直接指 packages.adb 文件路径**,
# 不是目录 URL. 上游样子:
#   https://downloads.openwrt.org/snapshots/packages/<arch>/base/packages.adb
# 所以我们追加的也是 file:// 直指 packages.adb (或 index.json).
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

# 幂等: 已含同 URL 行则先剥掉, 再 prepend, 保证总在第一行
{
    echo "$LINE"
    grep -vxF "$LINE" "$REPO" || true
} > "$REPO.new"
mv "$REPO.new" "$REPO"

echo "add-repo: $REPO"
echo "  prepend: $LINE"
echo "--- 完整 repositories ---"
cat "$REPO"
