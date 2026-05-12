#!/usr/bin/env bash
# common/scripts/prepare-zsh-plugins.sh
#
# 当 .config 启用 zsh 时，git clone 常用 zsh 插件到 files/root/.zsh/。
# 双路径兼容：
#   - buildroot 路径（默认）：cwd 是 OpenWrt 源码根目录，使用 cwd 的 .config 与 files/
#       bash prepare-zsh-plugins.sh
#   - IB 路径（显式参数）：在 IB 容器中 cwd 是 /home/builder，需指定 build-config
#                          仓库内的 device .config 路径
#       bash prepare-zsh-plugins.sh /path/to/devices/<dev>/.config files

set -euo pipefail

CONFIG_FILE="${1:-.config}"
FILES_DIR="${2:-files}"
ZSH_PLUGIN_DIR="${FILES_DIR}/root/.zsh"

if ! grep -q '^CONFIG_PACKAGE_zsh=y' "$CONFIG_FILE" 2>/dev/null; then
    echo "    - 未启用 zsh，跳过插件准备 ($CONFIG_FILE)"
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

clone_plugin "zsh-autosuggestions"     "https://github.com/zsh-users/zsh-autosuggestions"
clone_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting"
