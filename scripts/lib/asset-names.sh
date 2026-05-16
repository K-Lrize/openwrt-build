#!/usr/bin/env bash
# scripts/lib/asset-names.sh
#
# 集中所有 release asset 的命名规则 (架构不变量 #9, 见 ARCHITECTURE.md)。
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
#   - <source_slug>  = <repo_slug>-<ref_slug>, 避免不同 fork 的同分支名撞 tag
#
# 双层接口:
#   *_name(target/arch, repo, ref)     — 高层, 接受原始 repo+ref, 内部算 source_slug
#   *_name_with_slug(target/arch, slug)  — 低层, 接受已算好的 source_slug;
#                                          用于已持有 source_slug 的上下文 (如
#                                          _pool-finalize.yml 通过 input 拿到 slug)

sdk_tar_name_with_slug() {
    local target="$1" slug="$2"
    printf 'sdk-%s-%s.tar.zst\n' "$(slugify "$target")" "$slug"
}
sdk_tar_name() {
    sdk_tar_name_with_slug "$1" "$(source_slug "$2" "$3")"
}

ib_tar_name_with_slug() {
    local target="$1" slug="$2"
    printf 'ib-%s-%s.tar.zst\n' "$(slugify "$target")" "$slug"
}
ib_tar_name() {
    ib_tar_name_with_slug "$1" "$(source_slug "$2" "$3")"
}

ib_manifest_name_with_slug() {
    local target="$1" slug="$2"
    printf 'ib-%s-%s.manifest.txt\n' "$(slugify "$target")" "$slug"
}
ib_manifest_name() {
    ib_manifest_name_with_slug "$1" "$(source_slug "$2" "$3")"
}

pool_tar_name_with_slug() {
    local arch="$1" slug="$2"
    printf 'pool-%s-%s.tar.zst\n' "$(slugify "$arch")" "$slug"
}
pool_tar_name() {
    pool_tar_name_with_slug "$1" "$(source_slug "$2" "$3")"
}

pool_manifest_name_with_slug() {
    local slug="$1"
    printf 'pool-%s.manifest.txt\n' "$slug"
}
pool_manifest_name() {
    pool_manifest_name_with_slug "$(source_slug "$1" "$2")"
}

# 拼 release asset 的下载 URL。owner/repo 通常来自 GITHUB_REPOSITORY,tag
# 通常是 rolling。
#   release_asset_url <owner/repo> <tag> <asset_name>
release_asset_url() {
    local repo="$1" tag="$2" asset="$3"
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$repo" "$tag" "$asset"
}
