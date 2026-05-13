#!/usr/bin/env bash
# scripts/lib/image-tags.sh
#
# 集中所有 GHCR 镜像 tag 的拼写规则，避免在多个 workflow / 脚本里重复写
# "sdk-${target}-${ref}" 这种字面量。改 tag 规则只需要改这一处。
#
# 依赖：scripts/lib/slugify.sh (slugify + source_slug)
#
# 用法（source 后调用）：
#   source scripts/lib/slugify.sh
#   source scripts/lib/image-tags.sh
#
#   prefix=$(image_prefix "$OWNER_LC" "$REPO_NAME_LC")
#       # → ghcr.io/lrize/openwrt-build
#
#   sdk_image=$(sdk_image_tag "$prefix" "mediatek/filogic" "K-Lrize/openwrt" "main")
#       # → ghcr.io/lrize/openwrt-build:sdk-mediatek-filogic-K-Lrize-openwrt-main
#
#   ib_image=$(ib_image_tag "$prefix" "$target" "$repo" "$ref")
#   pool_image=$(pool_image_tag "$prefix" "$repo" "$ref")
#
# 约定：
#   - SDK / IB：tag = <kind>-<target_slug>-<source_slug>
#   - Pool   ：tag = packages-<source_slug>   （Pool 跨 target，不分 target_slug）
#   - <source_slug> = <repo_slug>-<ref_slug>

image_prefix() {
    local owner_lc="$1"
    local repo_name_lc="$2"
    printf 'ghcr.io/%s/%s\n' "$owner_lc" "$repo_name_lc"
}

sdk_image_tag() {
    local prefix="$1" target="$2" repo="$3" ref="$4"
    printf '%s:sdk-%s-%s\n' "$prefix" "$(slugify "$target")" "$(source_slug "$repo" "$ref")"
}

ib_image_tag() {
    local prefix="$1" target="$2" repo="$3" ref="$4"
    printf '%s:ib-%s-%s\n' "$prefix" "$(slugify "$target")" "$(source_slug "$repo" "$ref")"
}

pool_image_tag() {
    local prefix="$1" repo="$2" ref="$3"
    printf '%s:packages-%s\n' "$prefix" "$(source_slug "$repo" "$ref")"
}
