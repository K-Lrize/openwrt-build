#!/usr/bin/env bash
# scripts/lib/pkg-list.sh
#
# 包名清单的合并/切分。配合 lib/pkg-filter.sh 使用:先清洗再切分。
#
# 用法 (source 后作为 bash 函数调用):
#   source scripts/lib/pkg-list.sh
#   pkg_list_merge_unique a.txt b.txt > merged.txt
#   pkg_list_chunk 2 4 < merged.txt > chunk-2.txt
#
# 用法 (CLI 直接调用):
#   bash scripts/lib/pkg-list.sh merge a.txt b.txt > merged.txt
#   bash scripts/lib/pkg-list.sh chunk 2 4 < merged.txt > chunk-2.txt
#
# 设计:
#   - merge:  多文件合并,按首次出现顺序去重(stable),不重排
#   - chunk:  按 (NR-1) % total == chunk_id 取片,保持顺序
#     与旧 scripts/ci/select-pool-chunk.sh:44 算法等价,迁移行为零回归。
#     未来如需 hash-based 稳定切分,独立 PR 切换。

pkg_list_merge_unique() {
    awk '!seen[$0]++' "$@"
}

pkg_list_chunk() {
    local chunk_id="${1:?用法: pkg_list_chunk <chunk_id> <total>}"
    local total="${2:?用法: pkg_list_chunk <chunk_id> <total>}"
    case "$chunk_id" in *[!0-9]*) echo "pkg_list_chunk: chunk_id 必须为非负整数: $chunk_id" >&2; return 2 ;; esac
    case "$total"    in *[!0-9]*) echo "pkg_list_chunk: total 必须为正整数: $total" >&2; return 2 ;; esac
    [ "$total" -gt 0 ] || { echo "pkg_list_chunk: total 必须 > 0" >&2; return 2; }
    [ "$chunk_id" -lt "$total" ] || { echo "pkg_list_chunk: chunk_id ($chunk_id) 必须 < total ($total)" >&2; return 2; }
    awk -v cid="$chunk_id" -v tot="$total" '((NR - 1) % tot) == cid'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        merge) pkg_list_merge_unique "$@" ;;
        chunk) pkg_list_chunk "$@" ;;
        *)
            cat >&2 <<EOF
用法:
  bash $0 merge <file> [<file>...]   # 合并文件,首次出现顺序去重
  bash $0 chunk <chunk_id> <total>   # 从 stdin 取第 chunk_id/total 片到 stdout
EOF
            exit 2
            ;;
    esac
fi
