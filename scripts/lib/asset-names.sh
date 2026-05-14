#!/usr/bin/env bash
# scripts/lib/asset-names.sh
#
# 集中所有 release asset 的命名规则。取代旧 lib/image-tags.sh (GHCR tag 算法)。
# 改 asset 命名只需要改这一处。
#
# 依赖:scripts/lib/slugify.sh (slugify + source_slug)
#
# 用法 (source 后调用):
#   source scripts/lib/slugify.sh
#   source scripts/lib/asset-names.sh
#
#   sdk_tar=$(sdk_tar_name        "mediatek/filogic" "K-Lrize/openwrt" "main")
#       # → sdk-mediatek-filogic-K-Lrize-openwrt-main.tar.zst
#   ib_tar=$(ib_tar_name          "mediatek/filogic" "K-Lrize/openwrt" "main")
#       # → ib-mediatek-filogic-K-Lrize-openwrt-main.tar.zst
#   ib_manifest=$(ib_manifest_name "mediatek/filogic" "K-Lrize/openwrt" "main")
#       # → ib-mediatek-filogic-K-Lrize-openwrt-main.manifest.txt
#   pool_tar=$(pool_tar_name      "aarch64_cortex-a53" "K-Lrize/openwrt" "main")
#       # → pool-aarch64_cortex-a53-K-Lrize-openwrt-main.tar.zst
#   pool_man=$(pool_manifest_name  "K-Lrize/openwrt" "main")
#       # → pool-K-Lrize-openwrt-main.manifest.txt
#
# 约定:
#   - SDK / IB tar:  <kind>-<target_slug>-<source_slug>.tar.zst
#   - IB manifest:   ib-<target_slug>-<source_slug>.manifest.txt
#   - Pool tar:      pool-<arch_slug>-<source_slug>.tar.zst (按 arch 切分)
#   - Pool manifest: pool-<source_slug>.manifest.txt (跨 arch 去重)
#   - <source_slug>  = <repo_slug>-<ref_slug>,sloppy-fork 隔离

sdk_tar_name() {
    local target="$1" repo="$2" ref="$3"
    printf 'sdk-%s-%s.tar.zst\n' "$(slugify "$target")" "$(source_slug "$repo" "$ref")"
}

ib_tar_name() {
    local target="$1" repo="$2" ref="$3"
    printf 'ib-%s-%s.tar.zst\n' "$(slugify "$target")" "$(source_slug "$repo" "$ref")"
}

ib_manifest_name() {
    local target="$1" repo="$2" ref="$3"
    printf 'ib-%s-%s.manifest.txt\n' "$(slugify "$target")" "$(source_slug "$repo" "$ref")"
}

pool_tar_name() {
    local arch="$1" repo="$2" ref="$3"
    printf 'pool-%s-%s.tar.zst\n' "$(slugify "$arch")" "$(source_slug "$repo" "$ref")"
}

pool_manifest_name() {
    local repo="$1" ref="$2"
    printf 'pool-%s.manifest.txt\n' "$(source_slug "$repo" "$ref")"
}

# 拼 release asset 的下载 URL。owner/repo 通常来自 GITHUB_REPOSITORY,tag
# 通常是 rolling。
#   release_asset_url <owner/repo> <tag> <asset_name>
release_asset_url() {
    local repo="$1" tag="$2" asset="$3"
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$repo" "$tag" "$asset"
}
