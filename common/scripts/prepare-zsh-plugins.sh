#!/usr/bin/env bash
# 脚本职责：根据最终构建配置准备 Zsh 插件资产
set -euo pipefail

TARGET_DIR="files"
ZSH_PLUGIN_DIR="${TARGET_DIR}/root/.zsh"

if ! grep -q '^CONFIG_PACKAGE_zsh=y' .config 2>/dev/null; then
    echo "    - 未启用 zsh，跳过插件准备"
    exit 0
fi

mkdir -p "$ZSH_PLUGIN_DIR"

clone_plugin() {
    local name="$1" url="$2"
    if [[ ! -d "${ZSH_PLUGIN_DIR}/${name}" ]]; then
        echo "    - 正在下载插件: ${name}"
        git clone --depth 1 --quiet "$url" "${ZSH_PLUGIN_DIR}/${name}"
    else
        echo "    - 插件已存在: ${name}"
    fi
}

clone_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
clone_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting"
