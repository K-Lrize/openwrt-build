#!/usr/bin/env bash
# ============================================================
# OpenWrt 配置验证 + 依赖诊断脚本
# 用法: validate-config.sh <seed_config> <device_id>
# 前置条件: 在 OpenWrt 源码目录下，已完成 make defconfig
# ============================================================
set -euo pipefail

SEED="${1:?用法: validate-config.sh <seed_config> <device_id>}"
DEVICE="${2:?用法: validate-config.sh <seed_config> <device_id>}"

if [[ ! -f "$SEED" ]]; then
  echo "::error::seed config 不存在: ${SEED}"
  exit 1
fi
if [[ ! -f .config ]]; then
  echo "::error::当前目录下未找到 .config（请先执行 make defconfig）"
  exit 1
fi

# ── 分类计数 ──────────────────────────────────────────────
MISSING=()
DISABLED=()
DISABLED_DETAILS=()
OK=0
TOTAL=0

# ── 逐行扫描 seed config ─────────────────────────────────
while IFS= read -r line; do
  # 只检查包配置项（CONFIG_PACKAGE_*），跳过 TARGET / KERNEL / BUILD 等非包选项
  if [[ "$line" =~ ^(CONFIG_PACKAGE_[A-Za-z0-9_+.-]+)=y$ ]]; then
    key="${BASH_REMATCH[1]}"
    ((TOTAL++)) || true

    if grep -q "^${key}=y" .config 2>/dev/null; then
      # ✅ 有效：defconfig 后仍为 =y
      ((OK++)) || true

    elif grep -q "^# ${key} is not set" .config 2>/dev/null; then
      # ⚠️ 包存在但被 Kconfig 禁用（依赖未满足或平台不支持）
      DISABLED+=("$key")

      # ── 依赖诊断 ──────────────────────────────────────
      pkg_name="${key#CONFIG_PACKAGE_}"
      diag=""

      # 在 feeds/ 下查找包的 Makefile
      makefile=$(find feeds -name "Makefile" -path "*/${pkg_name}/Makefile" 2>/dev/null | head -1)

      if [[ -n "$makefile" ]]; then
        # 从 Makefile 的 DEPENDS 行提取依赖列表
        bad_deps=""
        while IFS= read -r dep; do
          # 去除 + 前缀和空格
          dep="${dep//+/}"
          dep="${dep// /}"
          # 跳过空行和条件标记（@ARCH, @TARGET 等）
          [[ -z "$dep" || "$dep" == @* ]] && continue
          dep_key="CONFIG_PACKAGE_${dep}"
          if grep -q "^# ${dep_key} is not set" .config 2>/dev/null; then
            bad_deps="${bad_deps} \`${dep}\`(未选中)"
          elif ! grep -q "^${dep_key}" .config 2>/dev/null; then
            bad_deps="${bad_deps} \`${dep}\`(不存在)"
          fi
        done < <(grep -E '^\s*(DEPENDS|PKG_BUILD_DEPENDS)\s*[\+:]?=' "$makefile" \
                 | sed 's/.*[+:]=//' | tr ' +\\' '\n' | grep -v '^$' | grep -v '^@' || true)

        if [[ -n "$bad_deps" ]]; then
          diag="缺少依赖:${bad_deps}"
        else
          diag="依赖已选中，可能是平台/ARCH 限制（TARGET 条件不满足）"
        fi
      else
        diag="未找到 Makefile（可能是 kmod 或内置包，由平台 Kconfig 管理）"
      fi

      DISABLED_DETAILS+=("${pkg_name}|${diag}")

    else
      # ❌ defconfig 中完全找不到此选项 → 包不存在于 feeds
      MISSING+=("$key")
    fi
  fi
done < "$SEED"

# ── 输出 Step Summary（Markdown 表格）────────────────────
SUMMARY_TARGET="${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "## 配置验证报告 — ${DEVICE}"
  echo ""
  echo "| 项目 | 数量 |"
  echo "|---|---|"
  echo "| 检测总数 | ${TOTAL} |"
  echo "| ✅ 有效 | ${OK} |"
  echo "| ❌ 包不存在 | ${#MISSING[@]} |"
  echo "| ⚠️ 依赖冲突 | ${#DISABLED[@]} |"

  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    echo "### ❌ 不存在的包"
    echo ""
    echo "以下配置项在 feeds 中找不到对应包，请检查拼写或确认 feeds 是否包含此包："
    echo ""
    echo "| 配置项 |"
    echo "|---|"
    for key in "${MISSING[@]}"; do
      echo "| \`${key}\` |"
    done
  fi

  if [[ ${#DISABLED[@]} -gt 0 ]]; then
    echo ""
    echo "### ⚠️ 被 Kconfig 禁用的包（依赖诊断）"
    echo ""
    echo "以下包存在于 feeds 中，但 \`make defconfig\` 后被禁用："
    echo ""
    echo "| 包名 | 诊断 |"
    echo "|---|---|"
    for detail in "${DISABLED_DETAILS[@]}"; do
      pkg="${detail%%|*}"
      diag="${detail#*|}"
      echo "| \`${pkg}\` | ${diag} |"
    done
    echo ""
    echo "> **修复建议**："
    echo "> - 「缺少依赖」→ 在 seed config 中补充对应依赖包"
    echo "> - 「平台/ARCH 限制」→ 该包可能不支持目标平台，考虑移除"
    echo "> - 「未找到 Makefile」→ 内核模块由平台 Kconfig 管理，检查 TARGET 是否正确"
  fi

  if [[ ${#MISSING[@]} -eq 0 && ${#DISABLED[@]} -eq 0 ]]; then
    echo ""
    echo "所有 ${TOTAL} 个包配置项验证通过。"
  fi
} | tee -a "$SUMMARY_TARGET"

# ── 输出 Action Outputs ──────────────────────────────────
OUTPUT_TARGET="${GITHUB_OUTPUT:-/dev/null}"
echo "missing_count=${#MISSING[@]}" >> "$OUTPUT_TARGET"
echo "disabled_count=${#DISABLED[@]}" >> "$OUTPUT_TARGET"

# ── 退出码决策 ────────────────────────────────────────────
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "::error::${DEVICE}: ${#MISSING[@]} 个包在 feeds 中不存在，禁止继续"
  exit 1
fi

if [[ ${#DISABLED[@]} -gt 0 ]]; then
  echo "::warning::${DEVICE}: ${#DISABLED[@]} 个包被 Kconfig 禁用（见上方诊断）"
fi
