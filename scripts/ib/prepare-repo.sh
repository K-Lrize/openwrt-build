#!/usr/bin/env bash
# scripts/ib/prepare-repo.sh
#
# 在「已解压的 ImageBuilder workdir」内把外部 ipk/apk 注册为本地最高优先级源:
#   1. 把 packages 目录下所有 ipk/apk 复制到 workdir/local_repo/
#   2. 生成 Packages.gz / APKINDEX.tar.gz (复用 scripts/sdk/index.sh)
#   3. 在 repositories.conf 第一行注入 src/gz local file://... 确保本地源优先
#
# 取代旧 _firmware-image.yml:95-108 在 docker IB 容器内跑的那一段。
#
# 用法:
#   ib/prepare-repo.sh \
#       --workdir <IB_ROOT>          必填,已解压的 IB 根
#       --packages-dir <DIR>         必填,tier2 + tier3 合并后的 ipk/apk 目录 (扁平)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR=""
PACKAGES_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)       WORKDIR="$2"; shift 2 ;;
        --packages-dir)  PACKAGES_DIR="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::ib/prepare-repo: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$WORKDIR"      ] || { echo "::error::ib/prepare-repo: 缺少 --workdir"      >&2; exit 2; }
[ -n "$PACKAGES_DIR" ] || { echo "::error::ib/prepare-repo: 缺少 --packages-dir" >&2; exit 2; }

WORKDIR="$(cd "$WORKDIR" && pwd)"
PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"

if [ ! -f "$WORKDIR/repositories.conf" ]; then
    echo "::error::ib/prepare-repo: $WORKDIR 不像 IB 根 (缺 repositories.conf)" >&2
    exit 1
fi

mkdir -p "$WORKDIR/local_repo"

# 复制全部 ipk/apk 到 local_repo (扁平结构,IB 本地源不分 arch/feed)
find "$PACKAGES_DIR" -type f \( -name "*.ipk" -o -name "*.apk" \) \
    -exec cp -v {} "$WORKDIR/local_repo/" \; 2>/dev/null \
    | sed 's|^|  |' \
    || true

if [ -z "$(find "$WORKDIR/local_repo" -maxdepth 1 -type f \( -name "*.ipk" -o -name "*.apk" \) 2>/dev/null)" ]; then
    echo "::warning::ib/prepare-repo: $PACKAGES_DIR 下无 ipk/apk,跳过 local_repo 注入。"
    rmdir "$WORKDIR/local_repo" 2>/dev/null || true
    exit 0
fi

# 生成索引 (借 IB 自带的 ipkg-make-index.sh,IB tar 通常包含它)
bash "$SCRIPT_DIR/../sdk/index.sh" --pool-dir "$WORKDIR/local_repo" --sdk-dir "$WORKDIR"

# 注入到 repositories.conf 第一行 — local 必须比远程 feed 优先
LOCAL_LINE="src/gz local file://$WORKDIR/local_repo"
if ! grep -qxF "$LOCAL_LINE" "$WORKDIR/repositories.conf"; then
    sed -i.bak "1i\\
${LOCAL_LINE}
" "$WORKDIR/repositories.conf" && rm -f "$WORKDIR/repositories.conf.bak"
fi

echo "ib/prepare-repo: $(find "$WORKDIR/local_repo" -maxdepth 1 -type f | wc -l | tr -d ' ') 个文件注册到 local_repo"
