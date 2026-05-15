#!/usr/bin/env bash
# scripts/lib/pkg-filter.sh
#
# 包名清单清洗的唯一权威。所有「从 custom-packages.txt 或 missing JSON 出来的
# 包名列表」入口都该走这里,避免 sed/grep 规则散落在多个脚本。
#
# 用法 (source 后作为 bash 函数调用):
#   source scripts/lib/pkg-filter.sh
#   pkg_filter_clean strip < raw.txt > clean.txt
#
# 用法 (CLI 直接调用):
#   bash scripts/lib/pkg-filter.sh strip < raw.txt > clean.txt
#
# 输入格式 (stdin):
#   - 一行一个包名
#   - 整行 #注释 / 空行 / 行尾 #注释 / 首尾空白 全部容忍
#
# 输出格式 (stdout):
#   - 清洗后的纯包名,一行一个,保持原始顺序(下游 chunk 切分依赖顺序稳定)
#
# kmod-policy:
#   keep    保留 kmod-* 原样          (SDK 能编 kmod — Module.symvers + 预编 *.ko
#                                      已经在 SDK tar 内,见上游 target/sdk/Makefile:81,113;
#                                      Tier3 补编路径默认用这个,避免误剥)
#   strip   静默剔除所有 kmod-*       (旧默认,保留作 fallback)
#   warn    剔除并 stderr warning      (seed-config 等用户可见入口)
#   error   发现 kmod-* 即 exit 1     (pool 清单守门,见 select-chunk)

pkg_filter_is_kmod() {
    case "$1" in
        kmod-*) return 0 ;;
        *)      return 1 ;;
    esac
}

pkg_filter_clean() {
    local policy="${1:-strip}"
    case "$policy" in
        keep|strip|warn|error) ;;
        *)
            printf '::error::pkg_filter_clean: unknown policy %q (expect keep|strip|warn|error)\n' "$policy" >&2
            return 2
            ;;
    esac

    awk -v policy="$policy" '
        BEGIN { had_kmod_error = 0 }
        {
            sub(/[[:space:]]+#.*$/, "")
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            if ($0 == "" || $0 ~ /^#/) next

            if ($0 ~ /^kmod-/) {
                if (policy == "keep") {
                    print; next
                } else if (policy == "strip") {
                    next
                } else if (policy == "warn") {
                    printf "::warning::pkg-filter: skipping kmod entry %s (kmod must be declared in common/base-config)\n", $0 > "/dev/stderr"
                    next
                } else {
                    printf "::error::pkg-filter: kmod %s not allowed here (declare in common/base-config as CONFIG_PACKAGE_%s=m)\n", $0, $0 > "/dev/stderr"
                    had_kmod_error = 1
                    next
                }
            }
            print
        }
        END { if (had_kmod_error) exit 1 }
    '
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    pkg_filter_clean "${1:-strip}"
fi
