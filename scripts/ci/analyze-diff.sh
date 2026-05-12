#!/usr/bin/env bash
# 脚本职责：分析设备配置，计算缺失包，并支持 kmod 路径转换
# 参数：
#   $1: OpenWrt 源码根目录
#   $2: 设备 .config 路径
#   $3: ImageBuilder 镜像名称 (提供 Tier 1 内置包清单 /manifests/installed_packages.txt)
#   $4: Global Package Pool 镜像名称 (提供 Tier 2 全局清单 /manifests/global-manifest.txt)
#   $5: 输出 JSON 矩阵文件路径

set -euo pipefail

SRC_DIR="$1"
CONFIG_FILE="$2"
IB_IMAGE="$3"
POOL_IMAGE="$4"
JSON_OUTPUT="$5"

echo "开始执行全量增量分析 (包含 kmod)..."

# 1. 提取 Tier 1 清单 (IB 镜像内置包) —— IB 镜像有 shell，直接 docker run cat
docker pull "$IB_IMAGE" || { sleep 10; docker pull "$IB_IMAGE"; }
docker run --rm "$IB_IMAGE" cat /manifests/installed_packages.txt > L_Tier1.txt || touch L_Tier1.txt

# 1.5 提取 Tier 2 清单 (Global Pool 镜像) —— pool 镜像是 FROM scratch，没有 shell，用 docker create + cp
docker pull "$POOL_IMAGE" 2>/dev/null || { sleep 10; docker pull "$POOL_IMAGE" 2>/dev/null; } || true
pool_cid="$(docker create "$POOL_IMAGE" 2>/dev/null)" || pool_cid=""
if [ -n "$pool_cid" ]; then
    docker cp "${pool_cid}:/manifests/global-manifest.txt" L_Tier2.txt 2>/dev/null || touch L_Tier2.txt
    docker rm "$pool_cid" >/dev/null 2>&1 || true
else
    echo "::warning::无法拉取 Global Pool 镜像 ${POOL_IMAGE}，Tier 2 清单按空处理。"
    touch L_Tier2.txt
fi

# 2. 提取所需包名
grep '^CONFIG_PACKAGE_.*=[ym]' "$CONFIG_FILE" | \
    sed -E 's/^CONFIG_PACKAGE_(.*)=[ym]/\1/' > L_Required.txt

# 3. 计算缺失包 (Required - Available)
sort -u L_Tier1.txt L_Tier2.txt > L_Available.txt
comm -23 <(sort -u L_Required.txt) L_Available.txt > L_Missing.txt

MISSING_COUNT=$(wc -l < L_Missing.txt)
echo "分析完成：共有 $MISSING_COUNT 个包需要处理。"

# 4. 反查源码路径 (针对 kmod 做了特殊处理)
L_PATHS=$(mktemp)
if [ "$MISSING_COUNT" -gt 0 ]; then
    cd "$SRC_DIR"
    bash ../build-config/scripts/build/prepare-feeds.sh "$(basename "$(dirname "$CONFIG_FILE")")"
    while read -r pkg; do
        # --- 特殊处理开始 ---
        if [[ "$pkg" == kmod-* ]]; then
            # 1. 先尝试找特定的 Makefile (某些外部 feed 的 kmod)
            path=$(grep -rlE "Package/($pkg)\$" package/ feeds/ 2>/dev/null | head -n1 || true)

            # 2. 如果没找到，或者在 package/kernel/linux 目录下
            # 则统一重定向到 SDK 的内核编译目标
            if [ -z "$path" ] || [[ "$path" == package/kernel/linux/* ]]; then
                echo "package/kernel/linux" >> "$L_PATHS"
                continue
            fi
        else
            # 普通包处理
            path=$(grep -rlE "Package/($pkg)\$" package/ feeds/ 2>/dev/null | head -n1 || true)
        fi
        # --- 特殊处理结束 ---

        if [ -n "$path" ]; then
            dirname "$path" >> "$L_PATHS"
        fi
    done < ../L_Missing.txt
    cd - > /dev/null
fi

# 5. 生成 JSON 矩阵
if [ -s "$L_PATHS" ]; then
    # 去重并生成 JSON
    sort -u "$L_PATHS" | jq -R . | jq -s -c . > "$JSON_OUTPUT"
else
    echo "[]" > "$JSON_OUTPUT"
fi

echo "JSON 矩阵已更新，包含 kmod 路径: $(cat "$JSON_OUTPUT")"
