# H3C HM2004-DU 固件构建（GitHub Actions）

按飞书文档《H3C‑HM2004‑DU 固件编译需求整理（GitHub Actions构建）》落地的**自有**构建仓库。

不 fork 别人的仓库，也不复制别人的 CI 壳子：上游按 commit SHA 取，本仓库只放**差异**（`overlay/`），
差异内容由 CI 原样打成 `overlay.diff` 归档。当前差异规模：**12 个文件、+325/−51 行**。

* 目标设备：H3C HM2004-DU（Airoha AN7581，aarch64 cortex-a53，profile `h3c_hm2004-du`）
* 主干引擎：`LazuliKao/wrt_release`（内置 FTTR 配方与 CI 思路）
* 固件源码树：`LazuliKao/ponwrt@feat/hm2004-npu`（= `pbs05/ponwrt@master` + 5 个 FTTR/PPE 内核补丁提交）
* 参考仓库：`1018ji/merge-immortalwrt-ponwrt`（构建逻辑）

---

## 1. 仓库结构与构建流程

```
pins.env                     上游仓库的 commit 锚点（引擎、源码树、参考树、两个附加 feed）
pins.feeds                   源码树自带 7 个 feed 的 commit 锚点
overlay/                     盖到引擎上的差异（本仓库真正的产物）
  compilecfg/lk_h3c_hm2004_du.ini.tpl    设备构建元信息（带 COMMIT_HASH）
  deconfig/lk_h3c_hm2004_du.config       设备 dotconfig
  deconfig/fragments/{ebpf_btf,honk,fttr}.config
  recipes/feed_pins|ebpf_btf|honk|hm2004_fttr_feed|h3c-hm2004-du_fttr|vantage_feed|luci_theme_vantage
scripts/                     apply_overlay / preclone / load_signing_key
                             assert_prebuild / assert_artifacts / assert_rootfs
                             check_fttr_dts / check_official_fttr
tests/                       dryrun.sh（门禁的正反分支）/ check_recipes.sh
.github/workflows/build.yml  唯一工作流
```

一次构建实际发生的事：

```
pins.env
  └─ apply_overlay.sh   clone 引擎 → checkout ENGINE_SHA → 覆盖 overlay → 打 overlay.diff
       └─ preclone.sh   clone ponwrt → fetch PONWRT_SHA → 交给引擎的 COMMIT_HASH 复位
            └─ load_signing_key.sh   从 Secrets 写 private-key.pem / key-build（不落盘任何密钥到仓库）
                 └─ ./build.sh <目标> debug      只跑到 make defconfig（约 20 分钟）
                      └─ assert_prebuild.sh      构建设置核验：BTF / profile / feed pin / 装机包 / 密钥
                           └─ ./build.sh <目标>  完整编译
                                └─ assert_artifacts.sh   认证物：镜像 / 内核 .config / vmlinux 的 .BTF 段 / manifest
                                     └─ 产物归档（先上传，任何门禁都不得让三小时的镜像消失）
                                          └─ assert_rootfs.sh   抠出镜像里的 squashfs，看真实文件系统
                                               └─ check_fttr_dts.sh → Release
```

`assert_rootfs.sh` 是最后加的，因为它回答的问题是别人回答不了的：`.manifest` 是构建系统的
记账，设备跑的是文件系统。它把镜像里的 squashfs 抠出来解包，直接判
`/www/luci-static/vantage` 在不在、`30_luci-theme-vantage` 在不在而 `990_set_fluent_default`
**必须不在**、中文 `.lmo` 在不在、`cls_bpf.ko`/`act_bpf.ko` 在不在 `/lib/modules/<ver>`、
以及 `/etc/apk/keys` 里有没有公钥（决定设备端软件源能不能验签）。

预检单独跑一次 `debug`，是为了让「配置根本没生效」这类问题在 20 分钟内暴露，而不是等 3 小时后
在 `assert_artifacts.sh` 才红。代价是多跑一遍 feeds，约半小时。

---

## 2. 需求文档逐条对照

### 一、源码合并与基线策略

| 文档要求 | 落地位置 | 状态 |
| --- | --- | --- |
| 以 `LazuliKao/wrt_release` 为主干，保留其 FTTR 插件、CI 工作流、feeds 框架 | `apply_overlay.sh` 按 SHA 取引擎；`ADD_RECIPES` 保留 `airoha_an7581`、`luci_app_airoha_npu` 等原配方 | 做到 |
| PON 对齐 `pbs05/ponwrt`：DTS、mtd、PON 驱动、BOSA 工具、sysupgrade 脚本 | 源码树直接取 ponwrt（见第 3 节的路线说明）；DTS/mtd/board.d/platform.sh 全在该树内 | 做到（换了实现方式） |
| 只移植 PON 硬件层，不整体替换主干内核与基础系统 | 引擎与源码树都不改，差异全部集中在 `overlay/`，`overlay.diff` 可审 | 做到（见第 3 节） |
| 构建系统对齐 `1018ji/merge-immortalwrt-ponwrt` | feed 用 `^<sha>` 锁版本、配置用 base+片段合成、磁盘清理、`make download`/`make` 分离、整目录打包 | 部分采纳 |
| 核心前置：eBPF/BTF 供 honk 运行 | `fragments/ebpf_btf.config` + `recipes/ebpf_btf/files/airoha_an7581_ebpf.config` | 做到 |

`1018ji` 那侧**没有**照搬的三处，以及原因：

1. 它的 `.github/workflows/release.yml` 与 `pbs05/ponwrt` 里的**同一份文件**（blob sha 相同），
   且 `configs/an7581.config` 里**没有** `CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_h3c_hm2004-du=y`
   —— 它根本不出 HM2004-DU 的镜像。所以只借它的方法，不借它的产物定义。
2. 它把 ImmortalWrt 与 ponwrt 用 `git merge` 合在一棵全源码树里维护。这是仓库所有者的做法，
   不适用于「自有仓库 + 按 SHA 取上游」的约束。
3. 它用 `actions/cache@v4 path: dl` 缓存下载；引擎用的是 `.ccache` + `staging_dir` 两级缓存，
   已经覆盖同一目的，不重复引入。
4. 它自维护的两个内核补丁（`hack-6.18/951-net-tcp-bbr3-support.patch`、
   `pending-6.18/675-02-netfilter-bridge-...patch`）**不需要移植**：这两个文件在
   `pbs05/ponwrt@master` 里本来就有（已逐个列目录确认）。1018ji 维护的是「上游 bump 后重新
   打上」的版本，那是它那棵 merge 树才需要的动作；我们的树不做 merge，直接用 ponwrt 自带的。

### 二、内核必选配置

文档写的是裸内核符号；OpenWrt 的 `.config` 里**只有** `config/Config-kernel.in` 暴露的
`CONFIG_KERNEL_*` 才真正可选，其余写进 `.config` 会被 `make defconfig` **静默丢掉**。
所以按符号逐个分流，两处写入、一处校验：

| 文档符号 | 实际做法 | 依据 |
| --- | --- | --- |
| `CONFIG_BPF` / `BPF_SYSCALL` / `BPF_JIT` | 上游 generic 已是 `=y`（`config-6.18:769/770/777`），在子 target 配置里再写明一次 | 已核对 |
| `CONFIG_BPF_STREAM_PARSER` | `CONFIG_KERNEL_BPF_STREAM_PARSER=y`（`Config-kernel.in:694`，`depends on KERNEL_CGROUP_BPF`，故同时开 CGROUP_BPF） | 已核对 |
| `CONFIG_NET_CLS_BPF` / `CONFIG_NET_ACT_BPF` | 子 target 配置追加 `=m`；上游是 `# ... is not set`（`config-6.18:4411/4432`），而 `kmod-sched-bpf` 要靠这两个符号产出 `cls_bpf.ko`/`act_bpf.ko` | 已核对 |
| `CONFIG_BPF_LSM` | **不做**。没有 `KERNEL_BPF_LSM` 可选项，要开得改子 target 配置并把 `bpf` 排进 `CONFIG_LSM` 顺序；honk 走 TC + kprobe，不用 LSM 钩子。为一个用不上的钩子改安全模块初始化顺序，和「稳定优先」冲突 | 判断 |
| `CONFIG_DEBUG_INFO_BTF` | `CONFIG_KERNEL_DEBUG_INFO=y` + `# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set` + `CONFIG_KERNEL_DEBUG_INFO_BTF=y` | **这是真正的卡点**：`KERNEL_DEBUG_INFO_BTF` 的条件是 `depends on KERNEL_DEBUG_INFO && !KERNEL_DEBUG_INFO_REDUCED`，而 `KERNEL_DEBUG_INFO_REDUCED` 的 `default y` 白名单里**没有 airoha**，ponwrt 自己的 `configs/an7581.config:304` 就是 `CONFIG_KERNEL_DEBUG_INFO_REDUCED=y`。不显式关掉 REDUCED，BTF 永远开不了 |
| `CONFIG_KPROBES` / `CONFIG_PERF_EVENTS` | `CONFIG_KERNEL_KPROBES=y`、`CONFIG_KERNEL_PERF_EVENTS=y`（PERF_EVENTS 在 airoha 子 target 里本来已是 `y`） | 已核对 |
| `CONFIG_BPF_CORE` | **不是 Kconfig 符号**，Linux 里不存在。CO-RE 是 BTF + libbpf 的能力，文档把概念写成了配置项 | 已核对 |
| `CONFIG_MODULES` / `CONFIG_MODULE_UNLOAD` | OpenWrt 恒开，不需要也不能在 dotconfig 里设 | 已核对 |

另外补了文档没写但 honk 实际要的：`CONFIG_KERNEL_BPF_EVENTS=y`（它 `select KERNEL_KPROBES`）、
`KERNEL_DYNAMIC_FTRACE`、`KERNEL_DEBUG_FS`、`KERNEL_MODULE_ALLOW_BTF_MISMATCH`（模块拆分 BTF
不匹配时拒绝加载，默认 y 更稳）。host 侧 `dwarves`（pahole）由 `KERNEL_DEBUG_INFO_BTF` 的
`select DWARVES` 带出，工作流里另外显式装了一份，避免 select 链变动后编不出来。

### 三、Feeds 配置参考

源码树自带 `feeds.conf.default`（packages/luci 来自 immortalwrt，routing/telephony/video 来自
openwrt，加 `pbs05/openwrt-pon-drivers`、`pbs05/openwrt-pon-userspace`）。文档里的
`src-git base https://github.com/openwrt/openwrt.git;main` **不需要**——那棵树的 `target/linux/airoha`
里**没有** `an7581-h3c-hm2004-du.dts`，设备集只有 gemtek/nokia/quantum（已对比确认）。

**这 7 个 feed 在上游一个都没锁版本**（`pbs05/ponwrt@master` 的 `feeds.conf.default` 全是分支头），
而参考仓库 `1018ji` 是 7 条全锁 `^<sha>` 的。文档「四、3」要防的正是「上游更新引入破坏性变更」，
所以由 `overlay/recipes/feed_pins/` 在 `pre_feeds` 阶段把 7 条全部锁到 `pins.feeds` 指定的 commit，
`assert_prebuild.sh` 再逐条核对。其中 `pon_drivers`/`pon_userspace` 两个 SHA 与 1018ji 的锁值一致，可交叉印证。

> 残留缺口：引擎 `modules/feeds.sh` 会自己追加两条 bandix 源
> （`timsaya/openwrt-bandix`、`timsaya/luci-app-bandix`），这两条不在我们的锁清单里，仍跟分支头走。

文档留空的 `src-git honk <honk插件仓库地址>` 已查实：
`kenzok8/openwrt-honk`（核心包 `honk` = dae 系 Rust 重写、eBPF 数据面；要求内核 6.12+、
只发 25.12 的 apk 包，架构含 `aarch64_cortex-a53`）。按 SHA 写进 `overlay/recipes/honk/recipe.json`。

### 四、GitHub Actions 构建约束

| 文档要求 | 落地 |
| --- | --- |
| 编译目标 profile `h3c_hm2004_du` | `CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_h3c_hm2004-du=y`，产物名与 manifest 在 `assert_artifacts.sh` 里核对 |
| 以引擎 workflow 为基底、参考 `1018ji` 改 | 自建 `build.yml`；磁盘清理、`dwarves`、kmod 单独打包、release 汇总等取自引擎与 `1018ji` 的做法 |
| 移植 pon 补丁/dts/驱动 + 注入 eBPF/BTF + 保留 fttr 编译选项 | 分别对应：源码树本身、`ebpf_btf` recipe、`fttr` 片段（见第 6 节的现实约束） |
| 锁定三个仓库固定 commit hash | `pins.env` + `compilecfg` 的 `COMMIT_HASH`。**上游 ini 从来不填 `COMMIT_HASH`**，等于每次跟分支头走；这是本仓库补上的第 1 个真实缺口 |
| 输出 sysupgrade.bin / factory.bin / config.seed / 完整日志 | sysupgrade 有；**factory.bin 该 profile 不产出**（第 6 节）；`.config`→`config.seed`、`config.buildinfo`、`build.log`、`overlay.diff`、`SHA256SUMS.txt` 都进产物 |
| 签名密钥用本机私钥、存 Secrets、禁止硬编码 | `load_signing_key.sh`，文件名按 `pbs05/ponwrt` 的 `rules.mk:353-355`（`private-key.pem`/`public-key.pem`/`key-build`）；缺密钥直接失败并打印生成命令 |

**没有照搬**引擎上游 workflow 的一处：它对 `lk_h3c_hm2004_du` 用 GitHub App 令牌去拉私有仓库。
2026-11-06 官方把界面 `LazuliKao/luci-app-fttr` 开源了（Apache-2.0），但后端
`LazuliKao/openwrt-fttr` 依旧私有——用仓库所有者自己的令牌查 API 也是 404，qwe-qaq 那边同样私有。
上游那个 recipe（`wrt_core/recipes/h3c-hm2004-du_fttr/recipe.json`）本身是 `enabled:false`，
它 import 的四个包里三个仍在私有仓库。这条线现在由 `with_official_fttr` + `scripts/check_official_fttr.sh` 随时可复查（见第 6 节），不再靠转述。

### 五、风险规避

| 文档要求 | 落地 |
| --- | --- |
| PON 优先级最高，重点校验驱动加载、BOSA、mtd、分区保护 | `assert_artifacts.sh` 先查 PON 五项包，再查 BTF，最后查附加功能——顺序就是优先级 |
| PON 异常时优先回退硬件补丁，不保留 eBPF/honk | 结构上支持：ponwrt 树按 SHA 回退，`ebpf_btf`/`honk` 是独立片段，去掉名字即可 |
| 不替换 fttr 相关包 | **半做到**：官方界面 `luci-app-fttr` 已开源（2026-11-06，Apache-2.0），但它 import 的三个本体包仍在私有的 `openwrt-fttr` 里，所以只能用公开源与别的包名顶上；见第 6 节 |
| eBPF 必须开 `DEBUG_INFO_BTF` | 见第 2 节，REDUCED 是关键，已显式关闭并双向校验 |
| 不整体替换主干内核/rootfs | 内核版本、rootfs 类型全由源码树+引擎决定，overlay 没碰 |
| 禁止混用多套 sysupgrade 脚本 | 只用源码树自带的 `target/linux/airoha/an7581/base-files/lib/upgrade/platform.sh`（含 `airoha_require_ubi_layout` 的 UBI 卷校验）；overlay 里没有第二份升级脚本 |

### 六、编译输出命名

文档示例：`HM2004-DU-wrtRelease-FTTR-eBPF-HONK-稳定版_${DATE}`

* Release 标题用文档原串（含中文）。
* artifact 名与 tag 用 ASCII：`HM2004-DU-wrtRelease-FTTR-eBPF-HONK-stable-${DATE}` /
  `hm2004-du-${DATE}`。中文进 tag 会让后续 `gh release download`、缓存 key、外部下载工具都多一层坑。
* `${DATE}` = `TZ=Asia/Shanghai date +%Y%m%d`。

### 七、优先级排序

门禁按文档优先级排列，且**每条都指定了失败时要说的话**：
PON 包缺失 → 立刻红；BTF 没进内核 → 红并说明 pahole/REDUCED 两种可能；
honk 包不在 manifest → 红；FTTR 运行时缺口 → 红（在产物已归档之后，所以不会白等）；
`with_official_fttr` → 在任何耗时工作之前先探上游仓库与包，几分钟内把「缺哪个仓库、缺哪个 Makefile」列出来。

---

## 3. 关于「只移植 PON 硬件层」这条路线的说明

文档假设可以「主干用 `wrt_release` 的基础系统 + 从 ponwrt 搬 PON 硬件文件」。核对上游后，
这条路线不成立，改成了「源码树=ponwrt@SHA，编排层=引擎@SHA，差异集中在 overlay」：

1. `wrt_release` **不是** OpenWrt 分支，而是一个编译编排仓库（`build.sh` + `compilecfg/*.ini` +
   `deconfig/*.config` + `recipes/` + `modules/`），它自己**没有**任何 target 源码；
   它给 HM2004-DU 的原配 `ini` 写的 `REPO_URL` 就是 `LazuliKao/ponwrt`（fork）。
2. PON 的代码分布跨三层：target 里（DTS、board.d、platform.sh、170 个 `patches-6.18`）、
   两个**外部 feed**（`openwrt-pon-drivers` 装 `kmod-airoha-xpon`/`kmod-airoha-pon-frontend`/BOSA
   页读写驱动与光模块固件，`openwrt-pon-userspace` 装 `airoha-ponctl`/`airoha-pond`/`luci-app-pon`）。
   `package/` 目录里**没有**任何 pon 包（全树搜索确认为 0）。
3. 内核耦合是硬的：`airoha-xpon` 的 Makefile 写明它用 `airoha_eth` 的 PON data-path API，
   该 API 来自 `patches-6.18/922/925/927/608`，全部按 6.18.55 上下文做。
   换句话说，「搬驱动」必然连带搬整套 target 补丁，也就等于换内核。
4. 镜像定义耦合 UBI/FIT：`UBOOTENV_IN_UBI`、`KERNEL_IN_UBI`、`fitblk`、
   `external-static-with-rootfs`、`pad-to 128k`、`REQUIRE_IMAGE_METADATA=1` 与
   `platform.sh` 的 `airoha_require_ubi_layout` 必须配套，缺一个就是变砖而不是编译失败。

文档「主线不动」的**意图**（别被第三方改动带跑、改动可审）在新路线下是成立的：
引擎与源码树都按 SHA 取、一行没改，我们写的东西全在 `overlay/`，
每次构建的 `overlay.diff` 就是完整的改动清单。

---

## 4. 已验证 vs 未验证

**已验证（读的是真实文件/接口，不是文档转述）**

* 三个上游仓库存在，各自的 SHA、分支、fork 关系、`LazuliKao/wrt_release` 默认分支名是 `💥`。
* `feat/hm2004-npu` = `pbs05/ponwrt@master` 领先 5、落后 0，多出的 5 个提交是 FTTR/PPE 内核补丁。
* HM2004-DU 的 profile 名是 `h3c_hm2004-du`（带连字符），DTS/mtd 分区（`bl2` + `ubi`，UBI 卷
  `fip/ubootenv/ubootenv2/factory/fit`）、`03_pon_data` 的 factory 卷读取偏移。
* BTF 的真实卡点是 `DEBUG_INFO_REDUCED`（`Config-kernel.in:566/594` 的 depends 与 default 白名单）。
* `CONFIG_BPF_CORE` 在 Linux Kconfig 中不存在。
* `LazuliKao/openwrt-fttr` HTTP 404——2026-11-07 用仓库所有者（likz0421）自己的令牌再查一次仍是 404，
  即对本仓库所有人也不可见；`qwe-qaq/openwrt-fttr`、`qwe-qaq/luci-app-fttr` 同样私有。
* `LazuliKao/luci-app-fttr` 2026-11-06 起公开（Apache-2.0，main HEAD `9ae3e942`）。仓库里
  `package/luci-app-fttr/` 只有 `po/` 与 `root/`（menu.d、acl.d），**没有 Makefile、没有 htdocs**，
  而它 README 写「生成的 LuCI JS 已提交，打 OpenWrt 包不需要 Node」——AGENTS.md 自己写明 htdocs 是
  被 gitignore 的本地产物。这是文档与仓库现状不符，不是我的推测：两项都用 API 树列过。
  运行时契约在 `root/usr/share/rpcd/acl.d/luci-app-fttr.json`：名为 `fttr` 的 ubus 对象、24 个方法，
  加 UCI 的 `fttr` 段——都由私有后端里的 `fttrd` 提供。
* FTTR 公开 feed 的四个包名、`KCONFIG` 指向不存在的内核符号、驱动要的 10 个 GPIO con_id
  （`fmcs_load.c:300-315` 的 clk/data/nconfig/rst/status/conf-done，加 `fmcs_spi.c:321-324`
  位敲 SPI 的 sck/mosi/miso/cs）与 ponwrt DTS 的三条 `fpga-*-gpios` 不一致；pbs05 与 1018ji
  两份 DTS 在这一段逐字节相同（各 12224 字节），所以不是某个 fork 的漂移。
* honk feed 的包名、架构、内核版本要求、`DEPENDS` 里的四个 kmod。
* 引擎的 recipe 校验程序与阶段列表（`tests/check_recipes.sh` 直接从 `recipe.sh` 抽取后运行）。
* 本仓库的门禁脚本：`tests/dryrun.sh` 78 项正反分支全过（假目录树 + `dtc`/`readelf`/`curl` PATH 桩）。

**未验证（要说清楚，别当成已经成了）**

* 真机行为：PON 注册、BOSA 读数、LED 触发器、sysupgrade 保配置——需要刷机。
* `assert_artifacts.sh` 里「vmlinux 有 `.BTF` 段」在首次真实构建前只是**逻辑正确**，桩测过两分支。
* 镜像体积 vs UBI `fit` 卷剩余容量：BTF 会明显加大内核，构建期不做容量断言（卷容量无法从 DTS 可靠推出），
  **刷之前先看 `sysupgrade.itb` 的实际字节数**。
* FTTR 的 FPGA 寄存器传输：公开 feed 作者自己写明「未在 HM2004-DU 上确认物理 GPIO 走线，使用前必须实测」。
* 上游没有任何官方 HM2004-DU 镜像可对照（`pbs05/ponwrt`、rayniel 两个库的 releases 都是空的）。

---

## 5. 跑之前需要配的 Secrets

工作流里没有任何密钥。`APK_SIGNING_PRIVATE_KEY` 缺了直接失败；两个 usign Secret 缺了会**降级放行并打印后果**
（`config/Config-build.in:86` 的 `SIGN_FIRMWARE` 说明写明 OpenWrt 会用临时钥匙签固件），因为真正影响
设备长期使用的是 apk 仓库那把钥匙。

| Secret | 必需 | 用途 | 怎么生成 |
| --- | --- | --- | --- |
| `APK_SIGNING_PRIVATE_KEY` | 是 | apk 软件仓库签名（`private-key.pem`，公钥自动导出并校验自洽） | `openssl ecparam -name prime256v1 -genkey -noout -out private-key.pem`，把文件全文贴进 Secret |
| `APK_SIGNING_PUBLIC_KEY` | 否 | 配了会额外校验公私钥是否同一把 | `openssl ec -in private-key.pem -pubout` |
| `USIGN_PRIVATE` / `USIGN_PUBLIC` | 否 | sysupgrade 元数据签名（`key-build`/`key-build.pub`），base64 单行 | `usign -G -q -p key-build -d key-build.sec` 后 `base64 -w0` |
| `FTTR_TOKEN` | 否 | 只在 `with_official_fttr` 时用：探测/拉取私有的 `LazuliKao/openwrt-fttr`。`check_official_fttr.sh` 只从环境变量读，写进 0600 的临时 netrc、退出即删，不进命令行也不打印 | 一个contents只读的 fine-grained token |

为什么 apk 钥匙必须固定而不是每次现生成：设备端要挂自己的软件源，密钥每构建一变，升级就验签失败，
换固件还得再灌一次信任——和「稳定版」正相反。

---

## 6. 已知缺口（读这一段再决定要不要开 FTTR）

1. **FTTR 只能用公开源，而且是半套。** 文档假定的 `LazuliKao/openwrt-fttr` 是私有仓库（HTTP 404）。
   替代源 `rayniel/openwrt-hm2004-feed`（GPL-2.0 C 重写的 `kmod-fttr-fmcs` + `fttr-tools`(miniolt)
   + `hm2004-fttr-firmware`(FTTR_TOP.sbit，2,087,000 字节) + `luci-app-h3c-fttr`）能编能装，但：
   * 原包的 `KCONFIG:=CONFIG_FTTR_FMCS=m` 指向一个从未 source 进内核 Kconfig 树的符号，
     `.ko` 根本不会生成——`overlay/recipes/h3c-hm2004-du_fttr/apply.sh` 把它改成 out-of-tree
     的 `obj-m`，并补 `-DCONFIG_FTTR_FMCS_LOAD_AT_PROBE=1`（`fmcs.c:752` 的 `#ifdef` 需要它）。
   * **驱动源码本身要适配 6.18**（两处失败都由真实构建日志给出，不是推测）：
     - 构建 42098806007：`fmcs.c:636` 用了已被 v6.x 删除的 `no_llseek`；`fmcs.c:918` 给
       `genl_family.name` 赋值而它在 `include/net/genetlink.h:80` 是 `char[GENL_NAMSIZ]` 数组。
     - 修完上面两处、`fmcs.o` 过了之后，构建 42126367809 在 `fmcs_spi.o` 又报
       `fmcs.h:112 field 'cdev' has incomplete type`——头文件用了 `struct cdev`、`atomic_t`、
       `wait_queue_head_t` 却没 include 对应头；`fmcs.c` 恰好自己先包含了 `cdev.h` 才显得没事，
       换一个编译单元就崩。这是头文件自含性问题，不是某个 .c 的问题。

     由 `patches/fmcs-kernel6.18-adapt.patch` 一次修掉（5 个文件、9 个 hunk）：本地实现语义相同的
     `fmcs_no_llseek()`（返回 `-ESPIPE`，与内核原函数一致）、`name` 改 `strscpy(...)`、
     头文件补 `linux/cdev.h` / `linux/atomic.h` / `linux/wait.h`。
     - 同一场构建的收尾还报了一条：`ERROR: info field 'version' has invalid value:
       package version is invalid`。原因是上游直接拿驱动版本串原值
       `fmcs.h:23 #define FMCS_DRV_VERSION "V2024-0418-0001"` 当 `PKG_VERSION`，
       而 apk-tools 的版本格式不接受字母开头的组件。补丁追加一行 make 侧规范化
       `PKG_VERSION:=$(subst -,.,$(patsubst V%,%,$(PKG_VERSION)))` → `2024.0418.0001`，
       不动驱动里的版本串本身。（其余两个包 `1.0.0` / `1` 本来就合法，已逐个查过。）

     - 构建 42242418204：`.ko` 出来后换 `fttr-tools` 报
       `No rule to make target '../driver/fmcs_uapi.h', needed by 'miniolt'`。
       这是 feed 自己的打包不一致：包定义把 `userspace/*` 与 `driver/fmcs_uapi.h`
       **平铺**拷进同一个 `PKG_BUILD_DIR`，而 `userspace/Makefile` 仍按 feed 的嵌套布局
       写依赖与 `-I../driver`。`miniolt.c` 里 include 的是同目录的 `"fmcs_uapi.h"`，
       所以依赖行与 `-I` 各改一处即可。
     - 构建 42259744326：`miniolt.c:235 'ETH_P_ALL' undeclared`、`:290 'ETH_ALEN'
       undeclared`。glibc 会经 `<netpacket/packet.h>` 间接带进这些常量，musl 不会，
       补 `#include <linux/if_ether.h>`。全文扫过其余符号（if_nametoindex / htons /
       struct ifreq 都有对应头，没有 strlcpy、bcopy 之类 glibc 专有函数），
       所以这是该文件最后一个此类问题。
     补丁用 `patch --fuzz=0` 打，feed 源码一漂移就当场失败，绝不容忍"凑合打上"；
     `apply.sh` 打完还要过六条自检，`assert_prebuild.sh` 在构建前核对同样的点。
     第一条教训：第一版自检用 `grep '../driver'` 宽判，结果命中了
     **补丁注释里写的 `../driver`**，把自己误判成失败——判据必须盯 make 真正使用的
     那一行（`^miniolt: miniolt.c fmcs_uapi.h`），而不是任一处字符串。这条是本机
     测试直接拒掉的，不是等到 CI 上才发现。

     第二条教训（反面，记下来免得重犯）：为了缩短反馈环，我加过一步"只预编译 fttr
     用户态包"（`make package/feeds/hm2004/fttr-tools/compile`），想在 30 分钟内暴露
     编译错误。结果它自己造假报警——脱离 `world` 流程单独调用时，make 会去
     `host-compile` `package/utils/lua`，而那个 host 包单独编不了（0.09 秒失败，
     编译器根本没起来），于是真正要测的 miniolt 一行都没编到，还把整轮判红。
     **会误报的加速比没有加速更糟**，该步已删除，判定交回正常构建流程。
   * **编译与打包这一层已经全过了，过不去的是运行时。** 驱动按 con_id 取线，一共 10 条：
     `original/driver/fmcs_load.c:300-315` 要 nconfig / rst / clk / data / status / conf-done，
     `original/driver/fmcs_spi.c:321-324` 还要位敲 SPI 的 sck / mosi / miso / cs
     （位流是拿 GPIO 一根根敲进 FPGA 的）。而 ponwrt 的
     `target/linux/airoha/dts/an7581-h3c-hm2004-du.dts:125-127` 只给了三条，名字还带 `fpga-` 前缀：

     | 驱动要的 con_id | 这份 DTS 给的 | 结果 |
     | --- | --- | --- |
     | clk(29) / data(30) | `fpga-clk-gpios` / `fpga-data-gpios` | 编号对得上、名字对不上，取不到 |
     | nconfig / rst / status / conf-done | 没有 | 取不到 |
     | sck / mosi / miso / cs | 只有 `fpga-spi-int-gpios`(23)，驱动不问这个 | 取不到 |

     后果不是"功能弱一点"：`devm_gpiod_get_optional` 取不到给 NULL 不报错，但
     `fmcs_spi.c:335` 见 sck 为空直接返回 -ENODEV，而它是 `fmcs.c:729 fmcs_probe_common()`
     的第一步——驱动绑不上设备，`/dev/fmcs` 都不会出现。
     就算这 10 条补齐也只是走到第二步：寄存器通路（`miniolt read/write fpga`，M-OLT 控制的入口）
     走 0x1fa10000 上的 chip select 1，那个控制器在这棵树里归 `spi-airoha-snfi`，而原厂用的是它
     从没实现过的 Manual Mode——feed 的 `docs/REVERSE_ENGINEERING.md` §3.1-3.6 和整篇
     `docs/NEXT_STEPS.md` 讲的就是这件事。所以这是**驱动 + 硬件**的活，不是构建配置的活。
   * feed 里其实带了那份设备树补丁 `original/patches/0001-arm64-dts-airoha-hm2004-du-enable-fmcs.patch`，
     六个配置脚的编号都给了（nconfig 5 / rst 22 / clk 29 / data 30 / status 27 / conf-done 28，
     从原厂 DTB 里 `fpga_load.ko` 硬编码的 GPIO 位推出来）。这里**没有**打上去，理由是作者自己写的
     （feed `README.md:55-59`）：「the GPIO transport pins are not identified in the stock device tree.
     Do not enable the FMCS node or apply … until the transport wiring is resolved」——推算不等于实测，
     打上去还缺位敲那四条，而且打了也没有寄存器通路。要试就在自己板子上打，先核对这几只脚与
     `pon_tx_disable`、leds、keys 的复用冲突。
     `check_fttr_dts.sh` 因此在产物归档之后才拦，绝不自动改设备树：改就是替上游把「未实测」变成「已发布」。

     这道闸自己也在构建 42286251323 报过一次假案，值得记：它按 `arch/arm64/boot/dts/airoha/*.dtb`
     找 DTB，什么都没找到，于是把「门禁跑不了」报成了「门禁拦住」。真实落点是
     `$(KDIR)/image-<dts>.dtb`，即 `build_dir/target-*/linux-airoha_an7581/image-an7581-h3c-hm2004-du.dtb`
     ——依据是 `include/image.mk:40`（KDIR=KERNEL_BUILD_DIR）、`:691`（`$(KDIR)/image-$(1).dtb`）和
     `target/linux/airoha/image/an7581.mk:317/329`（DEVICE_DTS 与 `fit gzip` 用的就是它）。
     本地夹具当初按我猜的路径造文件，所以 68 条用例全绿却拦不住这个错——**夹具要照上游的构造规则造，
     不能照我对布局的印象造**。现在主路径 + 兜底路径 + 「两条都没有就逐条列出找过哪里」都有用例。
   * `moltd` / Rust 版控制器（ACS、MQTT、HL202 等分支）公开无处可取，只有 miniolt 一个命令行。
   * 位流是原厂提取的二进制，feed 与作者研究库都写明「未确认可以再分发」。往公开 Release
     里发镜像前，这一条得你自己判断。
   * **文档原指的官方那一套（`with_official_fttr`）复查结论。** 2026-11-06 官方开源了界面
     `LazuliKao/luci-app-fttr`，但引擎 recipe import 的三个本体包（`h3c-fmcs`、
     `h3c-fmcs-firmware`、`h3c-fttr-tools`）仍在私有的 `LazuliKao/openwrt-fttr` 里，
     对本仓库所有者也不可见。所以官方那条路今天仍走不通，而且不通的原因很具体：
     界面的 24 个 ubus 方法（`fttr` 对象）和 UCI `fttr` 段都由后端 `fttrd` 提供，
     只装界面会得到一个能打开、每次调用都报错的菜单——这种「绿但功能不在」正是门禁要拦的。
     哪天有令牌或后端开源了，`bash scripts/check_official_fttr.sh`（CI 里是
     `with_official_fttr=true`，几分钟内出结论，不占两小时）会把还缺什么逐条列出来；
     它探到全齐也只是放行到「能编能装」，运行时仍按上面 GPIO/寄存器通路那两条核。
2. **`factory.bin` 不存在，能拿到的是 `recovery.itb`。** 该 profile 的镜像定义只有
   `IMAGES := sysupgrade.itb`，救砖走 `KERNEL_INITRAMFS_SUFFIX := -recovery.itb` + U-Boot/UBI
   那条路，不是 TFTP 全镜像——文档这条要求在上游没有对应物。
   要产出它必须打开 `CONFIG_TARGET_ROOTFS_INITRAMFS=y`，而这件事踩了一个隐蔽的坑：
   上游 ini 的 `ADD_RECIPES` 里有 `disable_initramfs`，它在 `pre_defconfig` 阶段往 `.config`
   **追加** `CONFIG_TARGET_ROOTFS_INITRAMFS=n`，写得比设备配置和片段都晚，于是 `=y` 被无声顶掉、
   `recovery.itb` 不产出（实测构建 42116233200 就是这样，两小时后才由产物核验发现）。
   现在 ini 把它移到 `DISABLE_RECIPES`（引擎里 DISABLE 的优先级高于 ADD 与 recipe 集合），
   并且 `assert_prebuild.sh` 直接核对最终值，20 分钟内就会报错，而不是等两小时。
   代价：多编一个 initramfs 镜像、多几分钟到十几分钟；`sysupgrade.itb` 内容不受影响。
3. **`with_fttr=true` 会红，但红的位置很后、很有用。** 编译期障碍已经全部清掉了——构建
   42286251323 里 `kmod-fttr-fmcs-6.18.55.2024.0418.0001-r1.apk` 打出包了，四个 fttr 包
   （kmod / fttr-tools / hm2004-fttr-firmware / luci-app-h3c-fttr）都进了 rootfs manifest，
   rootfs 内容门禁也过了；唯一红的步骤是上面那条运行时门禁。这是刻意的：文档要求「fttr 插件可用」，
   而现在只能做到「装得上、跑不起」，红比「绿但功能不在」诚实。
   因为上传排在门禁之前，红的那一轮产物照样归档，不用重跑两小时。
   想要能刷的固件就 `with_fttr=false`，PON + honk + Vantage 主题照旧，那条线已经全绿发过 Release。

---

## 7. 本地自检

```bash
bash tests/dryrun.sh                                   # 门禁脚本的正反分支
ENGINE_DIR=<引擎目录> bash tests/check_recipes.sh       # 用引擎自己的校验器验 recipe
```

`check_recipes.sh` 的判据是从 `wrt_core/recipe.sh` 里**原样抽出**的 jq 程序与 `RECIPE_PHASES` 数组，
不是另写一套。它会额外拦住两类静默失效：phase 拼错（引擎只校验「非空字符串」，不在阶段表里的
phase 永远不执行且不报错）、`when.targets` 与目标名不符（被计划器过滤掉，同样静默）。

## 8. 界面主图：Vantage

`anothaDev/luci-theme-vantage`（GPL-3.0，546★，自述面向 OpenWrt 25.12）按 SHA 锁进工程，
作为固件的默认主题。接入方式完全走引擎已有的 recipe 机制，不魔改：

| 项 | 值 | 依据 |
| --- | --- | --- |
| feed | `src-git vantage https://github.com/anothaDev/luci-theme-vantage.git^e35a8e7f…` | `pins.env` 的 `VANTAGE_SHA` |
| 装机包 | `luci-theme-vantage`、`luci-i18n-vantage-theme-zh-cn` | 主题 Makefile 的 `PKG_NAME`、`LUCI_BASENAME:=vantage-theme`；`po/zh_Hans` 经 `feeds/luci/luci.mk:92` 的 `LUCI_LC_ALIAS.zh_Hans=zh-cn` 映射成 `zh-cn` |
| 默认怎么生效 | 主题自带 `root/etc/uci-defaults/30_luci-theme-vantage`：注册 `luci.themes.Vantage=/luci-static/vantage`，且仅在**新装**时把 `luci.main.mediaurlbase` 指过去（升级不动管理员已选主题） | 直接读了那份脚本，不是靠 README 转述 |

**必须同时关掉 `default_theme_fluent`**，这不是审美取舍而是执行顺序问题：引擎那份脚本叫
`990_set_fluent_default`，uci-defaults 按文件名排序执行，`990` 必然盖掉 `30` —— 不关的话
主题包装了、也注册了，但设备上界面还是 Fluent。Fluent 的**主题包**（`luci_theme_fluent`）保留，
LuCI 里可以切回去；只把"默认"这一票投给 Vantage。

`luci-app-vantage`（同仓库的 live dashboard 应用）**没有**装：它是应用不是主题，你没要求。
要加就在 `overlay/recipes/luci_theme_vantage/configs/vantage.config` 加一行
`CONFIG_PACKAGE_luci-app-vantage=y`，feed 已锁好，不用再动别处。

门禁核对四条：feed 锁版本、主题包选中、中文包选中、`990_set_fluent_default` **不在**源码树里
（在就说明默认会被顶回去）。`scripts/assert_prebuild.sh` 的 8、`tests/dryrun.sh` 场景 2 的
四条反例。

## 9. 改版本

只改 `pins.env` 和 `pins.feeds`。每个 pin 的作用：

* `pins.feeds` —— 源码树自带 7 个 feed 的锁版本点，`feed_pins` recipe 在 `pre_feeds` 阶段改写、
  `assert_prebuild.sh` 逐条核对。

* `pins.feeds` —— 源码树自带 7 个 feed 的锁版本点；`feed_pins` recipe 在 pre_feeds 阶段改写，`assert_prebuild.sh` 逐条核对。
* `ENGINE_SHA` —— 编排引擎。换它等于换整套构建行为，先看 `overlay.diff` 有没有变。
* `PONWRT_SHA` —— 固件源码树，PON 硬件与 DTS 都在这。写进 ini 的 `COMMIT_HASH`，
  构建前后各校验一次 HEAD。
* `MERGE_REPO`/`MERGE_SHA` —— 仅作对照参考，工作流会验证该 commit 存在，不参与构建。
* `HONK_SHA` / `FTTR_SHA` / `VANTAGE_SHA` —— 附加 feed 的锁版本，feed 名固定为 `honk` / `hm2004`
  （后者是包 Makefile 里硬编码的路径 `$(TOPDIR)/feeds/hm2004/original`，改名即失效）。
* `OFFICIAL_FTTR_BACKEND_REPO` / `OFFICIAL_FTTR_APP_REPO` / `OFFICIAL_FTTR_APP_SHA` ——
  文档原指的官方那一套。后端仓库至今私有，所以这三个值只被 `check_official_fttr.sh` 用来复查；
  `APP_SHA` 与上游 main 不一致时脚本会当场说出来（它是公开仓库，能直接比）。
