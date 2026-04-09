#!/usr/bin/env bash
# 脚本职责：为编译出的固件生成 SHA256 校验和与产物清单
set -euo pipefail

TARGET_PATH="${1:?用法: $0 <target_path>}"

echo "::group::生成固件校验和"
if [[ -d "$TARGET_PATH" ]]; then
    cd "$TARGET_PATH"

    # 查找所有文件并计算 sha256sum，排除掉已存在的校验文件本身
    # 使用 find 确保只处理当前目录的文件
    mapfile -d '' files < <(find . -maxdepth 1 -type f ! -name "sha256sums.txt" -print0 | sort -z)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "::error::目标路径 $TARGET_PATH 中没有可发布的产物。"
        exit 1
    fi
    sha256sum "${files[@]}" > sha256sums.txt

    echo "校验文件: sha256sums.txt"
    echo "校验条目: $(wc -l < sha256sums.txt)"
else
    echo "::error::目标路径 $TARGET_PATH 不存在，无法生成校验和。"
    exit 1
fi
echo "::endgroup::"
