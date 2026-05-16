# openwrt-build 架构

本仓库是 OpenWrt 固件的**配置仓库**，不是 OpenWrt 源码。上游源码在
`K-Lrize/openwrt`（fork），通过 GHA 拉下来配合本仓库的配置出固件。

## 一、目标和约束

| 目标 | 当前选择 |
|---|---|
| 多设备共享同一套包套餐，加包改一处全设备同步 | preset 套餐 + 设备 `+/-` 增删 |
| 改硬件无关的配置（套餐、common 文件）能快速出固件 | SDK + IB 增量轨道 |
| 改设备特化或加新设备走最常用路径 | IB-based firmware.yml |
| 上游 OpenWrt 升级引入新依赖时不静默漂移 | Tier3 probe-missing 兜底 + 强制 surface |
| GHA 月度耗时控制 | Base 月度全量重建 + Pool 增量重建 + Firmware 增量出固件 |
| 单一信息源，避免两文件同步漂移 | `common/presets/` 是 pool 编什么的唯一来源 |

## 二、三轨工作流

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      ① Base 轨 (base.yml)                                │
│  ─────────                                                               │
│  on:                                                                     │
│    push: common/base-config, common/feeds.conf, feeds/local/**,          │
│          scripts/sdk/**, .github/workflows/_base-target.yml,             │
│          .github/workflows/base.yml                                      │
│    schedule: 月度 (上游 OpenWrt 跟进)                                    │
│    workflow_dispatch                                                     │
│                                                                          │
│  做什么:                                                                 │
│    1. 完整 buildroot per target (kmod + base packages + toolchain)       │
│    2. 产出 SDK + IB tarball + IB manifest                                │
│    3. 末尾自动 dispatch pool-update.yml (Base 重建后 Pool 必须重建)      │
│                                                                          │
│  产物 (release tag = base-rolling):                                      │
│    sdk-<target>-<source>.tar.zst                                         │
│    ib-<target>-<source>.tar.zst                                          │
│    ib-<target>-<source>.manifest.txt                                     │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                      ② Pool 轨 (pool-update.yml)                         │
│  ─────────                                                               │
│  on:                                                                     │
│    push: common/presets/**, feeds/local/**, common/feeds.conf,           │
│          scripts/sdk/**, scripts/ci/select-chunk.sh,                     │
│          .github/workflows/_pool-build.yml,                              │
│          .github/workflows/_pool-finalize.yml,                           │
│          .github/workflows/pool-update.yml                               │
│    workflow_dispatch (修了套餐想单独跑用)                                │
│                                                                          │
│  做什么:                                                                 │
│    1. 从 base-rolling 下载 SDK tar                                       │
│    2. presets/*.list union 去重 = pool 编译清单                          │
│    3. 4-chunk 并发 SDK package/compile                                   │
│    4. 各 chunk 产物按 arch 合并、生成 Packages.gz / APKINDEX.tar.gz      │
│                                                                          │
│  产物 (release tag = pool-rolling):                                      │
│    pool-<arch>-<source>.tar.zst                                          │
│    pool-<source>.manifest.txt                                            │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                      ③ Firmware 轨 (firmware.yml)                        │
│  ─────────                                                               │
│  on:                                                                     │
│    push: devices/**, common/files/**, common/scripts/**, scripts/ib/**,  │
│          .github/workflows/_*-image.yml, .github/workflows/firmware.yml  │
│    workflow_dispatch                                                     │
│                                                                          │
│  做什么 (per device):                                                    │
│    1. Probe-Missing  下载 IB + pool tar, make manifest dry-run,          │
│                      抽出 missing 包名 + conflict 警告                   │
│    2. Aggregate      按 arch 聚合各设备的 missing                        │
│    3. Build-Patches  per arch 跑 Tier3 SDK 补编 (正常路径=空)            │
│    4. Assemble-Image per device IB 装 pool+tier3+files 出固件            │
│                                                                          │
│  产物 (release tag = firmware-rolling):                                  │
│    <device>-*-sysupgrade.bin, <device>-*-factory.bin                     │
│    <device>-sha256sums.txt, <device>-*.manifest                          │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│   救援轨 (firmware-full.yml)   完整 buildroot 出单设备固件               │
│   - workflow_dispatch only                                               │
│   - 用途: SDK/IB tar 出问题、device-tree 改动冒烟、深度调试              │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│   CI 轨 (validate.yml)         lint + defconfig dry-run                  │
│   - on: pull_request, push 配置类文件                                    │
│   - jobs: Lint-Presets, Defconfig-Validate                               │
└─────────────────────────────────────────────────────────────────────────┘
```

## 三、配置文件布局

```
common/
├── base-config              内核 + kmod 兜底 + toolchain runtime + multi-variant provides
│                            被 ① Base 轨用,内置进 IB tar
├── feeds.conf               所有轨道共享的 feeds 源
├── presets/                 ★ 包套餐 (G2 方案)
│   ├── core.list              所有路由器都要的基础包
│   ├── network.list           网络扩展 (sqm/smartdns/banip 等)
│   ├── ipv6.list              IPv6 / WireGuard
│   ├── proxy.list             代理 (sing-box)
│   ├── mobile.list            4G/5G modem
│   ├── cli.list               CLI 增强 / 调试 / 维护
│   ├── monitoring.list        监控
│   ├── maintenance.list       维护 (acme/ddns/watchcat 等)
│   └── _extras.list           归属未定的游离包(下划线开头, 不被 device 默认引用)
├── files/                   通用 rootfs 文件层 (etc/dropbear, root/.zshrc, etc/banner)
└── scripts/                 通用 image-time 脚本 (prepare-zsh-plugins.sh)

devices/<dev>/
├── target.conf              ★ 硬件 + arch
│                            顶部一行 `# arch: <name>` 是 arch 唯一来源
├── packages.list            ★ @preset <name> 引用套餐 + +pkg/-pkg 个性增删
├── feeds.conf               设备特有 feeds (可选,如 passwall_packages)
├── files/                   设备 rootfs override (覆盖 common/files/)
└── scripts/                 设备 image-time 脚本

feeds/local/                 本地 src-link feed (自维护包)
└── sing-box/                  feeds/local/<pkg>/Makefile

scripts/
├── lib/                     纯函数库, 只可被 source, 无副作用, 不 cd
│   ├── extract-config.sh      .config / target.conf 解析
│   ├── expand-packages.sh     packages.list → 最终 +/- 清单 (@preset 展开)
│   ├── slugify.sh             命名归一化
│   ├── asset-names.sh         release asset 命名规则
│   ├── pkg-filter.sh          kmod 守门、注释剥除
│   └── pkg-list.sh            合并、切片
├── sdk/                     第一参数永远 --workdir <SDK_ROOT> (有 ./scripts/feeds + Makefile)
│   ├── prepare.sh             feeds 拼装 + install
│   ├── compile.sh             批量 package/compile
│   └── index.sh               生成 Packages.gz / APKINDEX.tar.gz
├── ib/                      第一参数永远 --workdir <IB_ROOT> (有 Makefile + packages/)
│   │                        OR buildroot 根 (firmware-full 路径复用)
│   ├── prepare-repo.sh        把外部 ipk/apk 注入 IB packages/
│   ├── probe-missing.sh       make manifest dry-run, 反解 missing/conflict
│   ├── make-image.sh          make image
│   ├── merge-files.sh         合并 common/files + devices/<dev>/files → ./files
│   └── run-image-scripts.sh   跑 common/scripts/ + devices/<dev>/scripts/
└── ci/                      跑在 GHA runner 顶层, 不假设有 workdir
    ├── calculate-matrix.sh    自动发现设备 + 算 target 矩阵 + asset 名
    ├── select-chunk.sh        从 presets union 切第 N/M 片 (pool 用)
    ├── merge-missing-info.sh  按 arch 聚合各设备 missing 包名
    ├── lint-presets.sh        presets/*.list + devices/*/packages.list 静态校验
    ├── validate-config.sh     defconfig 后种子保留校验
    └── checksums.sh           生成 sha256sums.txt
```

## 四、配置文件语义约定

### `target.conf` 样例

```
# arch: aarch64_cortex-a53
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_glinet_gl-mt3600be=y
```

- 顶部一行 `# arch: <name>` 是 arch 唯一来源 (extract_arch 只看这一行)
- 接下来三行 `CONFIG_TARGET_*=y` 选 target/subtarget/device

### `packages.list` 样例

```
# devices/mt3600be/packages.list
@preset core
@preset network
@preset ipv6
@preset proxy
@preset mobile
@preset cli
@preset monitoring
@preset maintenance

# 设备特化增删
+iperf3                     # 套餐外个性加
-dnsmasq                    # 排除 IB DEFAULT_PACKAGES 的老 dnsmasq
-wpad-basic-mbedtls         # 排除多变体
```

语法：
- `@preset <name>`：引用 `common/presets/<name>.list`,展开为该套餐所有包,前缀视为 `+`
- `+<pkg>`：装这个包（喂给 IB `make image PACKAGES=`）
- `-<pkg>`：从 IB DEFAULT_PACKAGES 排除（避免 multi-variant conflict）
- `# 行尾注释`、整行注释 OK
- 包名必须存在于某个 preset 里（lint 强制；`-pkg` 排除 IB 默认包不受此限）

### `common/base-config` 语义

只放四类东西：
1. **kmod** (=m)：被 `CONFIG_ALL_KMODS=y` 全覆盖，写在这里是为了内核选项联动；
   罕见 kmod 必须显式写
2. **toolchain runtime** (=y)：`libatomic1` `libstdcpp6` 等被 C/C++ 应用 metadata depends 的运行时
3. **multi-variant provides 兜底** (=m)：`iptables-nft` `wpad-openssl` `wpad-basic-mbedtls`
   `libmbedtls` `libwolfssl` 等通过 PROVIDES 满足别名链
4. **全设备通用强制内置包** (=y)：`luci=y` `ca-bundle=y` `curl=y` 这种没必要在 preset 里反复写

**禁止**在 base-config 里写设备特化包——那些应该走 `devices/<dev>/packages.list`。

### `common/presets/*.list` 语义

```
# common/presets/cli.list
# CLI 增强 / 调试 / 维护
zsh
vim-full
tmux
jq
ncdu
lsof
htop
tcpdump
socat
drill
git
git-http
iperf3
openssh-sftp-server
rsync
```

- 一行一包,字符集 `[a-zA-Z0-9._+-]+`
- 容忍空行、整行注释、行尾注释
- **禁止 kmod-***：kmod 走 `common/base-config`（SDK 编 kmod 需要内核选项联动）
- preset 之间不应有重叠（lint 会 warn）

### `_extras.list` 特殊约定

`_` 开头的 preset 不会被 `@preset *.list` 通配引用，必须显式 `@preset _extras`。
用途：还没决定归属的"游离包"先丢这里，pool 仍然会编。

## 五、Tier3 (SDK 补编) 角色

正常路径 G2 套餐 + 严格 lint 之后，`firmware.yml` 的 Probe-Missing 报 `missing=0`,
Build-Patches matrix 是空数组,job skip。Tier3 99% 时间空跑。

它真正干活的场景:

| 场景 | 原因 | SDK 能否救 |
|---|---|---|
| **A. base-config 反向依赖闭包小遗漏** | 上游 OpenWrt 升级带新 Depends 别名,base-config 滞后 | 能 — 临时编出,固件出得来,事后补 base-config 重跑 base |
| **B. lint 漏判** | packages.list 写 +pkg 但 pkg 不在任何 preset | 能 — 兜底编出,事后修 lint 或加 preset |
| **C. 新内核 kmod 需要内核 symbol** | base-config 没 select 对应 kmod,内核选项=n | 不能 — `failed.txt` 留记录,firmware.yml 红,逼你改 base-config |
| **D. rust 包** | SDK 默认不带 rust toolchain | 不能 — 同 C,得改 buildroot 配置加 CONFIG_RUST=y |
| **E. 新 arch 首发** | base-rolling 没该 arch 的 SDK/IB tar | 救不了 — 先跑 base.yml,再跑 pool/firmware |

保留 Tier3 的本质：让"能救"的常见情况自动救（场景 A/B），把"救不了"的暴露成
CI 红线（场景 C/D），而非静默通过。

## 六、命名与 release asset

所有 release asset 命名集中在 `scripts/lib/asset-names.sh`。

| Asset | 模式 | 例 |
|---|---|---|
| SDK tar | `sdk-<target_slug>-<source_slug>.tar.zst` | `sdk-mediatek-filogic-K-Lrize-openwrt-main.tar.zst` |
| IB tar | `ib-<target_slug>-<source_slug>.tar.zst` | `ib-mediatek-filogic-K-Lrize-openwrt-main.tar.zst` |
| IB manifest | `ib-<target_slug>-<source_slug>.manifest.txt` | (同上 .manifest.txt) |
| Pool tar (per arch) | `pool-<arch_slug>-<source_slug>.tar.zst` | `pool-aarch64_cortex-a53-K-Lrize-openwrt-main.tar.zst` |
| Pool manifest (跨 arch) | `pool-<source_slug>.manifest.txt` | `pool-K-Lrize-openwrt-main.manifest.txt` |

`source_slug = slugify(repo)-slugify(ref)`，避免 fork 仓库的相同分支名撞 tag。
`target_slug = slugify(target)`，"`/`→`-`，其他非 `[A-Za-z0-9.-_]`→`_`。

| Release tag | 用途 |
|---|---|
| `base-rolling` | SDK + IB tar + IB manifest |
| `pool-rolling` | pool-<arch>-* tar + pool manifest |
| `firmware-rolling` | 各设备最终固件 + sha256sums |

## 七、添加新设备 / 新包 / 新套餐

### 加一个新可选包（比如 `mtr`）

1. 选一个 preset 给它归属（比如 `cli`），在 `common/presets/cli.list` 加一行 `mtr`
2. push → `pool-update.yml` 自动触发 → mtr.ipk 进 pool tarball
3. 想装它的设备在 `devices/<dev>/packages.list` 加 `+mtr` 或直接 `@preset cli`
4. push → `firmware.yml` 出固件，IB 直接从 pool 装上

如果暂时还没决定归哪个套餐：丢 `common/presets/_extras.list`，事后再归位。

### 加一台新设备（同 arch）

```bash
mkdir -p devices/<new-dev>/{files,scripts}
# 写 target.conf（顶部带 # arch: 注释）
# 写 packages.list（@preset 选套餐 + 个性 +/-）
# 可选: files/, scripts/, feeds.conf
git push
# firmware.yml 自动触发 → 出固件
```

### 加一台新设备（新 arch）

```bash
# 同上写好 devices/<new-dev>/
# 但 base-rolling 没这 arch 的 SDK/IB
# 必须先手动 dispatch base.yml (一次)
gh workflow run base.yml
# 等完后, push 设备目录, firmware.yml 自动跑
```

### 加一个新 preset

1. 新建 `common/presets/<name>.list`
2. 在某个 device 的 `packages.list` 用 `@preset <name>` 引用
3. push → pool 自动重编（如果新 preset 有新增包）→ firmware 自动出

## 八、本地调试约定

`scripts/lib/expand-packages.sh` 可独立 CLI 调用：

```bash
bash scripts/lib/expand-packages.sh devices/mt3600be/packages.list
# 输出:
#   +curl
#   +ca-bundle
#   ... (所有 @preset 展开 + 个性增删 + 去重)
```

`scripts/ib/probe-missing.sh` 在已解压的 IB workdir 内可独立跑：

```bash
bash scripts/ib/probe-missing.sh \
    --workdir /path/to/ib-extracted \
    --device-config devices/mt3600be \
    --output missing.json \
    --conflicts conflicts.txt
```

`scripts/sdk/compile.sh` 同理。这些脚本在 GHA 和本地表现完全一致——脚本自己不依赖 GHA 环境变量。

## 九、不变量 (invariants)

下面这些约定**任何 PR 不得违反**，违反一条架构基础就崩：

1. `scripts/lib/*` 不 cd、不写文件、不假设 cwd —— 纯函数库
2. `scripts/sdk/*` 第一参数永远 `--workdir`，是 SDK 根
3. `scripts/ib/*` 第一参数永远 `--workdir`，是 IB 根或 buildroot 根
4. `scripts/ci/*` 不假设有 workdir，靠 cwd / CONF_DIR 参数定位
5. `common/presets/*.list` 是 pool 编什么的**唯一**信息源，pool 工作流不读其他文件
6. `target.conf` 顶部一行 `# arch:` 是 arch 的**唯一**来源
7. `devices/<dev>/packages.list` 里 `+pkg` 必须在某 preset 里（lint 强制）
8. `common/base-config` 里**不写设备特化包**
9. Release asset 命名只从 `scripts/lib/asset-names.sh` 出
10. 工作流 YAML 文件以 `_` 前缀的是 reusable 子流，无前缀的是用户入口

## 十、未决事项

- `firmware.yml` 的"新 arch 但 base-rolling 没 SDK" 情况目前会红，未来可加一步
  preflight 检测后给清晰提示
- `probe-missing.sh` 检测出 conflict 后可半自动生成 `packages.list -pkg` 补丁
  PR 评论
- `_extras.list` 长期累积"游离包"是反模式，定期 review 归位（人维护）
