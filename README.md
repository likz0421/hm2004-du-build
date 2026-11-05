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
  recipes/feed_pins|ebpf_btf|honk|hm2004_fttr_feed|h3c-hm2004-du_fttr
scripts/                     apply_overlay / preclone / load_signing_key
                             assert_prebuild / assert_artifacts / check_fttr_dts
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
                                     └─ 产物归档 → check_fttr_dts.sh → Release
```

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

**没有照搬**引擎上游 workflow 的一处：它对 `lk_h3c_hm2004_du` 用 GitHub App 令牌去拉两个**私有**仓库
（`LazuliKao/openwrt-fttr`、`LazuliKao/luci-app-fttr`）。我们没那个 App，也不该把私有依赖引进自己的工程。

### 五、风险规避

| 文档要求 | 落地 |
| --- | --- |
| PON 优先级最高，重点校验驱动加载、BOSA、mtd、分区保护 | `assert_artifacts.sh` 先查 PON 五项包，再查 BTF，最后查附加功能——顺序就是优先级 |
| PON 异常时优先回退硬件补丁，不保留 eBPF/honk | 结构上支持：ponwrt 树按 SHA 回退，`ebpf_btf`/`honk` 是独立片段，去掉名字即可 |
| 不替换 fttr 相关包 | **做不到**，见第 6 节：原三包在私有仓库，必须换公开源与包名 |
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
honk 包不在 manifest → 红；FTTR 运行时缺口 → 红（在产物已归档之后，所以不会白等）。

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
* `LazuliKao/openwrt-fttr` HTTP 404（私有）。
* honk feed 的包名、架构、内核版本要求、`DEPENDS` 里的四个 kmod。
* FTTR 公开 feed 的四个包名、`KCONFIG` 指向不存在的内核符号、驱动要的 GPIO con_id
  （`clk/data/nconfig/rst/status/conf-done`）与 ponwrt DTS 的 `fpga-*-gpios` 不一致。
* 引擎的 recipe 校验程序与阶段列表（`tests/check_recipes.sh` 直接从 `recipe.sh` 抽取后运行）。
* 本仓库的门禁脚本：`tests/dryrun.sh` 45 项正反分支全过（假目录树 + `dtc`/`readelf` PATH 桩）。

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
   * **驱动源码本身要适配 6.18**（这条是真实构建 42098806007 的日志打出来的，不是推测）：
     `fmcs.c:636` 用了已被 v6.x 删除的 `no_llseek`，`fmcs.c:918` 给 `genl_family.name`
     赋值而它在 `include/net/genetlink.h:80` 是 `char name[GENL_NAMSIZ]` 数组。
     两处由 `patches/fmcs-kernel6.18-adapt.patch` 修掉：本地实现一个语义相同的
     `fmcs_no_llseek()`（返回 `-ESPIPE`，与内核原来那个函数一字不差），
     `name` 改成 `strscpy(..., sizeof(family->name))`。补丁用 `patch --fuzz=0` 打，
     feed 源码一漂移就当场失败，绝不容忍"凑合打上"。
   * 驱动要 `clk-gpios`/`data-gpios`/…，ponwrt 的 DTS 给的是 `fpga-clk-gpios`/`fpga-data-gpios`，
     con_id 对不上 → probe 拿不到线。这是**硬件走线未确认**，不是编译问题，
     所以由 `check_fttr_dts.sh` 在产物归档后再拦，不自动改设备树（改就是猜引脚）。
   * `moltd` / Rust 版控制器（ACS、MQTT、HL202 等分支）公开无处可取，只有 miniolt 一个命令行。
   * 位流是原厂提取的二进制，feed 与作者研究库都写明「未确认可以再分发」。往公开 Release
     里发镜像前，这一条得你自己判断。
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
3. **默认 `with_fttr=true` 会让构建红。** 这是刻意的：文档要求「fttr 插件可用」，而现在它做不到，
   红比绿了但功能不在更诚实。想要能刷的固件就 `with_fttr=false`，PON + FTTR 之外的部分照旧。

---

## 7. 本地自检

```bash
bash tests/dryrun.sh                                   # 门禁脚本的正反分支
ENGINE_DIR=<引擎目录> bash tests/check_recipes.sh       # 用引擎自己的校验器验 recipe
```

`check_recipes.sh` 的判据是从 `wrt_core/recipe.sh` 里**原样抽出**的 jq 程序与 `RECIPE_PHASES` 数组，
不是另写一套。它会额外拦住两类静默失效：phase 拼错（引擎只校验「非空字符串」，不在阶段表里的
phase 永远不执行且不报错）、`when.targets` 与目标名不符（被计划器过滤掉，同样静默）。

## 8. 改版本

只改 `pins.env` 和 `pins.feeds`。每个 pin 的作用：

* `pins.feeds` —— 源码树自带 7 个 feed 的锁版本点，`feed_pins` recipe 在 `pre_feeds` 阶段改写、
  `assert_prebuild.sh` 逐条核对。

* `pins.feeds` —— 源码树自带 7 个 feed 的锁版本点；`feed_pins` recipe 在 pre_feeds 阶段改写，`assert_prebuild.sh` 逐条核对。
* `ENGINE_SHA` —— 编排引擎。换它等于换整套构建行为，先看 `overlay.diff` 有没有变。
* `PONWRT_SHA` —— 固件源码树，PON 硬件与 DTS 都在这。写进 ini 的 `COMMIT_HASH`，
  构建前后各校验一次 HEAD。
* `MERGE_REPO`/`MERGE_SHA` —— 仅作对照参考，工作流会验证该 commit 存在，不参与构建。
* `HONK_SHA` / `FTTR_SHA` —— 两个 feed 的锁版本，feed 名固定为 `honk` / `hm2004`
  （后者是包 Makefile 里硬编码的路径 `$(TOPDIR)/feeds/hm2004/original`，改名即失效）。
