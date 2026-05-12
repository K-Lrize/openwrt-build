#!/usr/bin/env bash
# 脚本职责：提取 SDK/IB 产物并准备 Docker 构建上下文
# 参数：
#   $1: Build Config 目录路径 (build-config)
#   $2: OpenWrt 编译产物目录 (bin/targets)

set -euo pipefail

CONF_DIR="$1"
TARGET_DIR="$2"

IB_CTX="docker-ib"
SDK_CTX="docker-sdk"

echo "开始准备 Docker 构建上下文..."

# 1. 建立干净的工作目录
rm -rf "$IB_CTX" "$SDK_CTX"
mkdir -p "$IB_CTX/ib-root" "$IB_CTX/manifests"
mkdir -p "$SDK_CTX/sdk-root"

# 2. 处理 ImageBuilder
echo "正在提取 ImageBuilder..."
IB_TAR=$(find "$TARGET_DIR" -name "openwrt-imagebuilder-*.tar.*" | head -n1)
if [ -z "$IB_TAR" ]; then
    echo "::error::未找到 ImageBuilder 压缩包"
    exit 1
fi

if [[ "$IB_TAR" == *.zst ]]; then
    tar --use-compress-program=unzstd -xf "$IB_TAR" --strip-components=1 -C "$IB_CTX/ib-root"
else
    tar -xf "$IB_TAR" --strip-components=1 -C "$IB_CTX/ib-root"
fi

# 3. 提取全量 Manifest (物理扫描法：最准确，不漏包)
echo "正在生成内置软件包清单..."
find "$IB_CTX/ib-root/packages/" -type f \( -name "*.ipk" -o -name "*.apk" \) | \
    xargs -n1 basename | \
    sed -E 's/\.(ipk|apk)$//' | \
    sed -E 's/_[0-9][^_]*_[a-z0-9_-]+$//' | \
    sort -u > "$IB_CTX/manifests/installed_packages.txt"

echo "底座已内置软件包数量: $(wc -l < "$IB_CTX/manifests/installed_packages.txt")"
cp "$CONF_DIR/.github/docker/Dockerfile.imagebuilder" "$IB_CTX/Dockerfile"

# 4. 处理 SDK
echo "正在提取 SDK..."
SDK_TAR=$(find "$TARGET_DIR" -name "openwrt-sdk-*.tar.*" | head -n1)
if [ -z "$SDK_TAR" ]; then
    echo "::error::未找到 SDK 压缩包"
    exit 1
fi

if [[ "$SDK_TAR" == *.zst ]]; then
    tar --use-compress-program=unzstd -xf "$SDK_TAR" --strip-components=1 -C "$SDK_CTX/sdk-root"
else
    tar -xf "$SDK_TAR" --strip-components=1 -C "$SDK_CTX/sdk-root"
fi

# 5. 固化 Base 源到 SDK (实现打包进镜像)
echo "正在固化 Base 软件包源到 SDK..."
# 注意：OpenWrt 源码根目录的 package/ 目录即为 base 源的核心内容
# 我们将其拷贝到 SDK 的 base-packages 目录下，后续配合 src-link 使用
mkdir -p "$SDK_CTX/sdk-root/base-packages"
cp -ra package/* "$SDK_CTX/sdk-root/base-packages/"
# 清理可能存在的软链接（指向主源码外部的），确保 SDK 镜像完全自给自足
find "$SDK_CTX/sdk-root/base-packages" -type l -delete

cp "$CONF_DIR/.github/docker/Dockerfile.sdk" "$SDK_CTX/Dockerfile"

echo "Docker 上下文准备完成。"
