#!/usr/bin/env bash
# 脚本职责：生成滚动 Release 的下载索引，合并既有 assets 与本次构建产物
set -euo pipefail

ARTIFACTS_DIR="${1:?用法: $0 <artifacts_dir> <tag_name> <output_path>}"
TAG_NAME="${2:?用法: $0 <artifacts_dir> <tag_name> <output_path>}"
OUTPUT_PATH="${3:?用法: $0 <artifacts_dir> <tag_name> <output_path>}"

REPOSITORY="${GITHUB_REPOSITORY:?缺少 GITHUB_REPOSITORY}"
RELEASE_BASE_URL="https://github.com/${REPOSITORY}/releases/download/${TAG_NAME}"

declare -A ASSETS=()

if gh api "repos/${REPOSITORY}/releases/tags/${TAG_NAME}" --jq '.assets[].name' > /tmp/existing-release-assets.txt 2>/dev/null; then
    while IFS= read -r asset; do
        [[ -n "$asset" ]] || continue
        ASSETS["$asset"]=1
    done < /tmp/existing-release-assets.txt
else
    echo "未找到 Release ${TAG_NAME}，使用本次构建产物生成索引。"
fi

while IFS= read -r -d '' file; do
    ASSETS["$(basename "$file")"]=1
done < <(find "$ARTIFACTS_DIR" -type f -print0)

mapfile -t DEVICES < <(find devices -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

device_for_asset() {
    local asset="$1"
    local device
    for device in "${DEVICES[@]}"; do
        if [[ "$asset" == "${device}-"* ]]; then
            printf '%s\n' "$device"
            return 0
        fi
    done
    printf 'unknown\n'
}

label_for_asset() {
    local asset="$1"
    case "$asset" in
        *sysupgrade*) printf 'sysupgrade 固件' ;;
        *factory*) printf 'factory 固件' ;;
        *sha256sums.txt) printf 'SHA256 校验和' ;;
        *profiles.json) printf 'profiles.json' ;;
        *.manifest) printf '软件包清单' ;;
        *) printf '其他文件' ;;
    esac
}

sort_key_for_asset() {
    local asset="$1"
    case "$asset" in
        *sysupgrade*) printf '10' ;;
        *factory*) printf '20' ;;
        *sha256sums.txt) printf '30' ;;
        *.manifest) printf '40' ;;
        *profiles.json) printf '50' ;;
        *) printf '90' ;;
    esac
}

{
    cat <<EOF
## OpenWrt 固件发布

**更新设备**: ${DEVICE_LIST:-未知}

| 设备 | 文件类型 | 下载 |
| --- | --- | --- |
EOF

    for asset in "${!ASSETS[@]}"; do
        [[ "$asset" == "release-index.md" ]] && continue
        device="$(device_for_asset "$asset")"
        label="$(label_for_asset "$asset")"
        sort_key="$(sort_key_for_asset "$asset")"
        printf '%s\t%s\t| %s | %s | [%s](%s/%s) |\n' "$device" "$sort_key" "$device" "$label" "$asset" "$RELEASE_BASE_URL" "$asset"
    done | sort -t $'\t' -k1,1 -k2,2n -k3,3 | cut -f3-

    cat <<'EOF'

EOF
} > "$OUTPUT_PATH"

echo "Release 索引已生成: $OUTPUT_PATH"
