#!/usr/bin/env bash
# scripts/ci/finalize-pool.sh
#
# 汇总各 chunk 编出的扩展包 → 在 SDK 容器内生成标准索引 (opkg/apk 兼容) →
# 生成全局去重清单 → 打成 Global Package Pool 的 GHCR 镜像并推送。
#
# 参数：
#   $1: pool chunks 目录 (download-artifact merge 后的目录，内含 <arch>/<feed>/*.ipk)
#   $2: build-config 目录 (用于取 .github/docker/Dockerfile.packages)
#   $3: pool 镜像名称 (如 ghcr.io/owner/repo:packages-<ref_slug>)
#   $4: 用于建索引的 SDK 镜像 (任选一个架构的 SDK 即可)
#
# 副产物：在 cwd 留下 global-manifest.txt，供调用方上传到 Release (人类可读)。

set -euo pipefail

POOL_CHUNKS_DIR="$1"
BUILD_CONFIG_DIR="$2"
POOL_IMAGE="$3"
SDK_IMAGE="$4"

CTX="docker-packages"
MANIFEST="global-manifest.txt"

echo "开始构建 Global Package Pool 镜像..."

# 1. 结构化汇总到 docker 构建上下文
rm -rf "$CTX"
mkdir -p "$CTX/pool" "$CTX/manifests"
if [ -d "$POOL_CHUNKS_DIR" ]; then
    echo "正在汇总各 chunk 的扩展包 (保持 <arch>/<feed> 结构)..."
    cp -ra "$POOL_CHUNKS_DIR"/. "$CTX/pool/" 2>/dev/null || true
fi
# 清理 compile-in-sdk.sh 留下的 .targets 之类非包文件
find "$CTX/pool" -name '.targets' -delete 2>/dev/null || true

if [ -z "$(find "$CTX/pool" -type f \( -name '*.ipk' -o -name '*.apk' \) 2>/dev/null)" ]; then
    echo "::warning::Package Pool 为空，跳过镜像构建。"
    : > "$MANIFEST"
    exit 0
fi

# 修正权限：SDK 容器内可能以非 root 写索引文件
sudo chmod -R 777 "$CTX/pool"

# 2. 在 SDK 容器内生成标准化索引 (递归处理所有含包的目录)
echo "正在启动 SDK 容器进行标准化索引..."
docker pull "$SDK_IMAGE" || { sleep 10; docker pull "$SDK_IMAGE"; }
docker run --rm -v "$(pwd)/$CTX/pool":/repo -w /repo "$SDK_IMAGE" bash -c '
    set -euo pipefail
    find . -type f \( -name "*.ipk" -o -name "*.apk" \) -exec dirname {} \; | sort -u | while read -r dir; do
        echo "正在索引目录: $dir"
        if ls "$dir"/*.ipk >/dev/null 2>&1; then
            /home/builder/scripts/ipkg-make-index.sh "$dir" > "$dir/Packages"
            gzip -9nc "$dir/Packages" > "$dir/Packages.gz"
        fi
        if ls "$dir"/*.apk >/dev/null 2>&1; then
            apk mkndx -o "$dir/APKINDEX.tar.gz" "$dir"/*.apk 2>/dev/null || true
        fi
    done
'

# 3. 生成全局去重清单 (供 firmware 轨 Analyze-Diff 使用)
echo "正在生成全局清单..."
find "$CTX/pool" -type f \( -name "*.ipk" -o -name "*.apk" \) | \
    xargs -n1 basename | \
    sed -E 's/\.(ipk|apk)$//' | \
    sed -E 's/_[0-9][^_]*_[a-z0-9_-]+$//' | \
    sort -u > "$MANIFEST"
cp "$MANIFEST" "$CTX/manifests/$MANIFEST"
echo "全局清单包数量: $(wc -l < "$MANIFEST")"

# 4. 构建并推送 pool 镜像
cp "$BUILD_CONFIG_DIR/.github/docker/Dockerfile.packages" "$CTX/Dockerfile"
docker build -t "$POOL_IMAGE" "$CTX/"
docker push "$POOL_IMAGE" || { sleep 10; docker push "$POOL_IMAGE"; }
echo "Global Package Pool 镜像已推送: $POOL_IMAGE"
