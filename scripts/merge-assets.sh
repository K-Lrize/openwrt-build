#!/usr/bin/env bash
# 脚本职责：合并通用文件层与设备特定文件层
set -euo pipefail

DEVICE="${1:?用法: $0 <device_id>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

COMMON_DIR="${CONF_DIR}/common"
DEVICE_DIR="${CONF_DIR}/devices/${DEVICE}"
TARGET_DIR="files" # OpenWrt 源码根目录下的 files 目录会被自动打包进固件

echo "::group::合并固件文件层"
mkdir -p "$TARGET_DIR"

# 1. 应用通用文件层 (所有设备共用)
if [[ -d "${COMMON_DIR}/files" ]]; then
    echo "应用通用文件层。"
    rsync -a "${COMMON_DIR}/files/" "$TARGET_DIR/"
fi

# 2. 应用设备特定文件层 (覆盖通用资产)
if [[ -d "${DEVICE_DIR}/files" ]]; then
    echo "应用设备文件层: ${DEVICE}"
    rsync -a "${DEVICE_DIR}/files/" "$TARGET_DIR/"
fi
echo "::endgroup::"
