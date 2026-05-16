#!/usr/bin/env bash
# 脚本职责:计算 OpenWrt 构建矩阵
#
# 环境变量输入 (顶层 workflow 的 Initialize job 提供):
#   OPENWRT_REPO          上游 OpenWrt 仓库 (eg. openwrt/openwrt)
#   OPENWRT_REF           上游分支/tag/sha (eg. main)
#   GITHUB_REPOSITORY     owner/repo (GHA 内置)
#
# 输出 GHA outputs (8 个,均有消费方;改输出列表前请先 grep 确认):
#   device_matrix             ["mt3600be"]
#                             消费方: firmware.yml.Analyze-Diff / Assemble-Firmware matrix
#                                     validate.yml.Validate matrix
#   target_matrix             ["mediatek/filogic"]
#                             消费方: base.yml.Build-Base matrix
#   target_matrix_with_meta   [{target, target_slug, sdk_tar_name, ib_tar_name, ib_manifest_name}]
#                             消费方: pool-update.yml.Build-Pool matrix
#   device_meta               {"mt3600be": {arch, target, target_slug, profile,
#                                           sdk_tar_name, ib_tar_name, ib_manifest_name,
#                                           pool_tar_name}}
#                             消费方: firmware.yml Analyze-Diff env / Compile-Patches inputs /
#                                     Assemble-Firmware inputs
#   source_slug               "K-Lrize-openwrt-main"
#                             消费方: base/firmware/pool-update artifact pattern + 命名
#   pool_manifest_name        "pool-K-Lrize-openwrt-main.manifest.txt"  (跨 arch 单文件)
#                             消费方: firmware.yml Analyze-Diff + _pool-finalize.yml
#   indexer_sdk_tar_name      任选一个 SDK tar 名 (_pool-finalize.yml 借 ipkg-make-index.sh
#                             与 host bin 的 apk;ipkg-make-index 跨 target 同构)
#                             消费方: _pool-finalize.yml
#   has_builds                true/false
#                             消费方: firmware/pool-update/validate 的 job if

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/extract-config.sh
source "$CONF_DIR/scripts/lib/extract-config.sh"
# shellcheck source=../lib/slugify.sh
source "$CONF_DIR/scripts/lib/slugify.sh"
# shellcheck source=../lib/asset-names.sh
source "$CONF_DIR/scripts/lib/asset-names.sh"

OPENWRT_REPO="${OPENWRT_REPO:-openwrt/openwrt}"
OPENWRT_REF="${OPENWRT_REF:-main}"
GH_REPO="${GITHUB_REPOSITORY:-}"
if [ -n "$GH_REPO" ]; then
    OWNER_LC=$(echo "${GH_REPO%%/*}" | tr '[:upper:]' '[:lower:]')
    REPO_NAME_LC=$(echo "${GH_REPO##*/}" | tr '[:upper:]' '[:lower:]')
else
    OWNER_LC="local"
    REPO_NAME_LC="local"
fi
SRC_SLUG=$(source_slug "$OPENWRT_REPO" "$OPENWRT_REF")
REF_SLUG=$(slugify "$OPENWRT_REF")
POOL_MANIFEST_NAME=$(pool_manifest_name "$OPENWRT_REPO" "$OPENWRT_REF")

cd "$CONF_DIR"

# 1. 自动发现设备
ALL_DEVICES=()
if [ -d "devices" ]; then
    for dir in devices/*/; do
        [ -d "$dir" ] || continue
        ALL_DEVICES+=("$(basename "$dir")")
    done
fi

if [ ${#ALL_DEVICES[@]} -eq 0 ]; then
    echo "::error::未在 devices/ 目录下找到任何设备配置。"
    exit 1
fi

echo "发现设备: ${ALL_DEVICES[*]}"

BUILD_LIST=()

# 2. 启发式增量决策
case "${GITHUB_EVENT_NAME:-workflow_dispatch}" in
    schedule|workflow_dispatch)
        echo "构建模式: 全量构建 (${GITHUB_EVENT_NAME:-manual})"
        BUILD_LIST=("${ALL_DEVICES[@]}")
        ;;
    push|pull_request)
        echo "构建模式: 变更检测 (${GITHUB_EVENT_NAME})"
        if [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
            BASE="${BASE_SHA:-}"
            HEAD="${HEAD_SHA:-}"
        else
            HEAD="HEAD"
            if git rev-parse HEAD^ >/dev/null 2>&1; then
                BASE="HEAD^"
            else
                BASE=""
            fi
        fi
        if [ -n "$BASE" ]; then
            CHANGED=$(git diff --name-only "$BASE" "$HEAD")
            echo "变更文件:"
            echo "$CHANGED"
            if echo "$CHANGED" | grep -qE "^(scripts/|common/|\.github/workflows/)"; then
                echo "检测到公共组件变更,执行全量构建。"
                BUILD_LIST=("${ALL_DEVICES[@]}")
            else
                for dev in "${ALL_DEVICES[@]}"; do
                    if echo "$CHANGED" | grep -q "^devices/$dev/"; then
                        BUILD_LIST+=("$dev")
                    fi
                done
            fi
        else
            echo "无对比基准,执行全量构建。"
            BUILD_LIST=("${ALL_DEVICES[@]}")
        fi
        ;;
    *)
        BUILD_LIST=("${ALL_DEVICES[@]}")
        ;;
esac

# 去重 + 排序
if [ "${#BUILD_LIST[@]}" -gt 0 ]; then
    IFS=$'\n' BUILD_LIST=($(printf '%s\n' "${BUILD_LIST[@]}" | sort -u)); unset IFS
fi

# 3. 空矩阵直接返回
if [ ${#BUILD_LIST[@]} -eq 0 ]; then
    echo "构建矩阵为空,无需构建。"
    {
        echo "device_matrix=[]"
        echo "target_matrix=[]"
        echo "target_matrix_with_meta=[]"
        echo "device_meta={}"
        echo "source_slug=${SRC_SLUG}"
        echo "pool_manifest_name=${POOL_MANIFEST_NAME}"
        echo "indexer_sdk_tar_name="
        echo "has_builds=false"
    } >> "$GITHUB_OUTPUT"
    exit 0
fi

# 4. 构造 device_meta + 收集 target 集合
device_meta='{}'
target_set=()

for dev in "${BUILD_LIST[@]}"; do
    cfg="devices/${dev}/target.conf"

    if [ ! -f "$cfg" ]; then
        echo "::error::device ${dev}: 缺 $cfg (架构不变量 #6, 见 ARCHITECTURE.md)。"
        exit 1
    fi

    arch=$(extract_arch "$cfg")
    target=$(extract_target "$cfg")
    profile=$(extract_profile "$cfg")
    target_slug=$(slugify "$target")
    sdk_tar=$(sdk_tar_name      "$target" "$OPENWRT_REPO" "$OPENWRT_REF")
    ib_tar=$(ib_tar_name        "$target" "$OPENWRT_REPO" "$OPENWRT_REF")
    ib_manifest=$(ib_manifest_name "$target" "$OPENWRT_REPO" "$OPENWRT_REF")

    if [ -z "$arch" ]; then
        echo "::error::device ${dev} (target=${target}) 推不出 arch — 在 ${cfg} 顶部写 '# arch: <name>' (架构不变量 #6)。"
        exit 1
    fi
    pool_tar=$(pool_tar_name "$arch" "$OPENWRT_REPO" "$OPENWRT_REF")

    dev_meta=$(jq -n \
        --arg arch "$arch" \
        --arg target "$target" \
        --arg target_slug "$target_slug" \
        --arg profile "$profile" \
        --arg sdk_tar_name "$sdk_tar" \
        --arg ib_tar_name "$ib_tar" \
        --arg ib_manifest_name "$ib_manifest" \
        --arg pool_tar_name "$pool_tar" \
        '{
            arch: $arch,
            target: $target,
            target_slug: $target_slug,
            profile: $profile,
            sdk_tar_name: $sdk_tar_name,
            ib_tar_name: $ib_tar_name,
            ib_manifest_name: $ib_manifest_name,
            pool_tar_name: $pool_tar_name
        }')

    device_meta=$(jq -c --arg dev "$dev" --argjson meta "$dev_meta" \
        '. + {($dev): $meta}' <<< "$device_meta")

    target_set+=("$target")
done

# 5. target 去重
mapfile -t target_list < <(printf '%s\n' "${target_set[@]}" | sort -u)

# 6. per-target metadata (驱动 base.yml / pool-update.yml 的矩阵)
target_meta='[]'
first_sdk_tar=""
for target in "${target_list[@]}"; do
    target_slug=$(slugify "$target")
    sdk_tar=$(sdk_tar_name      "$target" "$OPENWRT_REPO" "$OPENWRT_REF")
    ib_tar=$(ib_tar_name        "$target" "$OPENWRT_REPO" "$OPENWRT_REF")
    ib_manifest=$(ib_manifest_name "$target" "$OPENWRT_REPO" "$OPENWRT_REF")
    [ -z "$first_sdk_tar" ] && first_sdk_tar="$sdk_tar"
    entry=$(jq -nc \
        --arg target "$target" \
        --arg target_slug "$target_slug" \
        --arg sdk_tar_name "$sdk_tar" \
        --arg ib_tar_name "$ib_tar" \
        --arg ib_manifest_name "$ib_manifest" \
        '{target:$target, target_slug:$target_slug,
          sdk_tar_name:$sdk_tar_name, ib_tar_name:$ib_tar_name,
          ib_manifest_name:$ib_manifest_name}')
    target_meta=$(jq -nc --argjson r "$target_meta" --argjson e "$entry" '$r + [$e]')
done

# 7. 序列化 + 输出
device_matrix_json=$(printf '%s\n' "${BUILD_LIST[@]}" | jq -R . | jq -s -c .)
target_matrix_json=$(printf '%s\n' "${target_list[@]}" | jq -R . | jq -s -c .)

{
    echo "device_matrix=${device_matrix_json}"
    echo "target_matrix=${target_matrix_json}"
    echo "target_matrix_with_meta=${target_meta}"
    echo "device_meta=${device_meta}"
    echo "source_slug=${SRC_SLUG}"
    echo "pool_manifest_name=${POOL_MANIFEST_NAME}"
    echo "indexer_sdk_tar_name=${first_sdk_tar}"
    echo "has_builds=true"
} >> "$GITHUB_OUTPUT"

echo "device_matrix:            ${device_matrix_json}"
echo "target_matrix:            ${target_matrix_json}"
echo "target_matrix_with_meta:  ${target_meta}"
echo "device_meta:              ${device_meta}"
echo "source_slug:              ${SRC_SLUG}"
echo "pool_manifest_name:       ${POOL_MANIFEST_NAME}"
echo "indexer_sdk_tar_name:     ${first_sdk_tar}"
