#!/usr/bin/env bash
# scripts/ci/analyze-diff.sh
#
# 计算「设备需要 - (Tier1 IB 内置 + Tier2 Pool 已有)」的缺失包名集合。
# 输出包名（不再反查源码路径）—— compile-in-sdk.sh 现在通过 CONFIG_PACKAGE_*=m
# + make defconfig 自动解依赖，路径反查是不必要且易错的环节。
#
# 参数:
#   $1: 设备 .config 路径
#   $2: ImageBuilder 镜像（提供 Tier1 清单 /manifests/installed_packages.txt）
#   $3: Global Package Pool 镜像（提供 Tier2 清单 /manifests/global-manifest.txt）
#   $4: 输出 JSON 数组文件路径（包名字符串数组）
#
# 输出 JSON 形如: ["nftables-json","wireguard-tools",...]
#
# 注意：
#   - kmod 全部过滤掉。kmod 必须由 common/base-config + 完整 buildroot 决定，
#     SDK 容器内 make 编不出 base-config 之外的内核符号；过滤策略让 missing-list
#     不再误导 Tier3 去做无意义的 kernel 编译。
#   - 第三方 feed 才有的包（如 passwall）在 lenient 模式下会通过；strict 模式由
#     compile-in-sdk.sh 在容器里 make defconfig 阶段做最终拦截。

set -euo pipefail

CONFIG_FILE="${1:?缺少设备 .config 路径}"
IB_IMAGE="${2:?缺少 IB 镜像}"
POOL_IMAGE="${3:?缺少 Pool 镜像}"
JSON_OUTPUT="${4:?缺少输出 JSON 路径}"

echo "开始分析缺失包名（包名口径，路径反查已废弃）..."

# 1. 提取 Tier1 清单（IB 有 shell，直接 docker run cat）
docker pull "$IB_IMAGE" || { sleep 10; docker pull "$IB_IMAGE"; }
docker run --rm "$IB_IMAGE" cat /manifests/installed_packages.txt > L_Tier1.txt || touch L_Tier1.txt

# 2. 提取 Tier2 清单（Pool 镜像 FROM scratch 没 shell，用 docker create + cp）
docker pull "$POOL_IMAGE" 2>/dev/null || { sleep 10; docker pull "$POOL_IMAGE" 2>/dev/null; } || true
pool_cid="$(docker create "$POOL_IMAGE" 2>/dev/null)" || pool_cid=""
if [ -n "$pool_cid" ]; then
    docker cp "${pool_cid}:/manifests/global-manifest.txt" L_Tier2.txt 2>/dev/null || touch L_Tier2.txt
    docker rm "$pool_cid" >/dev/null 2>&1 || true
else
    echo "::warning::无法拉取 Global Pool 镜像 ${POOL_IMAGE}，Tier 2 清单按空处理。"
    touch L_Tier2.txt
fi

# 3. 提取设备 .config 里 =y/=m 的包名
grep '^CONFIG_PACKAGE_.*=[ym]' "$CONFIG_FILE" \
    | sed -E 's/^CONFIG_PACKAGE_(.*)=[ym]/\1/' > L_Required.txt

# 4. Required - (Tier1 ∪ Tier2)
sort -u L_Tier1.txt L_Tier2.txt > L_Available.txt
comm -23 <(sort -u L_Required.txt) L_Available.txt > L_Missing_raw.txt

# 5. 过滤掉 kmod-*（SDK 容器无法补编）
grep -v '^kmod-' L_Missing_raw.txt > L_Missing.txt || true

MISSING_COUNT=$(wc -l < L_Missing.txt | tr -d ' ')
SKIPPED_KMODS=$(grep -c '^kmod-' L_Missing_raw.txt || true)
echo "分析完成：${MISSING_COUNT} 个用户态包需补编；跳过 kmod ${SKIPPED_KMODS} 个（应在 base-config 处理）。"

# 6. 生成 JSON 数组
if [ "$MISSING_COUNT" -gt 0 ]; then
    jq -R . < L_Missing.txt | jq -s -c . > "$JSON_OUTPUT"
else
    echo "[]" > "$JSON_OUTPUT"
fi

echo "缺失包 JSON: $(cat "$JSON_OUTPUT")"
