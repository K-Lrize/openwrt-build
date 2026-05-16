#!/usr/bin/env bash
# scripts/ib/prepare-repo.sh
#
# 把外部 ipk/apk (pool 包 + fallback 补编) 注入已解压的 ImageBuilder workdir。
#
# 现代 OpenWrt IB (2024-12 切到 APK 之后,且 _base-target.yml 用 CONFIG_IB_STANDALONE=y)
# 顶层不再有 repositories.conf / repositories 文件 — IB Makefile 的 APK 命令是:
#
#   APK := apk ... \
#          $(if $(CONFIG_IB_STANDALONE),,--repositories-file $(TOPDIR)/repositories) \
#          --repository $(PACKAGE_DIR)/packages.adb \
#          $(if $(CONFIG_SIGNATURE_CHECK),,--allow-untrusted) \
#
# STANDALONE 模式下完全只看 $TOPDIR/packages/packages.adb,不读外部 repo。
# 上游 `make target/imagebuilder/install` 当前 (2026-Q2) 不预生成 packages.adb,
# 留给用户在 `make image` 链路里通过 `package_index` target 现场生成。但
# `make manifest` 不一定走同一条依赖链 — 索引缺失时 apk add 看到空仓,所有包
# 都会报 `(no such package)`,包括 IB 自带的 base-files / libc / kernel。
#
# 因此本脚本只需:
#   1. 校验 $WORKDIR 是 IB 根 (有 Makefile + packages/)
#   2. 把 $PACKAGES_DIR 下的 ipk/apk 复制进 $WORKDIR/packages/
#   3. 显式跑一次 `make package_index` 把 IB 自带 + 注入的包统一索引到 packages.adb,
#      让后续 probe-missing.sh / make-image.sh 看到完整闭包
#
# 用法:
#   ib/prepare-repo.sh \
#       --workdir <IB_ROOT>          必填,已解压的 IB 根
#       --packages-dir <DIR>         必填,pool + fallback 合并后的 ipk/apk 目录 (扁平)

set -euo pipefail

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

if [ ! -f "$WORKDIR/Makefile" ] || [ ! -d "$WORKDIR/packages" ]; then
    echo "::error::ib/prepare-repo: $WORKDIR 不像 IB 根 (缺 Makefile 或 packages/)" >&2
    echo "::group::ib-root listing"
    ls -la "$WORKDIR" >&2 || true
    echo "::endgroup::"
    exit 1
fi

# 把外部 ipk/apk 平铺复制进 IB 的 PACKAGE_DIR。
# IB 的 packages/ 本来就是单一目录(IB tar 自带预编译的 base 包),追加即可。
copied=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    cp -f "$f" "$WORKDIR/packages/"
    copied=$((copied + 1))
done < <(find "$PACKAGES_DIR" -maxdepth 4 -type f \( -name '*.ipk' -o -name '*.apk' \))

if [ "$copied" -eq 0 ]; then
    echo "::warning::ib/prepare-repo: $PACKAGES_DIR 下无 ipk/apk,无文件注入 (仅索引 IB 自带包)。"
fi

# 显式重建 package index。
# 上游 IB tar 不含 packages.adb,且 `make manifest` 不强制依赖 package_index,
# 所以必须在这里主动生成,否则 STANDALONE 模式下 apk 看到空仓 → 全部包 missing。
# 即便没注入新包,IB 自带的 1000+ 个 .apk 也需要索引才能被 probe / make image 查到。
echo "ib/prepare-repo: 重建 package index (make package_index)..."
if ! ( cd "$WORKDIR" && make package_index >/tmp/ib-prepare-repo-index.log 2>&1 ); then
    echo "::error::ib/prepare-repo: make package_index 失败" >&2
    echo "::group::package_index log (tail 80)"
    tail -80 /tmp/ib-prepare-repo-index.log >&2 || true
    echo "::endgroup::"
    exit 1
fi

if [ ! -f "$WORKDIR/packages/packages.adb" ]; then
    echo "::error::ib/prepare-repo: 索引重建后仍无 packages.adb,IB STANDALONE 将查不到任何包" >&2
    exit 1
fi

echo "ib/prepare-repo: $copied 个 ipk/apk → $WORKDIR/packages/, packages.adb 已重建"
