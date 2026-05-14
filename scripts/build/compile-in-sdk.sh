#!/usr/bin/env bash
# scripts/build/compile-in-sdk.sh
#
# 在给定 SDK 容器里跑「配置式」批量编译：
#   stdin    -> 一行一个「裸包名」
#   容器内：CONFIG_SEED (可选) + CONFIG_PACKAGE_<name>=m -> make defconfig -> 语义校验
#         -> make -j$(nproc) package/compile IGNORE_ERRORS="n m" -> 拷回 bin/packages
#
# 用法:
#   compile-in-sdk.sh <build_config_dir> <sdk_image> <output_dir> <feeds_arg> [config_seed_file]
#
# 环境变量:
#   STRICT_VALIDATION=1 (默认): 请求的包名在 make defconfig 后缺失 -> exit 1
#   STRICT_VALIDATION=0       : 同样列出缺失包名，但 warning 继续（Tier3 用，
#                                 missing-list 可能含外部 feed 才有的包）。
#
# Pool 轨 (custom-packages.txt) 和 Tier3 增量轨共用此入口。kmod 不在编译范围内
# （SDK 的内核 .config 已固化，需要的 kmod 请在 common/base-config 里 =m）。

set -euo pipefail

BUILD_CONFIG_DIR="$(cd "${1:?用法见脚本头注释}" && pwd)"
SDK_IMAGE="${2:?缺少 SDK 镜像参数}"
OUTPUT_DIR="${3:?缺少 output 目录参数}"
FEEDS_ARG="${4-}"
CONFIG_SEED="${5-}"
STRICT_VALIDATION="${STRICT_VALIDATION:-1}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# 1. 收集 stdin 的包名清单（剥注释/空行）
REQUESTED_FILE="$OUTPUT_DIR/.requested-packages"
sed -E '
    s/[[:space:]]+#.*//
    s/^[[:space:]]+//
    s/[[:space:]]+$//
    /^$/d
    /^#/d
' > "$REQUESTED_FILE"

if [ ! -s "$REQUESTED_FILE" ]; then
    echo "compile-in-sdk: 没有待编译的包名，跳过。"
    exit 0
fi

echo "::group::compile-in-sdk: 待编译包名清单 ($(wc -l < "$REQUESTED_FILE") 个)"
cat "$REQUESTED_FILE"
echo "::endgroup::"

# 2. 组装 docker 挂载
DOCKER_MOUNTS=(
    -v "$BUILD_CONFIG_DIR:/build-config:ro"
    -v "$OUTPUT_DIR:/output"
)
if [ -n "$CONFIG_SEED" ]; then
    CONFIG_SEED="$(cd "$(dirname "$CONFIG_SEED")" && pwd)/$(basename "$CONFIG_SEED")"
    DOCKER_MOUNTS+=( -v "$CONFIG_SEED:/seed/seed.config:ro" )
fi

# 3. 拉取 SDK 镜像
echo "::group::拉取 SDK 镜像: $SDK_IMAGE"
docker pull "$SDK_IMAGE" || { sleep 10; docker pull "$SDK_IMAGE"; }
echo "::endgroup::"

# 4. 容器内编译
docker run --rm "${DOCKER_MOUNTS[@]}" -w /home/builder \
    -e FEEDS_ARG="$FEEDS_ARG" \
    -e STRICT_VALIDATION="$STRICT_VALIDATION" \
    "$SDK_IMAGE" bash -euo pipefail -c '

    # 只安装请求包（而非 -a），避免 base-packages/ 等全量包通过 default m 被 defconfig 展开
    bash /build-config/scripts/build/prepare-feeds.sh "$FEEDS_ARG" /output/.requested-packages

    echo "::group::种子 .config 拼装"
    # (a) 起点：CONFIG_SEED（如果给定）覆盖 SDK 自带 .config；否则保留 SDK 默认
    if [ -f /seed/seed.config ]; then
        echo "应用 CONFIG_SEED -> .config"
        cp /seed/seed.config .config
    fi
    # (b) 追加请求包名的 CONFIG_PACKAGE_*=m 行
    bash /build-config/scripts/build/seed-config-from-packages.sh \
        < /output/.requested-packages >> .config
    echo "种子 .config 末尾:"
    tail -n 20 .config
    echo "::endgroup::"

    echo "::group::make defconfig"
    make defconfig
    echo "::endgroup::"

    echo "::group::语义校验 (defconfig 后哪些请求包丢了?)"
    missing_file=/output/.missing-after-defconfig
    : > "$missing_file"
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        case "$pkg" in kmod-*) continue ;; esac   # kmod 本来就被 seed 阶段过滤
        if ! grep -qE "^CONFIG_PACKAGE_${pkg}=[ym]" .config; then
            printf "%s\n" "$pkg" >> "$missing_file"
        fi
    done < /output/.requested-packages

    if [ -s "$missing_file" ]; then
        missing_count=$(wc -l < "$missing_file")
        echo "::warning::以下 ${missing_count} 个包在 make defconfig 后丢失（拼写错 / 不在 feeds / 被依赖剔除）："
        sed "s/^/  - /" "$missing_file"
        if [ "$STRICT_VALIDATION" = "1" ]; then
            echo "::error::STRICT_VALIDATION=1，因丢失包阻断编译。"
            chmod -R a+rwX /output 2>/dev/null || true
            exit 1
        fi
        echo "STRICT_VALIDATION=0，继续编译可用部分。"
    else
        echo "全部请求包通过 defconfig 解析。"
    fi
    echo "::endgroup::"

    echo "::group::make -j$(nproc) package/compile (IGNORE_ERRORS=\"n m\")"
    if ! make -j"$(nproc)" package/compile IGNORE_ERRORS="n m" BUILD_LOG=1; then
        echo "::warning::多线程 package/compile 失败，降级 -j1 V=s 重试一次。"
        make -j1 V=s package/compile IGNORE_ERRORS="n m" BUILD_LOG=1 || \
            echo "::error::单线程仍失败，部分包未产出（详见 logs/package/）。"
    fi
    echo "::endgroup::"

    echo "::group::整理编译产物"
    mkdir -p /output/packages /output/logs
    if [ -d bin/packages ]; then
        cp -ra bin/packages/. /output/packages/ 2>/dev/null || true
    fi
    if [ -d logs/package ]; then
        cp -ra logs/package /output/logs/ 2>/dev/null || true
    fi
    # 统计：哪些请求包最终没出 .ipk/.apk？
    failed_file=/output/.failed
    : > "$failed_file"
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        case "$pkg" in kmod-*) continue ;; esac
        # bin/packages/<arch>/<feed>/<pkg>_<ver>_<arch>.ipk 或 .apk
        if ! find /output/packages -maxdepth 4 -type f \
                \( -name "${pkg}_*.ipk" -o -name "${pkg}-*.apk" \) \
                -print -quit 2>/dev/null | grep -q .; then
            # 请求过但 defconfig 阶段就被丢的不重复计入
            if ! grep -qx "$pkg" /output/.missing-after-defconfig 2>/dev/null; then
                printf "%s\n" "$pkg" >> "$failed_file"
            fi
        fi
    done < /output/.requested-packages
    if [ -s "$failed_file" ]; then
        echo "::warning::请求但未产出包文件（编译失败/被父包合并/被裁剪）："
        sed "s/^/  - /" "$failed_file"
    fi
    chmod -R a+rwX /output 2>/dev/null || true
    echo "::endgroup::"
'
