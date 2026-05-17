#!/usr/bin/env bash
# scripts/lib/config-to-ib-packages.sh
#
# 把 buildroot KConfig 格式的 .config 翻译成 IB `make image PACKAGES=...` 喂值.
# 单一事实源原则: devices/<dev>/.config 同时给两条链路 (全量 buildroot / IB) 用,
# IB 不读 .config, 由本工具翻译成 +/- 字符串.
#
# 规则:
#   CONFIG_PACKAGE_<pkg>=y         → <pkg>      (不要 + 前缀)
#   CONFIG_PACKAGE_<pkg>=m         → <pkg>      (IB 视为装)
#   # CONFIG_PACKAGE_<pkg> is not set → -<pkg>  (从 DEFAULT_PACKAGES 排除)
#   其他全部忽略 (CONFIG_TARGET_*, CONFIG_SING_BOX_*, CONFIG_DEVEL/IB/SDK, ...)
#
# 输入: argv1 = .config 路径 (缺省读 stdin)
# 输出: stdout = "pkg1 pkg2 -pkg3 ..." (单行, 末尾无换行)
#
# 用法:
#   PACKAGES=$(bash scripts/lib/config-to-ib-packages.sh devices/mt3600be/.config)

set -euo pipefail

if [ $# -ge 1 ]; then
    [ -f "$1" ] || { echo "::error::config-to-ib-packages: $1 不存在" >&2; exit 1; }
    exec < "$1"
fi

awk '
    /^CONFIG_PACKAGE_[A-Za-z0-9._+-]+=[ym]$/ {
        sub(/^CONFIG_PACKAGE_/, "")
        sub(/=.*$/, "")
        printf "%s ", $0
    }
    /^# CONFIG_PACKAGE_[A-Za-z0-9._+-]+ is not set$/ {
        sub(/^# CONFIG_PACKAGE_/, "")
        sub(/ is not set$/, "")
        printf "-%s ", $0
    }
'
