#!/usr/bin/env bash
# scripts/ci/merge-missing-info.sh
#
# 职责：
#   1. 读取 all-missing/*.json (每个设备一个 JSON 数组，存的是源码路径)
#   2. 获取 device_meta (JSON) 建立 设备 -> 架构 的映射
#   3. 按架构对路径进行并集去重
#   4. 输出 GHA Matrix JSON (用于驱动 _firmware-packages.yml 的 per-arch 矩阵)
#
# 用法:
#   bash merge-missing-info.sh <missing_info_dir> <device_meta_json>

set -euo pipefail

INFO_DIR="${1:?Missing info dir}"
DEVICE_META="${2:?Missing device meta}"

# 结果存储：arch_paths["aarch64_cortex-a53"]="path/a path/b"
declare -A arch_paths

# 1. 遍历所有设备的缺失信息
for f in "$INFO_DIR"/*.json; do
    [ -f "$f" ] || continue
    dev=$(basename "$f" .json)
    
    # 获取该设备对应的 arch (通过 jq 从 meta 中提)
    arch=$(echo "$DEVICE_META" | jq -r --arg dev "$dev" '.[$dev].arch')
    [ -n "$arch" ] && [ "$arch" != "null" ] || continue
    
    # 读取该设备的路径列表
    paths=$(jq -r '.[] | select(. != null and . != "")' "$f")
    [ -n "$paths" ] || continue
    
    # 追加到对应架构的集合中
    arch_paths["$arch"]="${arch_paths["$arch"]:-}"$'\n'"$paths"
done

# 2. 构造最终的架构矩阵 JSON
# 格式: [{"key": "arch1", "value": ["p1", "p2"], "target_slug": "xxx"}, ...]
result="[]"
for arch in "${!arch_paths[@]}"; do
    # 去重
    unique_paths=$(printf '%s\n' "${arch_paths[$arch]}" | sed '/^[[:space:]]*$/d' | sort -u | jq -R . | jq -s -c .)
    [ "$(echo "$unique_paths" | jq 'length')" -gt 0 ] || continue
    
    # 找出一个代表性的 target_slug (该架构下第一个设备的)
    target_slug=$(echo "$DEVICE_META" | jq -r --arg arch "$arch" 'to_entries | map(select(.value.arch == $arch)) | .[0].value.target_slug')
    
    # 构造条目
    entry=$(jq -n \
        --arg arch "$arch" \
        --arg target_slug "$target_slug" \
        --argjson paths "$unique_paths" \
        '{key: $arch, value: $paths, target_slug: $target_slug}')
    result=$(echo "$result" | jq -c --argjson entry "$entry" '. + [$entry]')
done

echo "matrix=${result}" >> "$GITHUB_OUTPUT"
echo "最终架构编译矩阵: ${result}"
