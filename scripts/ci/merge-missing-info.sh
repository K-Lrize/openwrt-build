#!/usr/bin/env bash
# scripts/ci/merge-missing-info.sh
#
# 职责：
#   1. 读取 all-missing/*.json (每设备一个 JSON 数组，存的是「包名」)
#   2. 用 device_meta (JSON) 建立 设备 -> 架构 的映射
#   3. 按架构对包名做并集去重
#   4. 输出 GHA Matrix JSON 驱动 _firmware-packages.yml 的 per-arch 矩阵
#
# 输出格式:
#   matrix=[{"key":"<arch>","value":["pkg1","pkg2",...],
#            "target_slug":"<slug>","sdk_tar_name":"<asset>","ib_tar_name":"<asset>"}, ...]
#
# 用法:
#   bash merge-missing-info.sh <missing_info_dir> <device_meta_json>

set -euo pipefail

INFO_DIR="${1:?Missing info dir}"
DEVICE_META="${2:?Missing device meta}"

# 按 arch 聚合包名：arch_packages["aarch64_cortex-a53"]+="pkg-a\npkg-b\n"
declare -A arch_packages

for f in "$INFO_DIR"/*.json; do
    [ -f "$f" ] || continue
    dev=$(basename "$f" .json)

    arch=$(echo "$DEVICE_META" | jq -r --arg dev "$dev" '.[$dev].arch')
    [ -n "$arch" ] && [ "$arch" != "null" ] || continue

    packages=$(jq -r '.[] | select(. != null and . != "")' "$f")
    [ -n "$packages" ] || continue

    arch_packages["$arch"]="${arch_packages["$arch"]:-}"$'\n'"$packages"
done

result="[]"
for arch in "${!arch_packages[@]}"; do
    unique_packages=$(printf '%s\n' "${arch_packages[$arch]}" \
        | sed '/^[[:space:]]*$/d' \
        | sort -u \
        | jq -R . \
        | jq -s -c .)
    [ "$(echo "$unique_packages" | jq 'length')" -gt 0 ] || continue

    # 该 arch 下任选一个 device,把它的 sdk_tar_name / ib_tar_name 当作"代表"
    # (Tier3 只用 SDK 跑 make package/compile,per-target 的 SDK tarball 对该 arch 一致)
    rep=$(echo "$DEVICE_META" | jq -c --arg arch "$arch" \
        'to_entries | map(select(.value.arch == $arch)) | .[0].value')

    entry=$(jq -nc \
        --arg arch "$arch" \
        --argjson rep "$rep" \
        --argjson packages "$unique_packages" \
        '{
            key: $arch,
            value: $packages,
            target_slug:   $rep.target_slug,
            sdk_tar_name:  $rep.sdk_tar_name,
            ib_tar_name:   $rep.ib_tar_name
        }')
    result=$(echo "$result" | jq -c --argjson entry "$entry" '. + [$entry]')
done

echo "matrix=${result}" >> "$GITHUB_OUTPUT"
echo "最终架构编译矩阵: ${result}"
