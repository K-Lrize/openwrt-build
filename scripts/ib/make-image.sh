#!/usr/bin/env bash
# scripts/ib/make-image.sh
#
# 在「已 prepare-repo 的 ImageBuilder workdir」内组装一台设备的固件镜像。
# 取代旧 _firmware-image.yml:111-119 在 docker IB 容器内的逻辑。
#
# 用法:
#   ib/make-image.sh \
#       --workdir <IB_ROOT>          必填,已解压且 prepare-repo 完毕的 IB 根
#       --conf-dir <BUILD_CONFIG>    必填,build-config 仓库根 (供 merge-files.sh)
#       --device <DEVICE_SLUG>       必填,设备 slug,merge-assets 用
#       --profile <PROFILE>          必填,IB make image PROFILE
#       --packages <STR>             必填,空格分隔的包名清单 (IB make image PACKAGES)
#       --out <DIR>                  必填,bin/targets 拷贝目标 (此目录会创建)

set -euo pipefail

WORKDIR=""
CONF_DIR=""
DEVICE=""
PROFILE=""
PACKAGES=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)   WORKDIR="$2"; shift 2 ;;
        --conf-dir)  CONF_DIR="$2"; shift 2 ;;
        --device)    DEVICE="$2"; shift 2 ;;
        --profile)   PROFILE="$2"; shift 2 ;;
        --packages)  PACKAGES="$2"; shift 2 ;;
        --out)       OUT="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::ib/make-image: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$WORKDIR"  ] || { echo "::error::ib/make-image: 缺少 --workdir"  >&2; exit 2; }
[ -n "$CONF_DIR" ] || { echo "::error::ib/make-image: 缺少 --conf-dir" >&2; exit 2; }
[ -n "$DEVICE"   ] || { echo "::error::ib/make-image: 缺少 --device"   >&2; exit 2; }
[ -n "$PROFILE"  ] || { echo "::error::ib/make-image: 缺少 --profile"  >&2; exit 2; }
[ -n "$PACKAGES" ] || { echo "::error::ib/make-image: 缺少 --packages" >&2; exit 2; }
[ -n "$OUT"      ] || { echo "::error::ib/make-image: 缺少 --out"      >&2; exit 2; }

WORKDIR="$(cd "$WORKDIR" && pwd)"
CONF_DIR="$(cd "$CONF_DIR" && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [ ! -e "$WORKDIR/Makefile" ]; then
    echo "::error::ib/make-image: $WORKDIR 不像 IB 根 (缺 Makefile)" >&2
    exit 1
fi

cd "$WORKDIR"

echo "::group::ib/make-image: merge-files ($DEVICE)"
bash "$CONF_DIR/scripts/ib/merge-files.sh" "$DEVICE"
echo "::endgroup::"

echo "::group::ib/make-image: make image PROFILE=$PROFILE"
make image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES="files/"
echo "::endgroup::"

echo "::group::ib/make-image: collect bin/targets → $OUT"
cp -ra bin/targets/. "$OUT/"
echo "::endgroup::"
