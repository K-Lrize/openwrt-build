#!/usr/bin/env bash
# scripts/sdk/index.sh
#
# 为一个含 ipk/apk 的目录树生成 OpenWrt 标准的 Packages.gz / APKINDEX.tar.gz
# 索引文件。Pool finalize 阶段调用,host-native (借 SDK 自带的 ipkg-make-index.sh
# + 系统 apk 命令), 不需要 docker。
#
# 用法:
#   sdk/index.sh \
#       --pool-dir <DIR>         必填,含 <arch>/<feed>/*.ipk 的目录树
#       --sdk-dir <SDK_ROOT>     必填,已解压 SDK 根 (借 scripts/ipkg-make-index.sh + apk)
#
# 输出:
#   <DIR>/**/Packages, Packages.gz  (ipk 目录)
#   <DIR>/**/APKINDEX.tar.gz        (apk 目录)

set -euo pipefail

POOL_DIR=""
SDK_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --pool-dir) POOL_DIR="$2"; shift 2 ;;
        --sdk-dir)  SDK_DIR="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::sdk/index: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$POOL_DIR" ] || { echo "::error::sdk/index: 缺少 --pool-dir" >&2; exit 2; }
[ -n "$SDK_DIR"  ] || { echo "::error::sdk/index: 缺少 --sdk-dir"  >&2; exit 2; }

POOL_DIR="$(cd "$POOL_DIR" && pwd)"
SDK_DIR="$(cd "$SDK_DIR" && pwd)"

# ipkg-make-index.sh 只在 SDK tar 内,IB tar 没有 — 因此这里做软检查,
# 真正用到(目录里有 ipk)时再硬失败,避免纯 apk 场景把 IB 也卡在前置检查。
IPKG_INDEX="$SDK_DIR/scripts/ipkg-make-index.sh"

# SDK 的 host 工具链放在 staging_dir/host/bin,放 PATH 顶部以便 apk / gzip 等工具可用
if [ -d "$SDK_DIR/staging_dir/host/bin" ]; then
    export PATH="$SDK_DIR/staging_dir/host/bin:$PATH"
fi

found_any=0
while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    found_any=1
    echo "::group::sdk/index: $dir"

    if compgen -G "$dir/*.ipk" >/dev/null; then
        if [ ! -x "$IPKG_INDEX" ]; then
            echo "::error::sdk/index: 目录 $dir 含 ipk 但 $SDK_DIR 缺 scripts/ipkg-make-index.sh — 传入的 --sdk-dir 必须是 SDK 根,不能是 IB 根。" >&2
            exit 1
        fi
        "$IPKG_INDEX" "$dir" > "$dir/Packages"
        gzip -9nc "$dir/Packages" > "$dir/Packages.gz"
        echo "  ipk: $(find "$dir" -maxdepth 1 -name '*.ipk' | wc -l | tr -d ' ') 个 → Packages.gz"
    fi

    if compgen -G "$dir/*.apk" >/dev/null; then
        if command -v apk >/dev/null 2>&1; then
            apk mkndx -o "$dir/APKINDEX.tar.gz" "$dir"/*.apk 2>/dev/null || \
                echo "::warning::sdk/index: apk mkndx 失败于 $dir"
            echo "  apk: $(find "$dir" -maxdepth 1 -name '*.apk' | wc -l | tr -d ' ') 个 → APKINDEX.tar.gz"
        else
            echo "::warning::sdk/index: apk 不可用,跳过 $dir 的 APKINDEX 生成"
        fi
    fi
    echo "::endgroup::"
done < <(find "$POOL_DIR" -type f \( -name "*.ipk" -o -name "*.apk" \) -exec dirname {} \; | sort -u)

if [ "$found_any" = "0" ]; then
    echo "::warning::sdk/index: $POOL_DIR 下未发现 ipk/apk 文件,无索引生成。"
fi
