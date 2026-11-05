#!/usr/bin/env bash
# 硬门禁（构建前）：证明「配置真的生效了」，而不是「我们写了这行」。
#
# 用法：./build.sh <目标> debug 之后执行。debug 模式会跑到 make defconfig 就停，
# 这时候 .config 已经是 make defconfig 处理过的最终形态——凡是会被 kconfig
# 静默丢掉的符号，在这一层就能查出来，几分钟就能失败，不用等两小时全量编译。
#
# 需求文档「五、风险规避」要求稳定优先，所以这里的判据全部按「必须为 y / 必须不为 y」
# 写死，不做「大概开了」的宽松判定。任何一项不达标就退出 1 并把原因打全。
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

PINS=${PINS:-$REPO_DIR/pins.env}
ENGINE_DIR=${ENGINE_DIR:-$REPO_DIR/engine}
BUILD_DIR=${BUILD_DIR:-$ENGINE_DIR/action_build}
WITH_FTTR=${WITH_FTTR:-1}

# shellcheck disable=SC1090
. "$PINS"

CFG="$BUILD_DIR/.config"
KCFG="$BUILD_DIR/target/linux/airoha/an7581/config-6.18"
FEEDS="$BUILD_DIR/feeds.conf"
[ -f "$FEEDS" ] || FEEDS="$BUILD_DIR/feeds.conf.default"

fail=0
missing=()

need_cfg_y() {
    # $1=文件 $2=符号名（不含 CONFIG_ 前缀）
    if ! grep -q "^CONFIG_$2=y$" "$1" 2>/dev/null; then
        missing+=("$2=y  [不在 $(basename "$1") 里；实际行：$(grep "^CONFIG_$2" "$1" 2>/dev/null | head -1 || echo 无)]")
        fail=1
    fi
}

need_cfg_absent_y() {
    if grep -q "^CONFIG_$2=y$" "$1" 2>/dev/null; then
        missing+=("$2 必须关掉，但它是 =y（BTF 会被它挡掉）")
        fail=1
    fi
}

need_file_has() {
    if ! grep -qF "$2" "$1" 2>/dev/null; then
        missing+=("文件 $(basename "$1") 里找不到字符串：$2")
        fail=1
    fi
}

if [ ! -f "$CFG" ]; then
    echo "找不到 $CFG —— debug 模式没跑起来？" >&2
    exit 1
fi

echo "=============== 构建设置核验 ==============="

# --- 1. 源码就是我们 pin 的那个 commit ---
head_sha=$(git -C "$BUILD_DIR" rev-parse HEAD 2>/dev/null || echo 取不到)
if [ "$head_sha" != "$PONWRT_SHA" ]; then
    echo "× 源码树 HEAD 与 pins.env 不一致" >&2
    echo "  期望 $PONWRT_SHA" >&2
    echo "  实际 $head_sha" >&2
    echo "  引擎 reset_feeds_conf 的链路：reset --hard origin/$PONWRT_BRANCH → pull → clean → checkout COMMIT_HASH" >&2
    fail=1
else
    echo "√ 源码树 HEAD = pin 的 commit"
fi

# --- 2. 目标设备 profile ---
need_cfg_y "$CFG" "TARGET_airoha"
need_cfg_y "$CFG" "TARGET_airoha_an7581"
need_cfg_y "$CFG" "TARGET_DEVICE_airoha_an7581_DEVICE_h3c_hm2004-du"

# --- 3. BTF 三件套（需求文档「二、内核必选配置」的真正卡点）---
need_cfg_y "$CFG" "KERNEL_DEBUG_INFO"
need_cfg_absent_y "$CFG" "KERNEL_DEBUG_INFO_REDUCED"
need_cfg_y "$CFG" "KERNEL_DEBUG_INFO_BTF"
need_cfg_y "$CFG" "KERNEL_DEBUG_INFO_BTF_MODULES"
need_cfg_y "$CFG" "KERNEL_MODULE_ALLOW_BTF_MISMATCH"

# --- 4. honk 需要的观测面与 TC 支撑 ---
need_cfg_y "$CFG" "KERNEL_CGROUP_BPF"
need_cfg_y "$CFG" "KERNEL_BPF_EVENTS"
need_cfg_y "$CFG" "KERNEL_KPROBES"
need_cfg_y "$CFG" "KERNEL_PERF_EVENTS"
need_cfg_y "$CFG" "KERNEL_BPF_STREAM_PARSER"

# --- 5. 没有 KERNEL_* 对应项、只能进子 target 内核配置的那批 ---
for sym in CONFIG_BPF=y CONFIG_BPF_SYSCALL=y CONFIG_BPF_JIT=y \
    CONFIG_NET_SOCKMAP=y CONFIG_NET_CLS_BPF=m CONFIG_NET_ACT_BPF=m; do
    need_file_has "$KCFG" "$sym"
done
# 引擎 recipe 追加时会写一行标记，靠它确认追加真的发生了（而不是我们以为发生了）。
need_file_has "$KCFG" "# recipe: ebpf_btf (files/airoha_an7581_ebpf.config) [append]"

# --- 6. feed 是否按 pin 落进 feeds.conf ---
need_file_has "$FEEDS" "$HONK_FEED_URL.git^$HONK_SHA"
if [ "$WITH_FTTR" = "1" ]; then
    need_file_has "$FEEDS" "$FTTR_FEED_URL.git^$FTTR_SHA"
fi

# --- 6b. 上游自带的那 7 个 feed 也必须锁版本（需求文档「四、3」）---
PINS_FEEDS=${PINS_FEEDS:-$REPO_DIR/pins.feeds}
if [ ! -f "$PINS_FEEDS" ]; then
    missing+=("锁版本清单不存在：$PINS_FEEDS")
    fail=1
else
    while read -r fname furl fsha; do
        case "$fname" in '' | '#'*) continue ;; esac
        if ! grep -qE "^src-git[[:space:]]+${fname}[[:space:]]+${furl}\^${fsha}\$" "$FEEDS"; then
            missing+=("feed $fname 没有锁到 $fsha（现值：$(grep -E "src-git[[:space:]]+$fname" "$FEEDS" | head -1 || echo 无此行)）")
            fail=1
        fi
    done <"$PINS_FEEDS"
fi

# --- 7. PON 与 honk 的运行期包 ---
for p in PACKAGE_kmod-airoha-xpon PACKAGE_kmod-airoha-pon-frontend \
    PACKAGE_airoha-pond PACKAGE_airoha-ponctl PACKAGE_luci-app-pon \
    PACKAGE_honk PACKAGE_luci-app-honk \
    PACKAGE_kmod-sched-core PACKAGE_kmod-sched-bpf PACKAGE_kmod-veth PACKAGE_kmod-nft-queue; do
    need_cfg_y "$CFG" "$p"
done
if [ "$WITH_FTTR" = "1" ]; then
    for p in PACKAGE_kmod-fttr-fmcs PACKAGE_fttr-tools PACKAGE_hm2004-fttr-firmware \
        PACKAGE_luci-app-h3c-fttr; do
        need_cfg_y "$CFG" "$p"
    done
fi

# --- 8. apk 打包与签名（产物要能被设备上的 apk 信任，密钥必须来自 Secrets）---
need_cfg_y "$CFG" "USE_APK"
if grep -q "^CONFIG_SIGNED_PACKAGES=y$" "$CFG"; then
    if [ ! -s "$BUILD_DIR/private-key.pem" ]; then
        echo "× CONFIG_SIGNED_PACKAGES=y 但 $BUILD_DIR/private-key.pem 不存在" >&2
        echo "  后果：每次构建临时生成新密钥，设备端自托管软件源一升级就验签失败。" >&2
        echo "  处理：在仓库 Secrets 里配 APK_SIGNING_PRIVATE_KEY（见 README 的生成命令）。" >&2
        fail=1
    else
        echo "√ apk 签名私钥已就位（来自 Secrets，未硬编码）"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "=============== 构建设置核验未通过 ==============="
    for m in "${missing[@]}"; do
        echo "× $m"
    done
    echo
    echo "判据来自 scripts/assert_prebuild.sh；对照需求文档第二、四、五节。"
    exit 1
fi

echo "√ 全部构建设置判据通过"
