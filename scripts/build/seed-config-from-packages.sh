#!/usr/bin/env bash
# scripts/build/seed-config-from-packages.sh
#
# 把「裸包名清单」翻译为 OpenWrt 的 .config 片段。
# 上游脚本（pool / tier3）只关心包名，让 buildroot 的 make defconfig 自己解依赖。
#
# 用法:
#   printf 'nftables-json\nwireguard-tools\n' | bash seed-config-from-packages.sh >> .config
#
# 输入规则:
#   - 一行一个包名
#   - 支持整行 #注释、行尾 #注释、空行
#   - kmod-* 一律跳过并 warning（kmod 由 base-config + 完整 buildroot 负责，
#     SDK 容器内做 CONFIG_PACKAGE_kmod-xxx=m 没意义，内核 .config 已固化）
#
# 输出:
#   每个有效包名一行: CONFIG_PACKAGE_<name>=m

set -euo pipefail

sed -E '
    s/[[:space:]]+#.*//
    s/^[[:space:]]+//
    s/[[:space:]]+$//
    /^$/d
    /^#/d
' | while IFS= read -r pkg; do
    case "$pkg" in
        kmod-*)
            echo "::warning::seed-config-from-packages: skipping kmod entry '$pkg' (kmod must be declared in common/base-config)" >&2
            ;;
        *)
            printf 'CONFIG_PACKAGE_%s=m\n' "$pkg"
            ;;
    esac
done
