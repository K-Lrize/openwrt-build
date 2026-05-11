#!/usr/bin/env bash
# scripts/lib/slugify.sh
#
# 文件名/分支名/registry 标识符归一化。所有 ghcr 镜像 tag、Release 文件名、
# artifact 命名都用此函数，确保跨 workflow 一致。
#
# 用法（source 后调用）：
#   source scripts/lib/slugify.sh
#   target_slug=$(slugify "mediatek/filogic")     # → mediatek-filogic
#   ref_slug=$(slugify "release/24.10")           # → release-24.10
#   ref_slug=$(slugify "feature/foo bar")         # → feature-foo_bar
#
# 规则：
#   1. '/' → '-'                   （路径分隔变层级分隔）
#   2. 其他非 [A-Za-z0-9.-_] → '_'
#   3. 末尾连续 '_' 去掉            （避免 trailing underscore）

slugify() {
    echo "$1" | tr '/' '-' | tr -c 'a-zA-Z0-9.-' '_' | sed 's/_*$//'
}
