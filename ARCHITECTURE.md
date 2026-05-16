# openwrt-build 架构

本仓库是 OpenWrt 固件的**配置仓库**,不是 OpenWrt 源码。上游源码在
`K-Lrize/openwrt`(fork),通过 GHA 拉下来配合本仓库的配置出固件。

## 目录

1. [目标和约束](#一目标和约束)
2. [三轨工作流](#二三轨工作流)
3. [配置文件布局](#三配置文件布局)
4. [配置文件语义约定](#四配置文件语义约定)
5. [SDK 兜底补编 (fallback) 角色](#五sdk-兜底补编-fallback-角色)
6. [命名与 release asset](#六命名与-release-asset)
7. [添加新设备 / 新包 / 新套餐](#七添加新设备--新包--新套餐)
8. [本地调试约定](#八本地调试约定)
9. [端到端数据流](#九端到端数据流)
10. [全局变量与 GHA outputs 对照表](#十全局变量与-gha-outputs-对照表)
11. [不变量 (invariants)](#十一不变量-invariants)
12. [未决事项](#十二未决事项)

---

## 一、目标和约束

| 目标 | 当前选择 |
|---|---|
| 多设备共享同一套包套餐,加包改一处全设备同步 | preset 套餐 + 设备 `+/-` 增删 |
| 改硬件无关的配置 (套餐、common 文件) 能快速出固件 | SDK + IB 增量轨道 |
| 改设备特化或加新设备走最常用路径 | IB-based firmware.yml |
| 上游 OpenWrt 升级引入新依赖时不静默漂移 | firmware.yml probe-missing + SDK fallback 兜底 + 强制 surface |
| GHA 月度耗时控制 | Base 月度全量重建 + Pool 增量重建 + Firmware 增量出固件 |
| 同一信息单一处声明,避免多文件同步漂移 | `common/presets/` 是 pool 编什么的唯一信息源 |

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
│          .github/workflows/_firmware-*.yml, firmware.yml                 │
│    workflow_dispatch                                                     │
│                                                                          │
│  做什么 (per device):                                                    │
│    1. Probe-Missing       下载 IB + pool tar, make manifest dry-run,    │
│                           抽出 missing 包名 + conflict 警告              │
│    2. Aggregate-Missing   按 arch 聚合各设备 missing                     │
│    3. Compile-Fallback    per arch 跑 SDK 兜底补编 (正常路径=空)        │
│    4. Assemble-Firmware   per device IB 装 (pool + fallback + files)    │
│                           出固件                                         │
│    5. Publish             汇总推 firmware-rolling                        │
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
│   - jobs: Lint-Presets, Validate-Defconfig                               │
└─────────────────────────────────────────────────────────────────────────┘
```

## 三、配置文件布局

```
common/
├── base-config              全局开关 + 内置 kmod + toolchain runtime + multi-variant provides
│                            被 ① Base 轨用, 内置进 SDK / IB tar
├── feeds.conf               所有轨道共享的 feeds 源
├── presets/                 ★ 包套餐 (设备级 packages.list 通过 @preset 引用)
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
│                            顶部一行 `# arch: <name>` 是 arch 唯一信息源
├── packages.list            ★ @preset <name> 引用套餐 + +pkg/-pkg 个性增删
├── feeds.conf               设备特有 feeds (可选, 如 passwall_packages)
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

- 顶部一行 `# arch: <name>` 是 arch 唯一信息源 (extract_arch 只看这一行)
- 接下来三行 `CONFIG_TARGET_*=y` 选 target / subtarget / device

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

语法:
- `@preset <name>`:引用 `common/presets/<name>.list`,展开为该套餐所有包,前缀视为 `+`
- `+<pkg>`:装这个包 (喂给 IB `make image PACKAGES=`)
- `-<pkg>`:从 IB DEFAULT_PACKAGES 排除 (避免 multi-variant conflict)
- `# 行尾注释`、整行注释 OK
- 包名必须存在于某个 preset 里 (lint 强制;`-pkg` 排除 IB 默认包不受此限)

### `common/base-config` 语义

只放四类东西:
1. **Buildroot 全局开关** (`CONFIG_DEVEL`/`ALL_KMODS`/`SDK`/`IB`/`IB_STANDALONE`):
   集中到 base-config 顶部,而非散落在 workflow 的 heredoc
2. **必须内置内核的 kmod** (=y):启动早期即生效,如 `kmod-tun=y` `kmod-pppoe=y`
   `kmod-nft-tproxy=y`;其他 kmod 由 `ALL_KMODS=y` 默认 =m,**不必重复声明**
3. **Multi-variant provides 兜底** (=m):`iptables-nft` `wpad-openssl`
   `wpad-basic-mbedtls` `libmbedtls` `libwolfssl` 等通过 PROVIDES 满足别名链
4. **全设备通用强制内置包** (=y):`luci` `ca-bundle` `curl` `dnsmasq-full`
   这种没必要在 preset 里反复写
5. **Toolchain runtime + 高频反向依赖** (=y/=m):`libatomic1` `libstdcpp6`
   `libpcre2` `libsqlite3` `libnettle` 等

**禁止**在 base-config 里写设备特化包 —— 那些应该走 `devices/<dev>/packages.list`。

> **=y vs =m 的语义** (本仓库语境下):
> - kmod 的 =y / =m 真有区别 (前者编进 vmlinuz, 后者编 .ko 模块)
> - 用户态包的 =y / =m 对最终固件**没有直接影响** —— IB 装什么由 IB 自己的
>   `DEFAULT_PACKAGES`(来自上游 `target/linux/<board>/Makefile`)+ `PACKAGES=`
>   参数(我们从 `packages.list` 算出)决定, 跟 base-config 的 =y/=m 无关
> - 但 =y 让 buildroot 把该包编进自带 image (我们不用), =m 让该包编出 ipk
>   到 SDK/IB packages/ — 所以 =m 也能进 IB tar, 二者对我们等价

### `common/presets/*.list` 语义

```
# common/presets/cli.list — Shell 增强 + 诊断
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
rsync
openssh-sftp-server
iperf3
```

- 一行一包,字符集 `[a-zA-Z0-9._+-]+`
- 容忍空行、整行注释、行尾注释
- **禁止 kmod-***:kmod 走 `common/base-config`(SDK 编 kmod 需要内核选项联动)
- preset 之间不应有重叠 (lint 会 warn)

### `_extras.list` 特殊约定

`_` 开头的 preset 不会被 `@preset *.list` 通配引用,必须显式 `@preset _extras`。
用途:还没决定归属的"游离包"先丢这里,pool 仍然会编。

## 五、SDK 兜底补编 (fallback) 角色

固件最终装的 ipk 来自三处, 按优先级 / 来源区分:

| 来源 | 谁产出 | 何时编 | 走哪个 release |
|---|---|---|---|
| **IB 内置包** | `base.yml` 完整 buildroot | 改 `common/base-config` / 月度调度 | base-rolling 的 IB tar 自带 |
| **Pool 包** | `pool-update.yml` SDK 预编 | 改 `common/presets/*.list` | pool-rolling |
| **Fallback 补编** | `firmware.yml` 的 `Compile-Fallback` 现编 | Probe-Missing 检出 missing 才编 | 不发 release, 仅作 artifact 临时用 |

正常路径 (preset 套餐配置完整 + lint 通过) 之后, `firmware.yml` 的 Probe-Missing
报 `missing=0`, `Compile-Fallback` 的 matrix 是空数组, job skip。**fallback 99%
时间空跑**, 真正干活只在异常路径:

| 场景 | 原因 | SDK fallback 能否救 |
|---|---|---|
| **A. base-config 反向依赖闭包小遗漏** | 上游 OpenWrt 升级带新 Depends 别名, base-config 滞后 | 能 — 临时编出, 固件出得来, 事后补 base-config 重跑 base |
| **B. lint 漏判** | packages.list 写 +pkg 但 pkg 不在任何 preset | 能 — 兜底编出, 事后修 lint 或加 preset |
| **C. 新内核 kmod 需要内核 symbol** | base-config 没 select 对应 kmod, 内核选项=n | 不能 — `failed.txt` 留记录, firmware.yml 红, 逼你改 base-config |
| **D. rust 包** | SDK 默认不带 rust toolchain | 不能 — 同 C, 得改 buildroot 配置加 CONFIG_RUST=y |
| **E. 新 arch 首发** | base-rolling 没该 arch 的 SDK/IB tar | 救不了 — 先跑 base.yml, 再跑 pool/firmware |

保留 fallback 的本质:让"能救"的常见情况自动救 (场景 A/B), 把"救不了"的暴露成
CI 红线 (场景 C/D), 而非静默通过。

## 六、命名与 release asset

所有 release asset 命名集中在 `scripts/lib/asset-names.sh`。

| Asset | 模式 | 例 |
|---|---|---|
| SDK tar | `sdk-<target_slug>-<source_slug>.tar.zst` | `sdk-mediatek-filogic-K-Lrize-openwrt-main.tar.zst` |
| IB tar | `ib-<target_slug>-<source_slug>.tar.zst` | `ib-mediatek-filogic-K-Lrize-openwrt-main.tar.zst` |
| IB manifest | `ib-<target_slug>-<source_slug>.manifest.txt` | (同上 .manifest.txt) |
| Pool tar (per arch) | `pool-<arch_slug>-<source_slug>.tar.zst` | `pool-aarch64_cortex-a53-K-Lrize-openwrt-main.tar.zst` |
| Pool manifest (跨 arch) | `pool-<source_slug>.manifest.txt` | `pool-K-Lrize-openwrt-main.manifest.txt` |

`source_slug = slugify(repo)-slugify(ref)`,避免 fork 仓库的相同分支名撞 tag。
`target_slug = slugify(target)`,`/`→`-`,其他非 `[A-Za-z0-9.-_]`→`_`。

| Release tag | 用途 |
|---|---|
| `base-rolling` | SDK + IB tar + IB manifest |
| `pool-rolling` | pool-<arch>-* tar + pool manifest |
| `firmware-rolling` | 各设备最终固件 + sha256sums |

## 七、添加新设备 / 新包 / 新套餐

### 加一个新可选包 (比如 `mtr`)

1. 选一个 preset 给它归属 (比如 `cli`),在 `common/presets/cli.list` 加一行 `mtr`
2. push → `pool-update.yml` 自动触发 → mtr.ipk 进 pool tarball
3. 想装它的设备在 `devices/<dev>/packages.list` 加 `+mtr` 或直接 `@preset cli`
4. push → `firmware.yml` 出固件,IB 直接从 pool 装上

如果暂时还没决定归哪个套餐:丢 `common/presets/_extras.list`,事后再归位。

### 加一台新设备 (同 arch)

```bash
mkdir -p devices/<new-dev>/{files,scripts}
# 写 target.conf (顶部带 # arch: 注释)
# 写 packages.list (@preset 选套餐 + 个性 +/-)
# 可选: files/, scripts/, feeds.conf
git push
# firmware.yml 自动触发 → 出固件
```

### 加一台新设备 (新 arch)

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
3. push → pool 自动重编 (如果新 preset 有新增包) → firmware 自动出

## 八、本地调试约定

`scripts/lib/expand-packages.sh` 可独立 CLI 调用:

```bash
bash scripts/lib/expand-packages.sh devices/mt3600be/packages.list common/presets
# 输出:
#   +curl
#   +ca-bundle
#   ... (所有 @preset 展开 + 个性增删 + 去重)
```

`scripts/ib/probe-missing.sh` 在已解压的 IB workdir 内可独立跑:

```bash
bash scripts/ib/probe-missing.sh \
    --workdir /path/to/ib-extracted \
    --device-dir devices/mt3600be \
    --output missing.json \
    --conflicts conflicts.txt
```

`scripts/sdk/compile.sh` 同理。这些脚本在 GHA 和本地表现完全一致 —— 脚本自己不依赖 GHA 环境变量。

## 九、端到端数据流

每条轨道按 job 顺序逐步标出**输入文件**、**主要中间产物**、**输出 artifact / release asset**,
以及 job-to-job 的 GHA outputs 传递。

### 9.1 Base 轨数据流

```
                         ┌────────────────────────┐
                         │ devices/*/target.conf  │
                         │ common/base-config     │
                         │ common/feeds.conf      │
                         │ feeds/local/**         │
                         └──────────┬─────────────┘
                                    │ checkout
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Initialize  (ci/calculate-matrix.sh)                                 │
│   读: devices/*/target.conf                                          │
│   出 GHA outputs:                                                    │
│     target_matrix      = ["mediatek/filogic", ...]                  │
│     source_slug        = "K-Lrize-openwrt-main"                     │
│     openwrt_repo / openwrt_ref                                       │
└──────────────────────────────────────────────────────────────────────┘
                                    │ matrix fan-out per target
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Build-Base  (_base-target.yml, per target)                           │
│   1. Checkout 上游 OpenWrt @ openwrt_ref                             │
│   2. sdk/prepare.sh --workdir .   拼 feeds.conf + feeds update/install│
│   3. Compose .config:                                                │
│        CONFIG_TARGET_<board>=y                                       │
│        CONFIG_TARGET_<board>_<sub>=y                                 │
│        + 同 target 所有设备的 _DEVICE_<profile>=y 行 (拉 DEVICE_PACKAGES)│
│        + common/base-config (含 ALL_KMODS=y / SDK=y / IB=y / 兜底库) │
│   4. make defconfig → download → tools → toolchain → kernel          │
│      → package/{compile,install} → target/linux/install              │
│      → target/sdk/install → target/imagebuilder/install              │
│   5. Stage SDK tar:                                                  │
│        unzip 上游 sdk.tar → 注入 package/* 到 base-packages/ →       │
│        重新打包 → release-staging/sdk-<target>-<source>.tar.zst      │
│   6. Stage IB tar + manifest:                                        │
│        cp 上游 ib.tar → release-staging/ib-<target>-<source>.tar.zst │
│        扫 IB packages/*.ipk|*.apk → release-staging/*.manifest.txt   │
│   7. upload-artifact infrastructure-<target_slug>-<source_slug>      │
└──────────────────────────────────────────────────────────────────────┘
                                    │ artifact fan-in
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Publish-Base-Release                                                 │
│   - download-artifact pattern: infrastructure-*-<source_slug>        │
│   - softprops/action-gh-release → tag=base-rolling                   │
└──────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Trigger-Pool-Update                                                  │
│   - gh workflow run pool-update.yml -f openwrt_repo=... openwrt_ref=...│
│     strict=true update_release=true                                  │
└──────────────────────────────────────────────────────────────────────┘
```

### 9.2 Pool 轨数据流

```
                         ┌────────────────────────┐
                         │ common/presets/*.list  │
                         │ common/feeds.conf      │
                         │ devices/*/target.conf  │  (用来算 target_matrix)
                         └──────────┬─────────────┘
                                    │ checkout
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Initialize  (ci/calculate-matrix.sh)                                 │
│   出: target_matrix_with_meta                                        │
│         [{target, target_slug, sdk_tar_name, ib_tar_name, ...}, ...] │
│      source_slug                                                     │
│      pool_manifest_name = "pool-<source_slug>.manifest.txt"          │
│      indexer_sdk_tar_name = 任选第一个 SDK tar (给 finalize 用)      │
└──────────────────────────────────────────────────────────────────────┘
                                    │ fan-out per target × 4 chunks
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Build-Pool  (_pool-build.yml, per target × chunk 0..3)              │
│   1. gh release download base-rolling/<sdk_tar_name>                 │
│      → tar -xf → sdk-work/                                           │
│   2. ci/select-chunk.sh                                              │
│        读 common/presets/*.list union (含 _extras.list)              │
│        ↓ pkg_filter_clean error (守门 kmod)                          │
│        ↓ pkg_list_merge_unique (首次出现去重保序)                    │
│        ↓ pkg_list_chunk <id>/4                                       │
│      → chunk.txt                                                     │
│   3. sdk/prepare.sh --packages chunk.txt                             │
│      (按清单 install, 不退化到 -a)                                   │
│   4. sdk/compile.sh --strict --packages chunk.txt --out pool-out/   │
│   5. upload-artifact pool-chunk-<target>-<source>-<chunk>            │
│      path: pool-out/packages/                                        │
└──────────────────────────────────────────────────────────────────────┘
                                    │ artifact fan-in (所有 target × 4 chunk)
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Finalize-Pool  (_pool-finalize.yml)                                  │
│   1. download-artifact pool-chunk-*-<source_slug>-* → pool/          │
│   2. gh release download base-rolling/<indexer_sdk_tar_name>         │
│      → sdk-indexer/ (借 ipkg-make-index.sh + host apk)               │
│   3. sdk/index.sh --pool-dir pool/ --sdk-dir sdk-indexer/           │
│      → pool/**/Packages.gz + APKINDEX.tar.gz                         │
│   4. Pack per-arch tarballs:                                         │
│        for arch_dir in pool/*/:                                      │
│          tar -cf pool-<arch>-<source>.tar.zst -C $arch_dir .         │
│      + 跨 arch 单文件 pool-<source>.manifest.txt                     │
│   5. softprops/action-gh-release → tag=pool-rolling                  │
└──────────────────────────────────────────────────────────────────────┘
```

### 9.3 Firmware 轨数据流

```
                         ┌────────────────────────┐
                         │ devices/<dev>/target.conf │
                         │ devices/<dev>/packages.list│
                         │ common/presets/*.list  │
                         │ common/files/**        │
                         │ devices/<dev>/files/** │
                         └──────────┬─────────────┘
                                    │ checkout
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Initialize  (ci/calculate-matrix.sh)                                 │
│   增量检测 (push 时只编动过的 device, schedule/dispatch 时全设备)    │
│   出: device_matrix = ["mt3600be", ...]                              │
│      device_meta = {                                                 │
│        "mt3600be": {arch, target, target_slug, profile,              │
│                     sdk_tar_name, ib_tar_name, ib_manifest_name,    │
│                     pool_tar_name}                                   │
│      }                                                               │
└──────────────────────────────────────────────────────────────────────┘
                                    │ fan-out per device
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Probe-Missing  (per device)                                          │
│   1. gh release download base-rolling/<ib_tar_name> → ib-work/      │
│   2. gh release download pool-rolling/<pool_tar_name>                │
│      → pool-packages/ (允许 404, 按空处理)                          │
│   3. ib/prepare-repo.sh --workdir ib-work --packages-dir pool-packages│
│      合并 pool ipk → ib-work/packages/ + 倒回 mtime 触发重 index     │
│   4. ib/probe-missing.sh --workdir ib-work --device-dir <dev>        │
│        内部:                                                         │
│          - expand_packages_for_ib packages.list common/presets       │
│            → IB PACKAGES= 串 (空格分隔, 含 -pkg 排除项)              │
│          - extract_profile target.conf → PROFILE                     │
│          - cd ib-work && make manifest PROFILE=$P PACKAGES=$P        │
│          - 反解 stderr "(no such package)" → missing.txt             │
│          - 反解 stderr "conflicts:" → conflicts.txt                  │
│      → <device>.json, <device>.conflicts.txt                         │
│   5. upload-artifact missing-info-<device>                           │
└──────────────────────────────────────────────────────────────────────┘
                                    │ artifact fan-in
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Aggregate-Missing  (ci/merge-missing-info.sh)                       │
│   读: all-missing/<dev>.json + device_meta                          │
│   按 arch union 去重 → 每个 arch 选一个"代表设备" (取 sdk_tar_name) │
│   出 GHA output: arch_packages_matrix                                │
│     [{key:<arch>, value:[pkg...], sdk_tar_name, target_slug}, ...]  │
└──────────────────────────────────────────────────────────────────────┘
                                    │ if matrix != '[]' (正常路径为空, skip)
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Compile-Fallback  (_firmware-packages.yml, per arch)                   │
│   1. gh release download base-rolling/<sdk_tar_name> → sdk-work/    │
│   2. Materialize:                                                    │
│        missing.txt ← jq -r '.[]' <<< inputs.packages                │
│        combined.config ← 所有 devices/*/target.conf + base-config    │
│          (保留 target select, 避免 SDK defconfig 报缺 CONFIG_TARGET_*)│
│   3. sdk/prepare.sh --device __all__ --packages missing.txt         │
│   4. sdk/compile.sh --seed-config combined.config --packages missing.txt │
│      → pkg-out/packages/<arch>/                                      │
│   5. Collect pkg-out/packages/<arch>/**/*.{ipk,apk} → fallback-outputs/ │
│   6. upload-artifact fallback-ipks-<arch>                               │
└──────────────────────────────────────────────────────────────────────┘
                                    │ artifact (可能没有, Assemble 不依赖)
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Assemble-Firmware  (_firmware-image.yml, per device)                │
│   1. download-artifact fallback-ipks-<arch> → fallback-packages/ (允许空) │
│   2. gh release download base-rolling/<ib_tar_name> → ib-work/      │
│   3. gh release download pool-rolling/<pool_tar_name> → pool-packages/│
│   4. unified_repo/ ← pool-packages + fallback-packages 平铺            │
│   5. ib/prepare-repo.sh --packages-dir unified_repo                  │
│      → 注入 ib-work/packages/                                        │
│   6. ib/make-image.sh:                                               │
│        PROFILE  = extract_profile devices/<dev>/target.conf          │
│        PACKAGES = expand_packages_for_ib                             │
│                     devices/<dev>/packages.list common/presets       │
│        → cd ib-work && make image PROFILE=$P PACKAGES=$P FILES=files/│
│      内部先调 ib/merge-files.sh 合并 common/files + devices/<dev>/files│
│   7. Collect bin/targets/** → bin/outputs/<device>-*                 │
│      + ci/checksums.sh → <device>-sha256sums.txt                     │
│   8. upload-artifact firmware-<device>                               │
└──────────────────────────────────────────────────────────────────────┘
                                    │ artifact fan-in
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Publish-Firmware-Release                                             │
│   - download-artifact pattern: firmware-*                            │
│   - softprops/action-gh-release → tag=firmware-rolling               │
└──────────────────────────────────────────────────────────────────────┘
```

### 9.4 救援轨 (firmware-full.yml) 数据流

```
                         ┌────────────────────────┐
                         │ devices/<dev>/target.conf  │
                         │ devices/<dev>/packages.list│
                         │ common/base-config     │
                         │ common/presets/*.list  │
                         │ common/files/**        │
                         └──────────┬─────────────┘
                                    │ workflow_dispatch only
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Build-Firmware-Full                                                  │
│   1. Checkout 上游 OpenWrt + build-config                            │
│   2. sdk/prepare.sh --device <dev>                                   │
│      ib/merge-files.sh <dev> → ./files/                              │
│   3. Compose .config (三段):                                         │
│        a) devices/<dev>/target.conf  (硬件 select + arch 注释)       │
│        b) common/base-config         (全局开关 + kmod + 兜底)        │
│        c) expand_packages packages.list  (+pkg → CONFIG_PACKAGE_pkg=y;│
│                                            -pkg 在此阶段忽略)        │
│      + ccache/sccache 开关                                           │
│   4. ib/run-image-scripts.sh <dev>  (common/scripts + device/scripts)│
│   5. make defconfig → download → tools → toolchain → make -j$nproc   │
│      (整链路 buildroot, 不走 SDK / IB)                               │
│   6. Collect bin/targets/** → bin/outputs/<device>-*                 │
│      + checksums.sh                                                  │
│   7. upload-artifact firmware-<device> + build-logs-<device>         │
│   (本轨不推 release, 产物只在 artifact 留 3 天)                       │
└──────────────────────────────────────────────────────────────────────┘
```

### 9.5 CI 轨 (validate.yml) 数据流

```
                         ┌────────────────────────┐
                         │ common/presets/*.list  │
                         │ common/base-config     │
                         │ devices/*/{target.conf, packages.list}│
                         └──────────┬─────────────┘
                                    │ push / pull_request
                                    ▼
┌────────────────────────────┐     ┌──────────────────────────────────────────┐
│ Lint-Presets               │     │ Initialize  (ci/calculate-matrix.sh)     │
│   ci/lint-presets.sh       │     │   增量检测 → device_matrix                │
│   - presets/*.list 字符集 + │     └──────────────────────────────────────────┘
│     kmod 守门 + 包重复检测  │                          │
│   - devices/*/target.conf:  │                          ▼ fan-out
│     '# arch:' + CONFIG_TARGET│   ┌──────────────────────────────────────────┐
│   - devices/*/packages.list:│   │ Validate-Defconfig  (per device)         │
│     @preset 存在性 + +pkg   │   │  1. Checkout OpenWrt + build-config       │
│     在某 preset 内          │   │  2. sdk/prepare.sh --device <dev>         │
└────────────────────────────┘   │  3. Compose seed .config (三段, 同 full):│
                                  │       target.conf + base-config +         │
                                  │       expand(packages.list) → =y         │
                                  │  4. make defconfig                        │
                                  │  5. ci/validate-config.sh <dev>:          │
                                  │       校验 target.conf 的 CONFIG_TARGET_=y│
                                  │       和 base-config 的 =y 都保留         │
                                  │       packages.list 的 +pkg 都 =y         │
                                  │     失败 → exit 1 → CI 红                 │
                                  └──────────────────────────────────────────┘
```

## 十、全局变量与 GHA outputs 对照表

`scripts/ci/calculate-matrix.sh` 是矩阵+命名的**单点**。改输出列表前请先 grep
所有 workflow 文件,看哪些 job 在消费。

| GHA output | 类型 | 例 | 谁产出 | 谁消费 |
|---|---|---|---|---|
| `device_matrix` | JSON array | `["mt3600be"]` | calculate-matrix | firmware.yml `Probe-Missing` / `Assemble-Firmware` 矩阵;validate.yml `Validate-Defconfig` 矩阵 |
| `target_matrix` | JSON array | `["mediatek/filogic"]` | calculate-matrix | base.yml `Build-Base` 矩阵 |
| `target_matrix_with_meta` | JSON array | `[{target, target_slug, sdk_tar_name, ib_tar_name, ib_manifest_name}, ...]` | calculate-matrix | pool-update.yml `Build-Pool` 矩阵 |
| `device_meta` | JSON map | `{"mt3600be": {arch, target, target_slug, profile, sdk_tar_name, ib_tar_name, ib_manifest_name, pool_tar_name}}` | calculate-matrix | firmware.yml `Probe-Missing` env / `Compile-Fallback` inputs / `Assemble-Firmware` inputs |
| `source_slug` | string | `"K-Lrize-openwrt-main"` | calculate-matrix | 几乎所有 workflow (artifact 命名 + asset 命名 + release pattern) |
| `pool_manifest_name` | string | `"pool-K-Lrize-openwrt-main.manifest.txt"` | calculate-matrix | firmware.yml `Probe-Missing` (留作未来诊断) / `_pool-finalize.yml` |
| `indexer_sdk_tar_name` | string | `"sdk-mediatek-filogic-K-Lrize-openwrt-main.tar.zst"` | calculate-matrix | `_pool-finalize.yml` (任选一个 SDK 借 ipkg-make-index.sh) |
| `has_builds` | bool string | `"true" / "false"` | calculate-matrix | firmware.yml / pool-update.yml / validate.yml 各 job 的 `if:` |
| `arch_packages_matrix` | JSON array | `[{key:"aarch64_cortex-a53", value:["pkg-a", ...], sdk_tar_name, target_slug}, ...]` | firmware.yml `Aggregate-Missing` | firmware.yml `Compile-Fallback` 矩阵 |

**Release asset 名约定** (统一在 `scripts/lib/asset-names.sh`):

| Asset | 模板 | 取自 |
|---|---|---|
| SDK tar | `sdk-<target_slug>-<source_slug>.tar.zst` | `sdk_tar_name(target, repo, ref)` |
| IB tar | `ib-<target_slug>-<source_slug>.tar.zst` | `ib_tar_name(target, repo, ref)` |
| IB manifest | `ib-<target_slug>-<source_slug>.manifest.txt` | `ib_manifest_name(...)` |
| Pool tar | `pool-<arch_slug>-<source_slug>.tar.zst` | `pool_tar_name(arch, repo, ref)` |
| Pool manifest | `pool-<source_slug>.manifest.txt` | `pool_manifest_name(repo, ref)` |

**核心数据传递路径** (跨 workflow):

```
   base.yml (Build-Base)
        │  produces release: base-rolling
        │   ├─ sdk-<target>-<source>.tar.zst
        │   ├─ ib-<target>-<source>.tar.zst
        │   └─ ib-<target>-<source>.manifest.txt
        │
        ├──────────── (gh workflow run, async)
        ▼
   pool-update.yml (Build-Pool → Finalize-Pool)
        │  reads release: base-rolling/sdk-*
        │  produces release: pool-rolling
        │   ├─ pool-<arch>-<source>.tar.zst
        │   └─ pool-<source>.manifest.txt
        │
        │ ┌───────────── (push 触发, 各自独立)
        ▼ ▼
   firmware.yml
        │  reads release: base-rolling/ib-*  + pool-rolling/pool-*
        │  produces release: firmware-rolling
        │   ├─ <device>-*-sysupgrade.bin
        │   ├─ <device>-*-factory.bin
        │   ├─ <device>-sha256sums.txt
        │   └─ <device>-*.manifest
```

## 十一、不变量 (invariants)

下面这些约定**任何 PR 不得违反**,违反一条架构基础就崩:

1. `scripts/lib/*` 不 cd、不写文件、不假设 cwd —— 纯函数库
2. `scripts/sdk/*` 第一参数永远 `--workdir`,是 SDK 根
3. `scripts/ib/*` 第一参数永远 `--workdir`,是 IB 根或 buildroot 根
4. `scripts/ci/*` 不假设有 workdir,靠 cwd / `CONF_DIR` 参数定位
5. `common/presets/*.list` 是 pool 编什么的**唯一**信息源,pool 工作流不读其他文件
6. `target.conf` 顶部一行 `# arch:` 是 arch 的**唯一**来源
7. `devices/<dev>/packages.list` 里 `+pkg` 必须在某 preset 里 (lint 强制)
8. `common/base-config` 里**不写设备特化包**
9. Release asset 命名只从 `scripts/lib/asset-names.sh` 出
10. 工作流 YAML 文件以 `_` 前缀的是 reusable 子流,无前缀的是用户入口
11. `_base-target.yml` 的 .config heredoc 不重复 base-config 已有的全局开关
    (避免一处改一处漏)

## 十二、未决事项

- `firmware.yml` 的"新 arch 但 base-rolling 没 SDK" 情况目前会红,未来可加一步
  preflight 检测后给清晰提示
- `probe-missing.sh` 检测出 conflict 后可半自动生成 `packages.list -pkg` 补丁
  PR 评论
- `_extras.list` 长期累积"游离包"是反模式,定期 review 归位 (人维护)
