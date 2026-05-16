#!/usr/bin/env bash
# scripts/lib/expand-packages.sh
#
# preset 套餐方案的 packages.list 解析器。devices/<dev>/packages.list 的语法:
#
#   @preset <name>     展开为 common/presets/<name>.list 的所有包 (前缀视为 +)
#                      <name> 可以下划线开头 (如 @preset _extras 显式引用游离池)
#   +<pkg>             装这个包 (输出 +pkg)
#   -<pkg>             从 IB DEFAULT_PACKAGES 排除 (输出 -pkg)
#   # 整行/行尾注释    OK
#   空行                OK
#
# 函数:
#   expand_packages <packages.list> <presets_dir>
#       展开 packages.list,输出一行一项,带 +/- 前缀,首次出现顺序去重保序
#
#   expand_packages_for_ib <packages.list> <presets_dir>
#       同上,但输出格式贴近 IB `make image PACKAGES=...` 喂值 (空格分隔单行)
#
# 用法 (source):
#   source scripts/lib/expand-packages.sh
#   pkgs=$(expand_packages devices/mt3600be/packages.list common/presets)
#
# 用法 (CLI):
#   bash scripts/lib/expand-packages.sh devices/mt3600be/packages.list common/presets

# shellcheck source=./pkg-filter.sh
# BASH_SOURCE 在 zsh 下不存在; 用 ${BASH_SOURCE[0]:-$0} fallback 兼容
SCRIPT_LIB_DIR_EXPAND="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=./pkg-filter.sh
source "$SCRIPT_LIB_DIR_EXPAND/pkg-filter.sh"

# 内部: 展开一个 preset 文件,输出裸包名 (一行一个),不带 +/-
# 调用方负责处理 +/- 语义
_expand_preset_to_plain() {
    local preset_file="$1"
    [ -f "$preset_file" ] || {
        echo "::error::expand-packages: preset 文件不存在: $preset_file" >&2
        return 1
    }
    pkg_filter_clean error < "$preset_file"
}

expand_packages() {
    local list_file="$1"
    local presets_dir="$2"

    [ -f "$list_file"   ] || { echo "::error::expand-packages: $list_file 不存在" >&2; return 1; }
    [ -d "$presets_dir" ] || { echo "::error::expand-packages: $presets_dir 不存在" >&2; return 1; }

    # awk 解析 packages.list: 输出 (token, prefix) 形式给后续 dedup
    # token 可能是 @preset 行或单个 +/-pkg
    local tmp
    tmp="$(mktemp)"

    awk '
        { sub(/[[:space:]]+#.*$/, "") }   # 行尾注释
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
        $0 == ""  { next }
        /^#/      { next }
        /^@preset[[:space:]]+/ {
            name = $0
            sub(/^@preset[[:space:]]+/, "", name)
            print "PRESET " name
            next
        }
        /^\+/ {
            pkg = substr($0, 2)
            sub(/^[[:space:]]+/, "", pkg)
            print "PLUS " pkg
            next
        }
        /^-/ {
            pkg = substr($0, 2)
            sub(/^[[:space:]]+/, "", pkg)
            print "MINUS " pkg
            next
        }
        {
            printf "::error::expand-packages: 无法解析行: %s (期望 @preset/+pkg/-pkg)\n", $0 > "/dev/stderr"
            exit 2
        }
    ' "$list_file" > "$tmp" || return $?

    # 第二遍: 按出现顺序展开 PRESET → +pkg, 直接输出 PLUS/MINUS
    # 用 awk 的 seen[] 数组同时跨 preset 跟 packages.list 去重
    awk -v presets_dir="$presets_dir" '
        BEGIN { rc = 0 }
        $1 == "PRESET" {
            name = $2
            file = presets_dir "/" name ".list"
            if ((getline _ < file) < 0) {
                printf "::error::expand-packages: preset 不存在: %s (file=%s)\n", name, file > "/dev/stderr"
                rc = 1; exit rc
            }
            close(file)
            while ((getline line < file) > 0) {
                sub(/[[:space:]]+#.*$/, "", line)
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                if (line == "" || line ~ /^#/) continue
                if (line ~ /^kmod-/) {
                    printf "::error::expand-packages: preset %s 含 kmod %s (kmod 走 base-config)\n", name, line > "/dev/stderr"
                    rc = 1; exit rc
                }
                if (!seen[line]++) print "+" line
            }
            close(file)
            next
        }
        $1 == "PLUS" {
            pkg = $2
            if (!seen[pkg]++) print "+" pkg
            next
        }
        $1 == "MINUS" {
            # MINUS 用独立命名空间, 不跟 + 共享 seen (允许同一包先 + 后 -, 或单独 -)
            if (!minus_seen[$2]++) print "-" $2
            next
        }
        END { exit rc }
    ' "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

# IB make image PACKAGES= 喂值: 单行空格分隔, 剥掉 '+' 前缀 (IB 不识别),
# 保留 '-' 前缀 (IB Makefile L143-147 filter-out -% 处理排除项)
expand_packages_for_ib() {
    expand_packages "$1" "$2" | sed 's/^+//' | tr '\n' ' '
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    if [ $# -lt 2 ]; then
        cat >&2 <<EOF
用法: bash $0 <packages.list> <presets_dir>
EOF
        exit 2
    fi
    expand_packages "$1" "$2"
fi
