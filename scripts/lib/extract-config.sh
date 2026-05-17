#!/usr/bin/env bash
# scripts/lib/extract-config.sh
#
# 解析 OpenWrt .config 文件的纯函数库。所有函数读输入文件路径、向 stdout 输出。
# 不修改文件、不依赖工作目录。
#
# 兼容两种格式:
#   - 设备 .config (devices/<dev>/.config, 单一事实源):
#       # arch:    <arch_packages>     (顶部注释)
#       # ib-url:  <url>                (IB tar 拉取地址)
#       # sdk-url: <url>                (SDK tar 拉取地址)
#       CONFIG_TARGET_<main>=y
#       CONFIG_TARGET_<main>_<sub>=y
#       CONFIG_TARGET_<main>_<sub>_DEVICE_<profile>=y
#       CONFIG_PACKAGE_xxx=y / =m / # ... is not set
#       CONFIG_SING_BOX_WITH_*=y               (包子选项, IB SDK 阶段消费)
#   - defconfig 后格式 (OpenWrt build dir 的 .config):
#       CONFIG_TARGET_BOARD="<main>"
#       CONFIG_TARGET_SUBTARGET="<sub>"
#       CONFIG_TARGET_PROFILE="DEVICE_<profile>"
#       CONFIG_TARGET_ARCH_PACKAGES="<arch>"
#
# 用法 (source 后调用):
#   source scripts/lib/extract-config.sh
#   target=$(extract_target devices/mt3600be/.config)
#   profile=$(extract_profile devices/mt3600be/.config)
#   arch=$(extract_arch devices/mt3600be/.config)
#   ib_url=$(extract_ib_url devices/mt3600be/.config)
#   sdk_url=$(extract_sdk_url devices/mt3600be/.config)
#
# 设备包清单走 scripts/lib/config-to-ib-packages.sh, IB 阶段把
# CONFIG_PACKAGE_*=y/m / # ... is not set 翻译成 IB PACKAGES= 喂值.

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

# 输出 # ib-url: <URL> 注释里的 URL (设备 .config 顶部),
# 即拉 IB tar 的来源. 缺省时输出空串.
extract_ib_url() {
    local config="$1"
    [ -f "$config" ] || return 0
    grep -E '^#[[:space:]]*ib-url:[[:space:]]+' "$config" \
        | head -1 | sed -E 's/^#[[:space:]]*ib-url:[[:space:]]+//' | awk '{print $1}' || true
}

# 输出 # sdk-url: <URL> 注释里的 URL.
extract_sdk_url() {
    local config="$1"
    [ -f "$config" ] || return 0
    grep -E '^#[[:space:]]*sdk-url:[[:space:]]+' "$config" \
        | head -1 | sed -E 's/^#[[:space:]]*sdk-url:[[:space:]]+//' | awk '{print $1}' || true
}

# 输出 architecture（用于 ipk 命名/cache key），例如 "aarch64_cortex-a53"。
#
# 推导规则:
#   - 优先读 defconfig 后格式 CONFIG_TARGET_ARCH_PACKAGES="<arch>" (buildroot 完成后才有)
#   - 否则读设备 .config 顶部 `# arch: <name>` 注释
#
# 加新设备零代码改动: devices/<dev>/.config 顶部写一行 `# arch: <name>` 即可。
extract_arch() {
    local config="$1"
    [ -f "$config" ] || return 0

    # 1. defconfig 后格式优先 (buildroot workdir 内调用时)
    local arch
    arch=$(grep -E '^CONFIG_TARGET_ARCH_PACKAGES=' "$config" | cut -d'"' -f2)
    if [ -n "$arch" ]; then
        echo "$arch"
        return 0
    fi

    # 2. # arch: 注释 (设备 .config 顶部)
    arch=$(grep -E '^#[[:space:]]*arch:[[:space:]]+' "$config" \
            | head -1 | sed -E 's/^#[[:space:]]*arch:[[:space:]]+//' | awk '{print $1}')
    if [ -n "$arch" ]; then
        echo "$arch"
        return 0
    fi
}
