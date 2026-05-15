#!/usr/bin/env bash
# scripts/ib/prepare-repo.sh
#
# 把外部 ipk/apk(Tier2 pool + Tier3 补编)注入已解压的 ImageBuilder workdir。
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
# 而 IB Makefile 自带 `package_index` target,build 时会检测 packages/ 下文件是否
# 比 packages.adb 新,如新则自动重 index(见上游 target/imagebuilder/files/Makefile:201-236)。
#
# 因此本脚本只需:
#   1. 校验 $WORKDIR 是 IB 根 (有 Makefile + packages/)
#   2. 把 $PACKAGES_DIR 下的 ipk/apk 复制进 $WORKDIR/packages/
#   3. 把 packages.adb / Packages.gz 的 mtime 倒回过去,确保 IB 触发重 index
#
# 用法:
#   ib/prepare-repo.sh \
#       --workdir <IB_ROOT>          必填,已解压的 IB 根
#       --packages-dir <DIR>         必填,tier2 + tier3 合并后的 ipk/apk 目录 (扁平)

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
    echo "::warning::ib/prepare-repo: $PACKAGES_DIR 下无 ipk/apk,无文件注入。"
    exit 0
fi

# 倒回 index 的 mtime,确保 IB Makefile 第 220-236 行的"新于 index 就重跑"判定生效。
# (cp -f 已经更新了被覆盖文件的 mtime,但新增包则不会改 index 文件本身。)
for idx in packages.adb Packages Packages.gz Packages.sig packages.adb.sig; do
    if [ -f "$WORKDIR/packages/$idx" ]; then
        touch -d '1970-01-01' "$WORKDIR/packages/$idx" 2>/dev/null || true
    fi
done

echo "ib/prepare-repo: $copied 个 ipk/apk → $WORKDIR/packages/ (IB make image 时自动重 index)"
