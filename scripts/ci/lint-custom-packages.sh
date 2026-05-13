#!/usr/bin/env bash
# scripts/ci/lint-custom-packages.sh
#
# 静态校验 common/custom-packages.txt：
#   - 每行只允许「合法包名」或「整行 # 注释」或「空行」；
#     合法包名字符集：[a-zA-Z0-9._+-]+，允许行尾 # 注释。
#   - 禁止 kmod-*（kmod 走 common/base-config，由完整 buildroot 处理；
#     SDK 容器无法编译 base-config 之外的 kmod 符号）。
#   - 同一包名禁止重复。
#
# 失败 exit 1，stdout 给可读报告，便于 GHA log 直接读。
#
# 用法:
#   bash scripts/ci/lint-custom-packages.sh [path]
#   默认 path: <repo>/common/custom-packages.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIST_FILE="${1:-$CONF_DIR/common/custom-packages.txt}"

if [ ! -f "$LIST_FILE" ]; then
    echo "::error::custom-packages 清单不存在: $LIST_FILE"
    exit 1
fi

errors=0
declare -A seen
lineno=0

while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))

    # 整行注释 / 空白行：直接放行
    case "$raw" in
        ''|\#*) continue ;;
    esac
    if [[ "$raw" =~ ^[[:space:]]*$ ]]; then
        continue
    fi
    if [[ "$raw" =~ ^[[:space:]]*# ]]; then
        continue
    fi

    # 剥掉行尾注释 + 首尾空白
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue

    # 字符集校验
    if [[ ! "$line" =~ ^[a-zA-Z0-9._+-]+$ ]]; then
        echo "::error file=${LIST_FILE},line=${lineno}::非法字符或行内空白：'${raw}'"
        errors=$((errors + 1))
        continue
    fi

    # kmod 禁令
    if [[ "$line" == kmod-* ]]; then
        echo "::error file=${LIST_FILE},line=${lineno}::禁止在 pool 清单写 kmod：'${line}'（应在 common/base-config 用 CONFIG_PACKAGE_${line}=m 声明）"
        errors=$((errors + 1))
        continue
    fi

    # 重名检查
    if [ -n "${seen[$line]:-}" ]; then
        echo "::error file=${LIST_FILE},line=${lineno}::重复包名 '${line}'，已于第 ${seen[$line]} 行出现"
        errors=$((errors + 1))
        continue
    fi
    seen[$line]=$lineno
done < "$LIST_FILE"

total=${#seen[@]}
if [ "$errors" -gt 0 ]; then
    echo "::error::custom-packages 校验失败，共 ${errors} 个问题；通过校验的包数: ${total}"
    exit 1
fi

echo "custom-packages 校验通过：${total} 个有效包名。"
