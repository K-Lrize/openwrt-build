#!/usr/bin/env bash
# scripts/ci/lint-presets.sh
#
# 静态校验 G2 套餐方案的配置一致性:
#
#   1. common/presets/*.list
#      - 每行合法包名 / 整行 # 注释 / 空行
#      - 合法包名字符集: [a-zA-Z0-9._+-]+
#      - 禁止 kmod-* (走 common/base-config)
#      - 同一 preset 内重复 → 错
#      - 跨 preset 重复 → 警告 (可接受, 但建议归一)
#
#   2. devices/*/target.conf
#      - 顶部必须有 `# arch: <name>` (架构不变量 #6)
#      - 必须有 CONFIG_TARGET_<board>=y / _<sub>=y / _DEVICE_<profile>=y
#
#   3. devices/*/packages.list
#      - 每行匹配 `@preset <name>` / `+<pkg>` / `-<pkg>` / 整行注释 / 空行
#      - @preset 引用的 name 必须存在于 common/presets/<name>.list
#      - +<pkg> 必须能在 presets union 里找到 (否则 IB make image 会缺包)
#      - -<pkg> 不强制存在性检查 (常用来排除 IB DEFAULT_PACKAGES 默认包)
#
# 失败 exit 1, stdout 给可读报告。
#
# 用法:
#   bash scripts/ci/lint-presets.sh [conf-dir]   # 缺省: <repo-root>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CONF_DIR="$(cd "$CONF_DIR" && pwd)"

PRESETS_DIR="$CONF_DIR/common/presets"
DEVICES_DIR="$CONF_DIR/devices"

errors=0

# ─────────────────────────────────────────────────────────────
# 1. 校验 presets/*.list
# ─────────────────────────────────────────────────────────────
if [ ! -d "$PRESETS_DIR" ]; then
    echo "::error::lint-presets: $PRESETS_DIR 不存在 (G2 套餐方案要求)"
    exit 1
fi

declare -A pkg_to_preset     # pkg → first preset (warn 跨 preset 重复)

for preset_file in "$PRESETS_DIR"/*.list; do
    [ -f "$preset_file" ] || continue
    preset_name="$(basename "$preset_file" .list)"
    lineno=0
    declare -A seen_in_this_preset=()

    while IFS= read -r raw || [ -n "$raw" ]; do
        lineno=$((lineno + 1))

        case "$raw" in
            ''|\#*) continue ;;
        esac
        [[ "$raw" =~ ^[[:space:]]*$ ]] && continue
        [[ "$raw" =~ ^[[:space:]]*# ]] && continue

        line="${raw%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue

        if [[ ! "$line" =~ ^[a-zA-Z0-9._+-]+$ ]]; then
            echo "::error file=common/presets/${preset_name}.list,line=${lineno}::非法字符或行内空白: '${raw}'"
            errors=$((errors + 1))
            continue
        fi

        if [[ "$line" == kmod-* ]]; then
            echo "::error file=common/presets/${preset_name}.list,line=${lineno}::禁止在 preset 写 kmod: '${line}' (走 common/base-config 用 CONFIG_PACKAGE_${line}=m)"
            errors=$((errors + 1))
            continue
        fi

        if [ -n "${seen_in_this_preset[$line]:-}" ]; then
            echo "::error file=common/presets/${preset_name}.list,line=${lineno}::同一 preset 内重复包 '${line}' (上次在第 ${seen_in_this_preset[$line]} 行)"
            errors=$((errors + 1))
            continue
        fi
        seen_in_this_preset[$line]=$lineno

        if [ -n "${pkg_to_preset[$line]:-}" ]; then
            if [ "${pkg_to_preset[$line]}" != "$preset_name" ]; then
                echo "::warning file=common/presets/${preset_name}.list,line=${lineno}::包 '${line}' 也在 preset '${pkg_to_preset[$line]}' 出现 — pool 编译会去重, 但建议归一到单个套餐"
            fi
        else
            pkg_to_preset[$line]=$preset_name
        fi
    done < "$preset_file"

    pkg_count="${#seen_in_this_preset[@]}"
    echo "  preset ${preset_name}: ${pkg_count} 个包"
    unset seen_in_this_preset
done

echo "  跨 preset 唯一包总数: ${#pkg_to_preset[@]}"

# ─────────────────────────────────────────────────────────────
# 2. 校验 devices/*/target.conf + packages.list
# ─────────────────────────────────────────────────────────────
if [ ! -d "$DEVICES_DIR" ]; then
    echo "::warning::lint-presets: $DEVICES_DIR 不存在, 跳过 device 校验"
else
    for dev_dir in "$DEVICES_DIR"/*/; do
        [ -d "$dev_dir" ] || continue
        dev="$(basename "$dev_dir")"
        target_conf="$dev_dir/target.conf"
        pkg_list="$dev_dir/packages.list"

        if [ ! -f "$target_conf" ]; then
            echo "::error file=devices/${dev}/::缺 target.conf"
            errors=$((errors + 1))
        else
            if ! grep -qE '^#[[:space:]]*arch:[[:space:]]+' "$target_conf"; then
                echo "::error file=devices/${dev}/target.conf::缺顶部 '# arch: <name>' 注释 (架构不变量 #6)"
                errors=$((errors + 1))
            fi
            if ! grep -qE '^CONFIG_TARGET_[a-zA-Z0-9]+=y$' "$target_conf"; then
                echo "::error file=devices/${dev}/target.conf::缺 CONFIG_TARGET_<board>=y 行"
                errors=$((errors + 1))
            fi
            if ! grep -qE '^CONFIG_TARGET_.*_DEVICE_.+=y$' "$target_conf"; then
                echo "::error file=devices/${dev}/target.conf::缺 CONFIG_TARGET_..._DEVICE_<profile>=y 行"
                errors=$((errors + 1))
            fi
        fi

        if [ ! -f "$pkg_list" ]; then
            echo "::error file=devices/${dev}/::缺 packages.list"
            errors=$((errors + 1))
            continue
        fi

        lineno=0
        while IFS= read -r raw || [ -n "$raw" ]; do
            lineno=$((lineno + 1))

            stripped="${raw%%#*}"
            stripped="${stripped#"${stripped%%[![:space:]]*}"}"
            stripped="${stripped%"${stripped##*[![:space:]]}"}"
            [ -n "$stripped" ] || continue

            if [[ "$stripped" =~ ^@preset[[:space:]]+([a-zA-Z0-9._+-]+)$ ]]; then
                preset_name="${BASH_REMATCH[1]}"
                if [ ! -f "$PRESETS_DIR/${preset_name}.list" ]; then
                    echo "::error file=devices/${dev}/packages.list,line=${lineno}::@preset 引用不存在的套餐: '${preset_name}' (期望 common/presets/${preset_name}.list)"
                    errors=$((errors + 1))
                fi
                continue
            fi

            if [[ "$stripped" =~ ^\+([a-zA-Z0-9._+-]+)$ ]]; then
                pkg="${BASH_REMATCH[1]}"
                if [ -z "${pkg_to_preset[$pkg]:-}" ]; then
                    echo "::error file=devices/${dev}/packages.list,line=${lineno}::+${pkg} 不在任何 preset 内 (pool 不会编, IB 会缺包; 请加到对应 preset 或 _extras.list)"
                    errors=$((errors + 1))
                fi
                continue
            fi

            if [[ "$stripped" =~ ^-[a-zA-Z0-9._+-]+$ ]]; then
                continue
            fi

            echo "::error file=devices/${dev}/packages.list,line=${lineno}::无法识别的行: '${raw}' (期望 @preset/+pkg/-pkg)"
            errors=$((errors + 1))
        done < "$pkg_list"

        echo "  device ${dev}: OK"
    done
fi

if [ "$errors" -gt 0 ]; then
    echo "::error::lint-presets: ${errors} 个问题"
    exit 1
fi
echo "lint-presets: 全部通过"
