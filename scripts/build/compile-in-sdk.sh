#!/usr/bin/env bash
# scripts/build/compile-in-sdk.sh
#
# 在给定 SDK 容器里编译一组 make 目标，把 bin/packages/ 树整棵拷回宿主。
# 轨 A (Global Package Pool) 与 轨 B (增量补包) 共用：调用方各自负责
# “算出待编译的 make 目标列表”和“事后整理产物”，本脚本只负责容器内编译。
#
# 用法:
#   compile-in-sdk.sh <build_config_dir> <sdk_image> <output_dir> <feeds_arg> [config_seed_file]

set -euo pipefail

BUILD_CONFIG_DIR="$(cd "${1:?用法见脚本头注释}" && pwd)"
SDK_IMAGE="${2:?缺少 SDK 镜像参数}"
OUTPUT_DIR="${3:?缺少 output 目录参数}"
FEEDS_ARG="${4-}"
CONFIG_SEED="${5-}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# 1. 收集 stdin 的 make 目标
TARGETS_FILE="$OUTPUT_DIR/.targets"
sed '/^[[:space:]]*$/d' > "$TARGETS_FILE"
if [ ! -s "$TARGETS_FILE" ]; then
    echo "compile-in-sdk: 没有待编译的目标，跳过。"
    exit 0
fi

echo "::group::compile-in-sdk: 待编译目标清单"
cat "$TARGETS_FILE"
echo "::endgroup::"

# 2. 组装 docker 挂载
DOCKER_MOUNTS=(
    -v "$BUILD_CONFIG_DIR:/build-config:ro"
    -v "$OUTPUT_DIR:/output"
)
if [ -n "$CONFIG_SEED" ]; then
    CONFIG_SEED="$(cd "$(dirname "$CONFIG_SEED")" && pwd)/$(basename "$CONFIG_SEED")"
    DOCKER_MOUNTS+=( -v "$CONFIG_SEED:/home/builder/.config" )
fi

# 3. 拉取镜像
echo "::group::拉取 SDK 镜像: $SDK_IMAGE"
docker pull "$SDK_IMAGE" || { sleep 10; docker pull "$SDK_IMAGE"; }
echo "::endgroup::"

# 4. 容器内编译
docker run --rm "${DOCKER_MOUNTS[@]}" -w /home/builder -e FEEDS_ARG="$FEEDS_ARG" "$SDK_IMAGE" bash -euo pipefail -c '

    bash /build-config/scripts/build/prepare-feeds.sh "$FEEDS_ARG"

    echo "::group::make defconfig"
    make defconfig
    echo "::endgroup::"

    failed_pkgs=""
    total_pkgs=$(wc -l < /output/.targets)
    current=0

    while IFS= read -r tgt; do
        [ -n "$tgt" ] || continue
        current=$((current + 1))
        
        echo "::group::[$current/$total_pkgs] 正在编译: $tgt"
        if ! make "$tgt" -j"$(nproc)" BUILD_LOG=1 IGNORE_ERRORS=1; then
            echo "::warning::多线程编译失败，尝试单线程调试模式: $tgt"
            if ! make "$tgt" -j1 V=s BUILD_LOG=1 IGNORE_ERRORS=1; then
                echo "::error::包编译失败（已尝试单线程）: $tgt"
                failed_pkgs="${failed_pkgs}${tgt}"$'\''\n'\''
            fi
        fi
        echo "::endgroup::"
    done < /output/.targets

    if [ -n "$failed_pkgs" ]; then
        echo "::error::以下包编译失败:"
        printf "%s" "$failed_pkgs"
        printf "%s" "$failed_pkgs" > /output/.failed
    fi

    echo "::group::整理编译产物"
    # 保留 bin/packages/ 结构，确保架构不混淆
    mkdir -p /output/packages
    if [ -d bin/packages ]; then
        cp -ra bin/packages/* /output/packages/ 2>/dev/null || true
    fi
    # 容器以 root 跑，放开权限让宿主能读/清理/上传
    chmod -R a+rwX /output 2>/dev/null || true
    echo "::endgroup::"
'
