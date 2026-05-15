#!/usr/bin/env bash
# scripts/sdk/compile.sh
#
# 在「已 prepare 过的 SDK workdir」里跑配置式批量编译。
# 取代旧 scripts/build/compile-in-sdk.sh 的编译逻辑(不含 docker run)。
# Pool / Tier3 两条线共用,差异只通过参数体现。
#
# 用法:
#   sdk/compile.sh \
#       --workdir <SDK_ROOT>          已解压且已 prepare 完毕的 SDK 根
#       --packages <FILE>             已清洗的包清单,一行一包
#       --out <DIR>                   产物输出根 (packages/ logs/ .reports/)
#       [--seed-config <FILE>]        覆盖 SDK 自带 .config (tier3 用 combined.config)
#       [--jobs N]                    默认 nproc;Mac 上自动退回 sysctl 检测
#       [--strict]                    defconfig 后包名缺失 → exit 1
#       [--no-retry]                  关闭 -jN 失败自动 -j1 V=s 重试
#
# 输出 <OUT>/:
#   packages/<arch>/<feed>/*.ipk         (cp -a 自 SDK 的 bin/packages/)
#   logs/package/<pkg>/...               (失败时的详细日志)
#   .reports/requested.txt               (经清洗后的最终清单)
#   .reports/missing-after-defconfig.txt (拼写错 / feed 缺失 / 被剔除)
#   .reports/failed.txt                  (defconfig 过了但编译失败)
#
# 退出码:
#   0   全部 OK,或 lenient 模式下部分失败
#   1   strict 模式下 defconfig 缺包,或致命错误 (workdir 无效)
#   2   -jN + 单线程都失败 (CI 应 surface 为 warning,产物部分缺失)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg-filter.sh
source "$SCRIPT_DIR/../lib/pkg-filter.sh"

WORKDIR=""
PKG_FILE=""
OUT=""
SEED_CONFIG=""
JOBS=""
STRICT=0
NO_RETRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)      WORKDIR="$2"; shift 2 ;;
        --packages)     PKG_FILE="$2"; shift 2 ;;
        --out)          OUT="$2"; shift 2 ;;
        --seed-config)  SEED_CONFIG="$2"; shift 2 ;;
        --jobs)         JOBS="$2"; shift 2 ;;
        --strict)       STRICT=1; shift ;;
        --no-retry)     NO_RETRY=1; shift ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::sdk/compile: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$WORKDIR"  ] || { echo "::error::sdk/compile: 缺少 --workdir"  >&2; exit 2; }
[ -n "$PKG_FILE" ] || { echo "::error::sdk/compile: 缺少 --packages" >&2; exit 2; }
[ -n "$OUT"      ] || { echo "::error::sdk/compile: 缺少 --out"      >&2; exit 2; }

WORKDIR="$(cd "$WORKDIR" && pwd)"
PKG_FILE="$(cd "$(dirname "$PKG_FILE")" && pwd)/$(basename "$PKG_FILE")"
mkdir -p "$OUT" "$OUT/.reports"
OUT="$(cd "$OUT" && pwd)"
[ -n "$SEED_CONFIG" ] && SEED_CONFIG="$(cd "$(dirname "$SEED_CONFIG")" && pwd)/$(basename "$SEED_CONFIG")"

if [ ! -x "$WORKDIR/scripts/feeds" ] || [ ! -e "$WORKDIR/Makefile" ]; then
    echo "::error::sdk/compile: $WORKDIR 不是 OpenWrt SDK 根 (缺 scripts/feeds 或 Makefile)" >&2
    exit 1
fi

if [ -z "$JOBS" ]; then
    if command -v nproc >/dev/null 2>&1; then
        JOBS="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1; then
        JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    else
        JOBS=4
    fi
fi

cd "$WORKDIR"

REQUESTED="$OUT/.reports/requested.txt"
MISSING="$OUT/.reports/missing-after-defconfig.txt"
FAILED="$OUT/.reports/failed.txt"

# 1. 清洗清单。SDK 实际能编 kmod (Module.symvers + 预编 *.ko 在 SDK tar 内),
# 用 'keep' 保留 kmod 条目;调用方上层若想守门可用 error/warn。
pkg_filter_clean keep < "$PKG_FILE" > "$REQUESTED"

if [ ! -s "$REQUESTED" ]; then
    echo "::warning::sdk/compile: 清洗后清单为空,跳过编译。"
    : > "$MISSING"
    : > "$FAILED"
    exit 0
fi

echo "::group::sdk/compile: 待编译包 ($(wc -l < "$REQUESTED" | tr -d ' ') 个)"
cat "$REQUESTED"
echo "::endgroup::"

# 2. .config 拼装
echo "::group::种 .config"
if [ -n "$SEED_CONFIG" ]; then
    if [ ! -f "$SEED_CONFIG" ]; then
        echo "::error::sdk/compile: seed-config 不存在: $SEED_CONFIG" >&2
        exit 1
    fi
    echo "应用 seed-config -> .config"
    cp "$SEED_CONFIG" .config
fi
awk '{ printf "CONFIG_PACKAGE_%s=m\n", $0 }' "$REQUESTED" >> .config
echo ".config 末尾 20 行:"
tail -n 20 .config
echo "::endgroup::"

echo "::group::make defconfig"
make defconfig
echo "::endgroup::"

# 3. 语义校验
echo "::group::语义校验 — defconfig 后哪些请求包丢了?"
: > "$MISSING"
while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if ! grep -qE "^CONFIG_PACKAGE_${pkg}=[ym]" .config; then
        printf '%s\n' "$pkg" >> "$MISSING"
    fi
done < "$REQUESTED"

if [ -s "$MISSING" ]; then
    miss_n="$(wc -l < "$MISSING" | tr -d ' ')"
    echo "::warning::${miss_n} 个包在 defconfig 后丢失 (拼写错 / feed 缺失 / 被依赖剔除):"
    sed 's/^/  - /' "$MISSING"
    if [ "$STRICT" = "1" ]; then
        echo "::error::--strict 模式,因丢失包阻断编译。"
        exit 1
    fi
    echo "lenient 模式,继续编译可用部分。"
else
    echo "全部请求包通过 defconfig 解析。"
fi
echo "::endgroup::"

# 4. 编译
echo "::group::make -j${JOBS} package/compile (IGNORE_ERRORS=\"n m\")"
compile_ok=1
if ! make -j"${JOBS}" package/compile IGNORE_ERRORS="n m" BUILD_LOG=1; then
    compile_ok=0
    if [ "$NO_RETRY" = "0" ]; then
        echo "::warning::-j${JOBS} 失败,降级 -j1 V=s 重试。"
        if make -j1 V=s package/compile IGNORE_ERRORS="n m" BUILD_LOG=1; then
            compile_ok=1
        fi
    fi
fi
echo "::endgroup::"

# 5. 整理产物
echo "::group::整理产物"
mkdir -p "$OUT/packages" "$OUT/logs"
[ -d bin/packages ] && cp -ra bin/packages/. "$OUT/packages/" 2>/dev/null || true
[ -d logs/package ] && cp -ra logs/package "$OUT/logs/" 2>/dev/null || true

: > "$FAILED"
while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    # defconfig 阶段已经记 missing 的不重复计入 failed
    if grep -qx "$pkg" "$MISSING" 2>/dev/null; then continue; fi
    if ! find "$OUT/packages" -maxdepth 4 -type f \
            \( -name "${pkg}_*.ipk" -o -name "${pkg}-*.apk" \) \
            -print -quit 2>/dev/null | grep -q .; then
        printf '%s\n' "$pkg" >> "$FAILED"
    fi
done < "$REQUESTED"

if [ -s "$FAILED" ]; then
    echo "::warning::请求但未产出包文件 (编译失败 / 被父包合并 / 被裁剪):"
    sed 's/^/  - /' "$FAILED"
fi
echo "::endgroup::"

if [ "$compile_ok" = "0" ]; then
    echo "::error::package/compile 多线程与单线程均失败,部分包未产出。"
    exit 2
fi
