#!/usr/bin/env bash
# scripts/lib/extract-config.sh
#
# 解析 OpenWrt .config 文件的纯函数库。所有函数读输入文件路径、向 stdout 输出。
# 不修改文件、不依赖工作目录。
#
# 兼容两种格式：
#   - 种子格式（devices/<dev>/.config）：
#       CONFIG_TARGET_<main>=y
#       CONFIG_TARGET_<main>_<sub>=y
#       CONFIG_TARGET_<main>_<sub>_DEVICE_<profile>=y
#       CONFIG_PACKAGE_<pkg>=y
#       # @arch <arch_packages>          (Phase 4 引入的 arch 注释约定)
#   - defconfig 后格式（OpenWrt build dir 的 .config）：
#       CONFIG_TARGET_BOARD="<main>"
#       CONFIG_TARGET_SUBTARGET="<sub>"
#       CONFIG_TARGET_PROFILE="DEVICE_<profile>"
#       CONFIG_TARGET_ARCH_PACKAGES="<arch>"
#
# 用法（source 后调用）：
#   source scripts/lib/extract-config.sh
#   pkgs=$(extract_packages devices/mt3600be/.config)
#   target=$(extract_target devices/mt3600be/.config)

# 输出所有 CONFIG_PACKAGE_*=y/=m 启用的官方包名（每行一个，不含 CONFIG_PACKAGE_ 前缀）。
# 适用：种子格式 + defconfig 后格式（两者都有 CONFIG_PACKAGE_*=y/m 行）。
extract_packages() {
    local config="$1"
    [ -f "$config" ] || return 0
    grep -E '^CONFIG_PACKAGE_.*=[ym]$' "$config" \
        | sed -E 's/^CONFIG_PACKAGE_(.*)=[ym]$/\1/' \
        || true
}

# 输出 "<target>/<subtarget>"，例如 "mediatek/filogic"。
# 优先 defconfig 后格式（CONFIG_TARGET_BOARD/SUBTARGET），fallback 种子格式。
extract_target() {
    local config="$1"
    [ -f "$config" ] || return 0

    # defconfig 后格式优先
    local board sub
    board=$(grep -E '^CONFIG_TARGET_BOARD=' "$config" | cut -d'"' -f2)
    sub=$(grep -E '^CONFIG_TARGET_SUBTARGET=' "$config" | cut -d'"' -f2)
    if [ -n "$board" ] && [ -n "$sub" ]; then
        echo "${board}/${sub}"
        return 0
    fi

    # 种子格式 fallback：CONFIG_TARGET_<a>=y（无下划线）+ CONFIG_TARGET_<a>_<b>=y
    local main
    main=$(grep -E '^CONFIG_TARGET_[a-zA-Z0-9]+=y$' "$config" \
            | head -1 \
            | sed -E 's/^CONFIG_TARGET_([a-zA-Z0-9]+)=y$/\1/')
    [ -z "$main" ] && return 0
    sub=$(grep -E "^CONFIG_TARGET_${main}_[a-zA-Z0-9-]+=y$" "$config" \
            | head -1 \
            | sed -E "s/^CONFIG_TARGET_${main}_([a-zA-Z0-9-]+)=y\$/\1/")
    [ -z "$sub" ] && return 0
    echo "${main}/${sub}"
}

# 输出 OpenWrt `make image PROFILE=...` 用的 profile 名，
# 例如 "glinet_gl-mt3600be"（去掉 DEVICE_ 前缀）。
extract_profile() {
    local config="$1"
    [ -f "$config" ] || return 0

    # defconfig 后格式优先
    local raw
    raw=$(grep -E '^CONFIG_TARGET_PROFILE=' "$config" | cut -d'"' -f2)
    if [ -n "$raw" ]; then
        echo "${raw#DEVICE_}"
        return 0
    fi

    # 种子格式 fallback：CONFIG_TARGET_<a>_<b>_DEVICE_<profile>=y
    grep -E '^CONFIG_TARGET_.*_DEVICE_.+=y$' "$config" \
        | head -1 \
        | sed -E 's/^CONFIG_TARGET_.*_DEVICE_(.+)=y$/\1/' \
        || true
}

# 输出 architecture（用于 ipk 命名/cache key），例如 "aarch64_cortex-a53"。
# 种子 .config 没有此字段——靠 # @arch <value> 注释约定提供（Phase 4 引入）。
extract_arch() {
    local config="$1"
    [ -f "$config" ] || return 0

    # defconfig 后格式优先
    local arch
    arch=$(grep -E '^CONFIG_TARGET_ARCH_PACKAGES=' "$config" | cut -d'"' -f2)
    if [ -n "$arch" ]; then
        echo "$arch"
        return 0
    fi

    # 种子格式 fallback：# @arch <value>
    grep -E '^#[[:space:]]*@arch[[:space:]]+' "$config" \
        | head -1 \
        | awk '{print $3}' \
        || true
}
