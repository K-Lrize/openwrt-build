#!/usr/bin/env bash
# 脚本职责：执行通用与设备专属的固件定制脚本
set -euo pipefail

DEVICE="${1:?用法: $0 <device_id>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

COMMON_SCRIPT_DIR="${CONF_DIR}/common/scripts"
DEVICE_SCRIPT_DIR="${CONF_DIR}/devices/${DEVICE}/scripts"

run_script_dir() {
    local label="$1"
    local dir="$2"

    [[ -d "$dir" ]] || return 0

    local scripts=()
    while IFS= read -r script; do
        scripts+=("$script")
    done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' | sort)

    [[ ${#scripts[@]} -gt 0 ]] || return 0

    echo "::group::执行${label}固件脚本"
    for script in "${scripts[@]}"; do
        echo "运行脚本: $(basename "$script")"
        DEVICE="$DEVICE" CONFIG_REPO_DIR="$CONF_DIR" bash "$script"
    done
    echo "::endgroup::"
}

run_script_dir "通用" "$COMMON_SCRIPT_DIR"
run_script_dir "设备 [${DEVICE}] 专属" "$DEVICE_SCRIPT_DIR"
