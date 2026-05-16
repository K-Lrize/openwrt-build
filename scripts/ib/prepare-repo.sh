#!/usr/bin/env bash
# scripts/ib/prepare-repo.sh
#
# 把外部 ipk/apk (pool 包 + fallback 补编) 注入已解压的 ImageBuilder workdir。
#
# 现代 OpenWrt IB (2024-12 切到 APK 之后,且 _base-target.yml 用 CONFIG_IB_STANDALONE=y)
# 顶层不再有 repositories.conf / repositories 文件 — IB Makefile 的 APK 命令是:
#
#   APK := apk ... \
#          $(if $(CONFIG_IB_STANDALONE),,--repositories-file $(TOPDIR)/repositories) \
#          --repository $(PACKAGE_DIR)/packages.adb \
#          $(if $(CONFIG_SIGNATURE_CHECK),,--allow-untrusted) \
#
# STANDALONE 模式下完全只看 $TOPDIR/packages/packages.adb,不读外部 repo。
# 上游 `make target/imagebuilder/install` 当前 (2026-Q2) 不预生成 packages.adb,
# 留给用户在 `make image` 链路里通过 `package_index` target 现场生成。但
# `make manifest` 不一定走同一条依赖链 — 索引缺失时 apk add 看到空仓,所有包
# 都会报 `(no such package)`,包括 IB 自带的 base-files / libc / kernel。
#
# 因此本脚本只需:
#   1. 校验 $WORKDIR 是 IB 根 (有 Makefile + packages/)
#   2. 把 $PACKAGES_DIR 下的 ipk/apk 复制进 $WORKDIR/packages/
#   3. 显式跑一次 `make package_index` 把 IB 自带 + 注入的包统一索引到 packages.adb,
#      让后续 probe-missing.sh / make-image.sh 看到完整闭包
#
# 用法:
#   ib/prepare-repo.sh \
#       --workdir <IB_ROOT>          必填,已解压的 IB 根
#       --packages-dir <DIR>         必填,pool + fallback 合并后的 ipk/apk 目录 (扁平)

set -euo pipefail

WORKDIR=""
PACKAGES_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)       WORKDIR="$2"; shift 2 ;;
        --packages-dir)  PACKAGES_DIR="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "::error::ib/prepare-repo: 未知参数 $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$WORKDIR"      ] || { echo "::error::ib/prepare-repo: 缺少 --workdir"      >&2; exit 2; }
[ -n "$PACKAGES_DIR" ] || { echo "::error::ib/prepare-repo: 缺少 --packages-dir" >&2; exit 2; }

WORKDIR="$(cd "$WORKDIR" && pwd)"
PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"

if [ ! -f "$WORKDIR/Makefile" ] || [ ! -d "$WORKDIR/packages" ]; then
    echo "::error::ib/prepare-repo: $WORKDIR 不像 IB 根 (缺 Makefile 或 packages/)" >&2
    echo "::group::ib-root listing"
    ls -la "$WORKDIR" >&2 || true
    echo "::endgroup::"
    exit 1
fi

# 把外部 ipk/apk 平铺复制进 IB 的 PACKAGE_DIR。
# IB 的 packages/ 本来就是单一目录(IB tar 自带预编译的 base 包),追加即可。
copied=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    cp -f "$f" "$WORKDIR/packages/"
    copied=$((copied + 1))
done < <(find "$PACKAGES_DIR" -maxdepth 4 -type f \( -name '*.ipk' -o -name '*.apk' \))

if [ "$copied" -eq 0 ]; then
    echo "::warning::ib/prepare-repo: $PACKAGES_DIR 下无 ipk/apk,无文件注入 (仅索引 IB 自带包)。"
fi

# 显式重建 package index。
# 上游 IB tar 不含 packages.adb,且 `make manifest` 不强制依赖 package_index,
# 所以必须在这里主动生成,否则 STANDALONE 模式下 apk 看到空仓 → 全部包 missing。
# 即便没注入新包,IB 自带的 1000+ 个 .apk 也需要索引才能被 probe / make image 查到。
#
# apk mkndx 是 all-or-nothing: 任何一个 .apk 让 mkndx 报 `file format is invalid`,
# 整个 packages.adb 都不创建 (而非"少几条记录")。上游 IB Makefile 的 package_index
# 用 `>/dev/null 2>/dev/null || true` 把这种致命失败伪装成无声成功 — 后续 apk add
# 就拿空仓装包。我们这里:
#   1) 直接调 apk 不藏 stderr
#   2) 失败时解析 stderr 提取 invalid 文件,隔离到 packages/.broken/
#   3) 隔离后重跑 mkndx — 这时 packages.adb 必生成
#   4) 把被隔离的包暴露成 GHA warning,probe-missing 会自然把它们报为 missing
#      → Compile-Fallback 走 SDK 补编兜底
echo "ib/prepare-repo: 重建 package index..."

APK_BIN="$WORKDIR/staging_dir/host/bin/apk"
if [ ! -x "$APK_BIN" ]; then
    APK_BIN=$(find "$WORKDIR" -name apk -type f -perm -111 2>/dev/null | head -n 1) || true
fi
[ -x "$APK_BIN" ] || {
    echo "::error::ib/prepare-repo: 找不到 apk 可执行 (期望在 staging_dir/host/bin/apk)" >&2
    exit 1
}

mkndx_log="$(mktemp)"
trap 'rm -f "$mkndx_log"' EXIT

run_mkndx() {
    ( cd "$WORKDIR/packages" && "$APK_BIN" mkndx --allow-untrusted --output packages.adb *.apk ) \
        >"$mkndx_log" 2>&1
}

# 循环重试: mkndx 是 all-or-nothing,但它**只报第一批**遇到的坏文件就退出。
# 实际坏包数量 > 第一批 stderr 报的数量是常见情况 (上游 25.12 过渡期):
#   round 1: 报 cfdisk + colrm → 隔离
#   round 2: 报 ca-certificates → 隔离
#   round 3: 成功
# 错误格式 (多种 reason):
#   ERROR: cfdisk-2.42-r1.apk: file format is invalid or inconsistent
#   ERROR: ca-certificates-...apk: ADB block error
# 通用解析: `^ERROR: <name>.apk: <任何 reason>`,排除汇总行 "N errors, not creating index"
max_rounds=8
round=1
isolated_all=""

while :; do
    if run_mkndx; then
        break
    fi

    echo "::group::mkndx 第 $round 轮失败,完整输出"
    cat "$mkndx_log" >&2
    echo "::endgroup::"

    if [ "$round" -ge "$max_rounds" ]; then
        echo "::error::ib/prepare-repo: 重试 $max_rounds 轮仍失败,放弃 — 见上方日志" >&2
        exit 1
    fi

    invalid=$(awk -F': ' '
        /^ERROR: .*\.apk: / && $0 !~ /errors, not creating index/ {
            line = $0
            sub(/^ERROR: /, "", line)
            sub(/: .*$/, "", line)
            print line
        }' "$mkndx_log" | sort -u)

    if [ -z "$invalid" ]; then
        echo "::error::ib/prepare-repo: mkndx 失败但无法从 stderr 解析 invalid 包名 (第 $round 轮)" >&2
        exit 1
    fi

    mkdir -p "$WORKDIR/packages/.broken"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ ! -f "$WORKDIR/packages/$f" ]; then
            echo "::error::ib/prepare-repo: 解析出的 invalid 文件 $f 不存在,解析逻辑可能有误" >&2
            exit 1
        fi
        mv "$WORKDIR/packages/$f" "$WORKDIR/packages/.broken/" || {
            echo "::error::ib/prepare-repo: 无法隔离 $f" >&2
            exit 1
        }
        isolated_all+="$f"$'\n'
    done <<<"$invalid"

    round=$((round + 1))
done

if [ -n "$isolated_all" ]; then
    n_isolated=$(printf '%s' "$isolated_all" | grep -c .)
    echo "::warning::ib/prepare-repo: 上游 IB tar 含 $n_isolated 个无法被 apk mkndx 索引的 .apk,已隔离到 packages/.broken/ (经过 $((round - 1)) 轮重试)"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "::warning::ib/prepare-repo:   - $f"
    done <<<"$isolated_all"
fi

if [ ! -f "$WORKDIR/packages/packages.adb" ]; then
    echo "::error::ib/prepare-repo: mkndx 报成功但 packages.adb 未生成 (apk-tools 行为异常)" >&2
    exit 1
fi

n_indexed=$(find "$WORKDIR/packages" -maxdepth 1 -type f -name '*.apk' | wc -l | tr -d ' ')
echo "ib/prepare-repo: 注入 $copied 个外部 ipk/apk,packages.adb 已索引 $n_indexed 个 .apk"
