#!/usr/bin/env bash
# scripts/lib/extract-config.sh
#
# 解析 OpenWrt .config 文件的纯函数库。所有函数读输入文件路径、向 stdout 输出。
# 不修改文件、不依赖工作目录。
#
# 兼容两种格式：
#   - 种子格式（devices/<dev>/target.conf）：
#       # arch: <arch_packages>          (顶部注释, 架构不变量 #6)
#       CONFIG_TARGET_<main>=y
#       CONFIG_TARGET_<main>_<sub>=y
#       CONFIG_TARGET_<main>_<sub>_DEVICE_<profile>=y
#   - defconfig 后格式（OpenWrt build dir 的 .config）：
#       CONFIG_TARGET_BOARD="<main>"
#       CONFIG_TARGET_SUBTARGET="<sub>"
#       CONFIG_TARGET_PROFILE="DEVICE_<profile>"
#       CONFIG_TARGET_ARCH_PACKAGES="<arch>"
#
# 用法（source 后调用）：
#   source scripts/lib/extract-config.sh
#   target=$(extract_target devices/mt3600be/target.conf)
#   profile=$(extract_profile devices/mt3600be/target.conf)
#   arch=$(extract_arch devices/mt3600be/target.conf)
# 设备级包清单走 scripts/lib/expand-packages.sh 解析 packages.list, 不再用 extract_packages。

# 已废弃 (新代码用 scripts/lib/expand-packages.sh): 从 defconfig 后的 .config 读
# CONFIG_PACKAGE_xxx=y/=m → 输出 'xxx' (IB make image PACKAGES= 喂值),
# # CONFIG_PACKAGE_xxx is not set → 输出 '-xxx' (从 IB DEFAULT_PACKAGES 排除)。
# 仅 buildroot workdir 内仍可用 (firmware-full.yml 的兼容路径)。
extract_packages() {
    local config="$1"
    [ -f "$config" ] || return 0
    grep -E '^CONFIG_PACKAGE_.+=[ym]$' "$config" \
        | sed -E 's/^CONFIG_PACKAGE_(.+)=[ym]$/\1/' \
        || true
    grep -E '^# CONFIG_PACKAGE_[A-Za-z0-9._+-]+ is not set$' "$config" \
        | sed -E 's/^# CONFIG_PACKAGE_([A-Za-z0-9._+-]+) is not set$/-\1/' \
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
#
# 推导规则:
#   - 优先读 defconfig 后格式 CONFIG_TARGET_ARCH_PACKAGES="<arch>" (buildroot 完成后才有)
#   - 否则读 target.conf / .config 顶部 `# arch: <name>` 注释 (架构不变量 #6)
#
# 加新设备零代码改动: devices/<dev>/target.conf 顶部写一行 `# arch: <name>` 即可。
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

    # 2. # arch: 注释 (种子文件 target.conf 顶部)
    arch=$(grep -E '^#[[:space:]]*arch:[[:space:]]+' "$config" \
            | head -1 | sed -E 's/^#[[:space:]]*arch:[[:space:]]+//' | awk '{print $1}')
    if [ -n "$arch" ]; then
        echo "$arch"
        return 0
    fi
}
