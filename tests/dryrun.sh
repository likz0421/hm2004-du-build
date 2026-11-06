#!/usr/bin/env bash
# 断言脚本自己的测试。
#
# 为什么要有这个文件：门禁代码如果判错了，比没有门禁更糟——它会给你一个
# 「检查过了」的绿勾。这里用假目录树 + PATH 上的桩（dtc / readelf）把每个
# 检查的正反两分支都跑一遍：该过的要过，该炸的要炸出对应的那句话。
#
# 跑法：./tests/dryrun.sh
set -uo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
failed=0

say() { printf '%s\n' "$*"; }

run_expect() {
    # run_expect <pass|fail> <用例名> <失败时期望在输出里看到的片段> <命令...>
    local want=$1 name=$2 needle=$3
    shift 3
    local out rc
    out=$(mktemp)
    "$@" >"$out" 2>&1
    rc=$?
    if [ "$want" = "pass" ] && [ "$rc" -ne 0 ]; then
        say "× [$name] 期望通过，实际退出 $rc"
        sed 's/^/    /' "$out" | head -30
        failed=$((failed + 1))
    elif [ "$want" = "fail" ] && [ "$rc" -eq 0 ]; then
        say "× [$name] 期望失败，实际通过了 —— 这条门禁什么都没拦住"
        failed=$((failed + 1))
    elif [ "$want" = "fail" ] && [ -n "$needle" ] && ! grep -qF "$needle" "$out"; then
        say "× [$name] 是失败了，但没说出预期原因（要找：$needle）"
        sed 's/^/    /' "$out" | head -30
        failed=$((failed + 1))
    else
        say "√ [$name]"
        pass=$((pass + 1))
    fi
    rm -f "$out"
}

commit_here() {
    # $1=目录 $2=message [extra args]
    local dir=$1 msg=$2
    shift 2
    git -c user.name=test -c user.email=test@example.com -C "$dir" commit -q "$@" -m "$msg"
}

# ---------------------------------------------------------------- 假引擎
make_engine() {
    local dir=$1
    mkdir -p "$dir/wrt_core/compilecfg" "$dir/wrt_core/deconfig/fragments" \
        "$dir/wrt_core/recipes/h3c-hm2004-du_fttr/configs" \
        "$dir/wrt_core/recipes/airoha_an7581" "$dir/.github/workflows"
    printf 'REPO_URL=https://github.com/someone/else\nREPO_BRANCH=main\n' \
        >"$dir/wrt_core/compilecfg/lk_h3c_hm2004_du.ini"
    printf '# upstream device config\nCONFIG_TARGET_airoha=y\n' \
        >"$dir/wrt_core/deconfig/lk_h3c_hm2004_du.config"
    printf '{"name":"h3c-hm2004-du_fttr"}\n' \
        >"$dir/wrt_core/recipes/h3c-hm2004-du_fttr/recipe.json"
    printf 'stale\n' >"$dir/wrt_core/recipes/h3c-hm2004-du_fttr/configs/stale.config"
    git -C "$dir" init -q
    git -C "$dir" add -A
    commit_here "$dir" init
}

make_pins() {
    local pins=$1 engine_sha=$2 build_sha=$3
    cat >"$pins" <<EOF
ENGINE_REPO=https://github.com/LazuliKao/wrt_release
ENGINE_SHA=$engine_sha
PONWRT_REPO=https://github.com/LazuliKao/ponwrt
PONWRT_BRANCH=feat/hm2004-npu
PONWRT_SHA=$build_sha
HONK_FEED_URL=https://github.com/kenzok8/openwrt-honk
HONK_SHA=$FAKE_HONK_SHA
FTTR_FEED_URL=https://github.com/rayniel/openwrt-hm2004-feed
VANTAGE_FEED_URL=https://github.com/anothaDev/luci-theme-vantage
VANTAGE_SHA=$FAKE_VANTAGE_SHA
FTTR_SHA=$FAKE_FTTR_SHA
BUILD_TARGET=lk_h3c_hm2004_du
IMAGE_PROFILE=h3c_hm2004-du
DTS_COMPAT=h3c,hm2004-du
EOF
}

FAKE_HONK_SHA=1111111111111111111111111111111111111111
FAKE_FTTR_SHA=2222222222222222222222222222222222222222
FAKE_VANTAGE_SHA=6666666666666666666666666666666666666666

make_fake_pins_feeds() {
    # 3 条就够测逻辑；SHA 用假值，和 make_pins 里的 HONK/FTTR 假 SHA 同一套。
    cat >"$1" <<EOF
packages https://github.com/immortalwrt/packages.git 3333333333333333333333333333333333333333
luci https://github.com/immortalwrt/luci.git 4444444444444444444444444444444444444444
pon_drivers https://github.com/pbs05/openwrt-pon-drivers.git 5555555555555555555555555555555555555555
EOF
}

KERNEL_DIR_REL=build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581/linux-6.18.55

make_build_tree() {
    local dir=$1
    local kdir="$dir/$KERNEL_DIR_REL"
    mkdir -p "$kdir/net/sched" "$kdir/arch/arm64/boot/dts/airoha" \
        "$dir/target/linux/airoha/an7581" "$dir/staging_dir/host/bin" \
        "$dir/feeds/hm2004/original/driver" "$dir/bin/targets/airoha/an7581/packages"
    : >"$kdir/net/sched/cls_bpf.ko"
    : >"$kdir/net/sched/act_bpf.ko"

    cat >"$dir/target/linux/airoha/an7581/config-6.18" <<'EOF'
CONFIG_DEBUG_INFO=y
# recipe: ebpf_btf (files/airoha_an7581_ebpf.config) [append]
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_NET_SOCKMAP=y
CONFIG_NET_CLS_BPF=m
CONFIG_NET_ACT_BPF=m
EOF

    {
        printf 'src-git honk https://github.com/kenzok8/openwrt-honk.git^%s\n' "$FAKE_HONK_SHA"
        printf 'src-git hm2004 https://github.com/rayniel/openwrt-hm2004-feed.git^%s\n' "$FAKE_FTTR_SHA"
        printf 'src-git vantage https://github.com/anothaDev/luci-theme-vantage.git^%s\n' "$FAKE_VANTAGE_SHA"
        while read -r fname furl fsha; do
            case "$fname" in '' | '#'*) continue ;; esac
            printf 'src-git %s %s^%s\n' "$fname" "$furl" "$fsha"
        done <"${PINS_FEEDS_FILE:?测试未设置 PINS_FEEDS_FILE}"
    } >"$dir/feeds.conf"

    cat >"$dir/feeds/hm2004/original/driver/fmcs_load.c" <<'EOF'
	ret = fmcs_bitstream_get_gpio(dev, "nconfig", GPIOD_OUT_HIGH, &bs->nconfig);
	ret = fmcs_bitstream_get_gpio(dev, "clk", GPIOD_OUT_LOW, &bs->clk);
	ret = fmcs_bitstream_get_gpio(dev, "data", GPIOD_OUT_LOW, &bs->data);
EOF
    cat >"$dir/feeds/hm2004/original/driver/fmcs.c" <<'EOF'
static loff_t fmcs_no_llseek(struct file *file, loff_t offset, int whence)
{
	return -ESPIPE;
}
	.llseek		= fmcs_no_llseek,
	strscpy(family->name, fmcs_genl_names[i], sizeof(family->name));
EOF
    mkdir -p "$dir/feeds/hm2004/original/userspace"
    cat >"$dir/feeds/hm2004/original/userspace/Makefile" <<'EOF'
CPPFLAGS += -I.
miniolt: miniolt.c fmcs_uapi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ miniolt.c
EOF

    # apply.sh 处理后的形态（没有 KCONFIG 行、驱动是 obj-m）
    mkdir -p "$dir/package/feeds/hm2004/fttr-fmcs" "$dir/feeds/hm2004/package/fttr-fmcs"
    cat >"$dir/package/feeds/hm2004/fttr-fmcs/Makefile" <<'EOF'
define KernelPackage/fttr-fmcs
  FILES:=$(PKG_BUILD_DIR)/fttr-fmcs.ko
endef
EOF
    cat >"$dir/feeds/hm2004/package/fttr-fmcs/Makefile" <<'EOF'
FTTR_SOURCE_ROOT:=$(TOPDIR)/feeds/hm2004/original
PKG_VERSION:=$(shell sed -n 's/^#define FMCS_DRV_VERSION[[:space:]]*"\(.*\)"/\1/p' $(FTTR_SOURCE_ROOT)/driver/fmcs.h)
PKG_VERSION:=$(subst -,.,$(patsubst V%,%,$(PKG_VERSION)))
PKG_RELEASE:=1
EOF
    cat >"$dir/feeds/hm2004/original/driver/Makefile" <<'EOF'
obj-$(CONFIG_FTTR_FMCS)		+= fttr-fmcs.o
fttr-fmcs-y			:= fmcs.o fmcs_spi.o fmcs_load.o

# hm2004-du-build out-of-tree fix
obj-m := fttr-fmcs.o
ccflags-y += -DCONFIG_FTTR_FMCS_LOAD_AT_PROBE=1
EOF
    cat >"$dir/feeds/hm2004/original/driver/fmcs.h" <<'EOF'
#include <linux/atomic.h>
#include <linux/cdev.h>
#include <linux/device.h>
struct fmcs_dev {
	struct cdev cdev;
};
EOF

    cat >"$dir/.config" <<'EOF'
CONFIG_TARGET_airoha=y
CONFIG_TARGET_airoha_an7581=y
CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_h3c_hm2004-du=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_KERNEL_DEBUG_INFO=y
# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y
CONFIG_KERNEL_MODULE_ALLOW_BTF_MISMATCH=y
CONFIG_KERNEL_CGROUP_BPF=y
CONFIG_KERNEL_BPF_EVENTS=y
CONFIG_KERNEL_KPROBES=y
CONFIG_KERNEL_PERF_EVENTS=y
CONFIG_KERNEL_BPF_STREAM_PARSER=y
CONFIG_PACKAGE_kmod-airoha-xpon=y
CONFIG_PACKAGE_kmod-airoha-pon-frontend=y
CONFIG_PACKAGE_airoha-pond=y
CONFIG_PACKAGE_airoha-ponctl=y
CONFIG_PACKAGE_luci-app-pon=y
CONFIG_PACKAGE_honk=y
CONFIG_PACKAGE_luci-app-honk=y
CONFIG_PACKAGE_kmod-sched-core=y
CONFIG_PACKAGE_kmod-sched-bpf=y
CONFIG_PACKAGE_kmod-veth=y
CONFIG_PACKAGE_kmod-nft-queue=y
CONFIG_PACKAGE_kmod-fttr-fmcs=y
CONFIG_PACKAGE_fttr-tools=y
CONFIG_PACKAGE_hm2004-fttr-firmware=y
CONFIG_PACKAGE_luci-app-h3c-fttr=y
CONFIG_PACKAGE_luci-theme-vantage=y
CONFIG_PACKAGE_luci-i18n-vantage-theme-zh-cn=y
CONFIG_USE_APK=y
CONFIG_SIGNED_PACKAGES=y
CONFIG_SIGN_FIRMWARE=y
EOF
    printf 'binary\n' >"$dir/private-key.pem"
    printf '# snapshot\n' >"$dir/bin/targets/airoha/an7581/config.buildinfo"

    cat >"$kdir/.config" <<'EOF'
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_CGROUP_BPF=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
# CONFIG_DEBUG_INFO_REDUCED is not set
EOF
    : >"$kdir/vmlinux"
    printf 'dtb\n' >"$kdir/arch/arm64/boot/dts/airoha/an7581-h3c-hm2004-du.dtb"
}

make_fw_dir() {
    local dir=$1
    mkdir -p "$dir"
    printf 'x\n' >"$dir/ponwrt-airoha-an7581-h3c_hm2004-du-sysupgrade.itb"
    printf 'x\n' >"$dir/ponwrt-airoha-an7581-h3c_hm2004-du-recovery.itb"
    cat >"$dir/ponwrt-airoha-an7581-h3c_hm2004-du-rootfs.manifest" <<'EOF'
airoha-en7581-npu-firmware - 1 - aarch64_cortex-a53
kmod-airoha-xpon - 6.18.55 - aarch64_cortex-a53
kmod-airoha-pon-frontend - 6.18.55 - aarch64_cortex-a53
airoha-pond - 1.0 - aarch64_cortex-a53
airoha-ponctl - 1.0 - aarch64_cortex-a53
luci-app-pon - 1.0 - all
honk - 2026.11.06 - aarch64_cortex-a53
luci-app-honk - 2026.11.06 - all
kmod-sched-core - 6.18.55 - aarch64_cortex-a53
kmod-sched-bpf - 6.18.55 - aarch64_cortex-a53
kmod-veth - 6.18.55 - aarch64_cortex-a53
kmod-nft-queue - 6.18.55 - aarch64_cortex-a53
kmod-fttr-fmcs - 1.0 - aarch64_cortex-a53
fttr-tools - 1.0.0 - aarch64_cortex-a53
hm2004-fttr-firmware - 1 - aarch64_cortex-a53
luci-app-h3c-fttr - 1 - all
luci-theme-vantage - 1.0.15 - all
luci-i18n-vantage-theme-zh-cn - 1.0.15 - all
EOF
}

# ------------------------------------------------- 桩：dtc（输出指定 dts 文本）
make_dtc_stub() {
    local dir=$1 fixture=$2
    mkdir -p "$dir"
    cat >"$dir/dtc" <<EOF
#!/usr/bin/env bash
out=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then out=\$a; fi
    prev=\$a
done
cat "$fixture" >"\$out"
EOF
    chmod +x "$dir/dtc"
}

# -------------------------------------------------------- 桩：readelf
make_readelf_stub() {
    local dir=$1 with_btf=$2
    mkdir -p "$dir"
    if [ "$with_btf" = "1" ]; then
        cat >"$dir/readelf" <<'EOF'
#!/usr/bin/env bash
echo '  [ 1] .BTF      PROGBITS 0000000000000000'
echo '  [ 2] .BTF.ext  PROGBITS'
EOF
    else
        cat >"$dir/readelf" <<'EOF'
#!/usr/bin/env bash
echo '  [ 1] .text     PROGBITS'
EOF
    fi
    chmod +x "$dir/readelf"
}

fmcs_dts_good() {
    cat <<'EOF'
/ {
	fmcs {
		compatible = "h3c,fmcs";
		spi-controller = <&snfi>;
		nconfig-gpios = <&en7581_pinctrl 24 0>;
		rst-gpios = <&en7581_pinctrl 25 0>;
		clk-gpios = <&en7581_pinctrl 29 0>;
		data-gpios = <&en7581_pinctrl 30 0>;
		status-gpios = <&en7581_pinctrl 26 0>;
		conf-done-gpios = <&en7581_pinctrl 27 0>;
		status = "okay";
	};
};
EOF
}

fmcs_dts_missing() {
    cat <<'EOF'
/ {
	fmcs {
		compatible = "h3c,fmcs";
		fpga-clk-gpios = <&en7581_pinctrl 29 0>;
		fpga-data-gpios = <&en7581_pinctrl 30 0>;
		status = "okay";
	};
};
EOF
}

# ================================================================ 用例
say "### 场景 1：apply_overlay.sh 覆盖引擎"
E1=$WORK/engine1
make_engine "$E1"
E1SHA=$(git -C "$E1" rev-parse HEAD)
make_pins "$WORK/pins1.env" "$E1SHA" 0000000000000000000000000000000000000000

run_expect pass "带 fttr 的覆盖" "" \
    env PINS="$WORK/pins1.env" ENGINE_DIR="$E1" WITH_FTTR=1 bash "$REPO_DIR/scripts/apply_overlay.sh"

INI1="$E1/wrt_core/compilecfg/lk_h3c_hm2004_du.ini"
add1=$(awk -F= '$1=="ADD_RECIPES"{print $2}' "$INI1")
dis1=$(awk -F= '$1=="DISABLE_RECIPES"{print $2}' "$INI1")
if grep -q "src-git honk" "$E1/wrt_core/recipes/honk/recipe.json" &&
    grep -q "^COMMIT_HASH=" "$INI1" &&
    ! grep -q "openwrt-fttr" "$E1/wrt_core/recipes/h3c-hm2004-du_fttr/recipe.json" &&
    [ ! -f "$E1/wrt_core/recipes/h3c-hm2004-du_fttr/configs/stale.config" ] &&
    ! printf '%s' "$add1" | tr ',' '\n' | grep -qx disable_initramfs &&
    printf '%s' "$dis1" | tr ',' '\n' | grep -qx disable_initramfs; then
    say "√ [旧 recipe 目录被清掉、私有源引用被替换、ini 带上了 COMMIT_HASH、disable_initramfs 归到 DISABLE]"
    pass=$((pass + 1))
else
    say "× [overlay 结果不符合预期]"
    grep -n "COMMIT_HASH" "$E1/wrt_core/compilecfg/lk_h3c_hm2004_du.ini" || true
    failed=$((failed + 1))
fi

E2=$WORK/engine2
make_engine "$E2"
E2SHA=$(git -C "$E2" rev-parse HEAD)
make_pins "$WORK/pins2.env" "$E2SHA" 0000000000000000000000000000000000000000
run_expect pass "不带 fttr 的覆盖" "" \
    env PINS="$WORK/pins2.env" ENGINE_DIR="$E2" WITH_FTTR=0 bash "$REPO_DIR/scripts/apply_overlay.sh"
if grep -q "fttr" "$E2/wrt_core/compilecfg/lk_h3c_hm2004_du.ini"; then
    say "× [WITH_FTTR=0 但 ini 里还留着 fttr]"
    failed=$((failed + 1))
else
    say "√ [WITH_FTTR=0 时 ini 里没有 fttr]"
    pass=$((pass + 1))
fi

# 引擎 HEAD 与 pin 不一致时必须拦下
E3=$WORK/engine3
make_engine "$E3"
commit_here "$E3" second --allow-empty
make_pins "$WORK/pins3.env" "$(git -C "$E3" rev-parse HEAD~1)" 0000000000000000000000000000000000000000
run_expect fail "引擎版本对不上要拦" "不是 pin" \
    env PINS="$WORK/pins3.env" ENGINE_DIR="$E3" bash "$REPO_DIR/scripts/apply_overlay.sh"

say
say "### 场景 2：assert_prebuild.sh"
B=$WORK/build
PINS_FEEDS_FILE=$WORK/pins.feeds
make_fake_pins_feeds "$PINS_FEEDS_FILE"
mkdir -p "$B"
git -C "$B" init -q
make_build_tree "$B"
git -C "$B" add -A
commit_here "$B" tree
BSHA=$(git -C "$B" rev-parse HEAD)
make_pins "$WORK/pins4.env" "$E1SHA" "$BSHA"

prebuild() {
    env PINS="$WORK/pins4.env" PINS_FEEDS="$PINS_FEEDS_FILE" ENGINE_DIR="$E1" \
        BUILD_DIR="$B" WITH_FTTR=1 bash "$REPO_DIR/scripts/assert_prebuild.sh"
}
run_expect pass "构建设置全绿" "" prebuild

sed -i 's/^CONFIG_KERNEL_DEBUG_INFO_BTF=y$/# CONFIG_KERNEL_DEBUG_INFO_BTF is not set/' "$B/.config"
run_expect fail "BTF 没开要拦" "KERNEL_DEBUG_INFO_BTF" prebuild
sed -i 's/^# CONFIG_KERNEL_DEBUG_INFO_BTF is not set$/CONFIG_KERNEL_DEBUG_INFO_BTF=y/' "$B/.config"

sed -i 's/^# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set$/CONFIG_KERNEL_DEBUG_INFO_REDUCED=y/' "$B/.config"
run_expect fail "REDUCED 开着要拦" "必须关掉" prebuild
sed -i 's/^CONFIG_KERNEL_DEBUG_INFO_REDUCED=y$/# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set/' "$B/.config"

sed -i '/CONFIG_NET_CLS_BPF=m/d' "$B/target/linux/airoha/an7581/config-6.18"
run_expect fail "子 target 缺符号要拦" "NET_CLS_BPF" prebuild
echo "CONFIG_NET_CLS_BPF=m" >>"$B/target/linux/airoha/an7581/config-6.18"

sed -i '/^src-git hm2004/d' "$B/feeds.conf"
run_expect fail "fttr feed 没 pin 住要拦" "openwrt-hm2004-feed" prebuild
echo "src-git hm2004 https://github.com/rayniel/openwrt-hm2004-feed.git^2222222222222222222222222222222222222222" >>"$B/feeds.conf"

# 上游 feed 退回未锁版本（ponwrt 的 feeds.conf.default 本来就是这样）
sed -i 's|^src-git luci .*|src-git luci https://github.com/immortalwrt/luci.git|' "$B/feeds.conf"
run_expect fail "上游 feed 没锁版本要拦" "luci 没有锁到" prebuild
sed -i 's|^src-git luci https://github.com/immortalwrt/luci.git$|src-git luci https://github.com/immortalwrt/luci.git^4444444444444444444444444444444444444444|' "$B/feeds.conf"

# 主图三兄弟：主题包、中文语言包、feed 锁版本、以及不能留下 Fluent 的默认脚本
sed -i '/^CONFIG_PACKAGE_luci-theme-vantage=y$/d' "$B/.config"
run_expect fail "Vantage 主题没装上要拦" "luci-theme-vantage" prebuild
echo "CONFIG_PACKAGE_luci-theme-vantage=y" >>"$B/.config"

sed -i '/^CONFIG_PACKAGE_luci-i18n-vantage-theme-zh-cn=y$/d' "$B/.config"
run_expect fail "Vantage 中文包没装上要拦" "luci-i18n-vantage-theme-zh-cn" prebuild
echo "CONFIG_PACKAGE_luci-i18n-vantage-theme-zh-cn=y" >>"$B/.config"

sed -i '/^src-git vantage /d' "$B/feeds.conf"
sed -i '/^src-git vantage /d' "$B/feeds.conf.default" 2>/dev/null || true
run_expect fail "vantage feed 没锁版本要拦" "vantage feed 没在任何" prebuild
echo "src-git vantage https://github.com/anothaDev/luci-theme-vantage.git^$FAKE_VANTAGE_SHA" >>"$B/feeds.conf"

mkdir -p "$B/package/base-files/files/etc/uci-defaults"
printf '#!/bin/sh\n' >"$B/package/base-files/files/etc/uci-defaults/990_set_fluent_default"
run_expect fail "Fluent 默认脚本还在要拦" "盖回 Fluent" prebuild
rm -f "$B/package/base-files/files/etc/uci-defaults/990_set_fluent_default"

mv "$B/private-key.pem" "$B/private-key.pem.bak"
run_expect fail "缺签名私钥要拦" "APK_SIGNING_PRIVATE_KEY" prebuild
mv "$B/private-key.pem.bak" "$B/private-key.pem"

printf '  KCONFIG:=CONFIG_FTTR_FMCS=m\n' >>"$B/package/feeds/hm2004/fttr-fmcs/Makefile"
run_expect fail "apply.sh 没生效要拦" ".ko 编不出来" prebuild
sed -i '/KCONFIG:=CONFIG_FTTR_FMCS/d' "$B/package/feeds/hm2004/fttr-fmcs/Makefile"

# recipe 在 pre_defconfig 之后把 INITRAMFS 写成 n —— recovery.itb 就不会产出
sed -i 's/^CONFIG_TARGET_ROOTFS_INITRAMFS=y$/CONFIG_TARGET_ROOTFS_INITRAMFS=n/' "$B/.config"
run_expect fail "INITRAMFS 被 recipe 改掉要拦" "recovery.itb 不会产出" prebuild
sed -i 's/^CONFIG_TARGET_ROOTFS_INITRAMFS=n$/CONFIG_TARGET_ROOTFS_INITRAMFS=y/' "$B/.config"

sed -i '/^obj-m := fttr-fmcs\.o$/d' "$B/feeds/hm2004/original/driver/Makefile"
run_expect fail "驱动缺 obj-m 要拦" "obj-m 行" prebuild
echo "obj-m := fttr-fmcs.o" >>"$B/feeds/hm2004/original/driver/Makefile"

sed -i '/CONFIG_FTTR_FMCS_LOAD_AT_PROBE=1/d' "$B/feeds/hm2004/original/driver/Makefile"
run_expect fail "驱动缺位流加载宏要拦" "LOAD_AT_PROBE" prebuild
echo "ccflags-y += -DCONFIG_FTTR_FMCS_LOAD_AT_PROBE=1" >>"$B/feeds/hm2004/original/driver/Makefile"

sed -i 's|= fmcs_no_llseek,|= no_llseek,|' "$B/feeds/hm2004/original/driver/fmcs.c"
run_expect fail "6.18 适配没落上要拦" "no_llseek" prebuild
sed -i 's|= no_llseek,|= fmcs_no_llseek,|' "$B/feeds/hm2004/original/driver/fmcs.c"

sed -i '/strscpy(family->name/d' "$B/feeds/hm2004/original/driver/fmcs.c"
run_expect fail "genl name 还是赋值要拦" "genl_family.name" prebuild
echo "	strscpy(family->name, fmcs_genl_names[i], sizeof(family->name));" >>"$B/feeds/hm2004/original/driver/fmcs.c"

sed -i '/^#include <linux\/cdev.h>$/d' "$B/feeds/hm2004/original/driver/fmcs.h"
run_expect fail "头文件不自含要拦" "fmcs.h 不自含" prebuild
sed -i '1i #include <linux/cdev.h>' "$B/feeds/hm2004/original/driver/fmcs.h"

sed -i '/patsubst V%/d' "$B/feeds/hm2004/package/fttr-fmcs/Makefile"
run_expect fail "版本号没规范化要拦" "package version is invalid" prebuild
sed -i '/^PKG_RELEASE/i PKG_VERSION:=$(subst -,.,$(patsubst V%,%,$(PKG_VERSION)))' \
    "$B/feeds/hm2004/package/fttr-fmcs/Makefile"

sed -i 's|^miniolt: miniolt\.c fmcs_uapi\.h$|miniolt: miniolt.c ../driver/fmcs_uapi.h|' \
    "$B/feeds/hm2004/original/userspace/Makefile"
run_expect fail "userspace 还按嵌套布局写依赖要拦" "No rule to make target" prebuild
sed -i 's|^miniolt: miniolt\.c \.\./driver/fmcs_uapi\.h$|miniolt: miniolt.c fmcs_uapi.h|' \
    "$B/feeds/hm2004/original/userspace/Makefile"

run_expect pass "补回之后重新全绿" "" prebuild

commit_here "$B" drift --allow-empty
run_expect fail "源码 HEAD 漂了要拦" "不一致" prebuild
git -C "$B" reset --hard -q "$BSHA"

say
say "### 场景 3：assert_artifacts.sh"
FW=$WORK/firmware
make_fw_dir "$FW"
STUBS_OK=$WORK/stubs_ok
fmcs_dts_good >"$WORK/good.dts"
fmcs_dts_missing >"$WORK/bad.dts"
make_dtc_stub "$STUBS_OK" "$WORK/good.dts"
make_readelf_stub "$STUBS_OK" 1
make_readelf_stub "$WORK/stubs_nobtf" 0

artifacts() {
    env PINS="$WORK/pins4.env" ENGINE_DIR="$E1" BUILD_DIR="$B" FW_DIR="$FW" WITH_FTTR=1 \
        PATH="$STUBS_OK:$PATH" bash "$REPO_DIR/scripts/assert_artifacts.sh"
}
run_expect pass "产物全绿" "" artifacts

rm -f "$FW"/*sysupgrade.itb
run_expect fail "缺 sysupgrade 要拦" "sysupgrade.itb" artifacts
printf 'x\n' >"$FW/ponwrt-airoha-an7581-h3c_hm2004-du-sysupgrade.itb"

rm -f "$FW"/*recovery.itb
run_expect fail "缺 recovery 救砖镜像要拦" "recovery.itb" artifacts
printf 'x\n' >"$FW/ponwrt-airoha-an7581-h3c_hm2004-du-initramfs-recovery.itb"

rm -f "$B/bin/targets/airoha/an7581/config.buildinfo"
run_expect fail "缺 config.buildinfo 要拦" "config.buildinfo" artifacts
printf '# snapshot\n' >"$B/bin/targets/airoha/an7581/config.buildinfo"

sed -i '/CONFIG_DEBUG_INFO_BTF=y/d' "$B/$KERNEL_DIR_REL/.config"
run_expect fail "内核实际没开 BTF 要拦" "DEBUG_INFO_BTF" artifacts
echo "CONFIG_DEBUG_INFO_BTF=y" >>"$B/$KERNEL_DIR_REL/.config"

run_expect fail "vmlinux 没有 .BTF 段要拦" ".BTF" \
    env PINS="$WORK/pins4.env" ENGINE_DIR="$E1" BUILD_DIR="$B" FW_DIR="$FW" WITH_FTTR=1 \
    PATH="$WORK/stubs_nobtf:$PATH" bash "$REPO_DIR/scripts/assert_artifacts.sh"

rm -f "$B/$KERNEL_DIR_REL/net/sched/cls_bpf.ko"
run_expect fail "TC 模块没生成要拦" "cls_bpf.ko" artifacts
: >"$B/$KERNEL_DIR_REL/net/sched/cls_bpf.ko"

sed -i '/^honk /d;/^luci-app-honk /d' "$FW"/*rootfs.manifest
run_expect fail "清单里没 honk 要拦" "honk" artifacts
sed -i '$a honk - 2026.11.06 - aarch64_cortex-a53\nluci-app-honk - 2026.11.06 - all' \
    "$FW"/ponwrt-airoha-an7581-h3c_hm2004-du-rootfs.manifest

sed -i '/^luci-theme-vantage /d' "$FW"/*rootfs.manifest
run_expect fail "清单里没 Vantage 主题要拦" "luci-theme-vantage" artifacts
echo "luci-theme-vantage - 1.0.15 - all" >>"$FW"/ponwrt-airoha-an7581-h3c_hm2004-du-rootfs.manifest

# 多 profile 场景：混进一份别的机型的清单，必须挑本机型那份
printf 'nothing - 0 - all\n' >"$FW/openwrt-airoha-an7581-gemtek_w1700k-rootfs.manifest"
run_expect pass "有多份清单时挑本机型那份" "" artifacts

# 两份都不是本机型时，不许退回去随便信一份
mv "$FW"/ponwrt-airoha-an7581-h3c_hm2004-du-rootfs.manifest "$FW/h3c-renamed.manifest"
run_expect fail "没有本机型的清单就不许判" "无法确定该信哪一份" artifacts
mv "$FW/h3c-renamed.manifest" "$FW"/ponwrt-airoha-an7581-h3c_hm2004-du-rootfs.manifest
rm -f "$FW/openwrt-airoha-an7581-gemtek_w1700k-rootfs.manifest"

say
say "### 场景 4：check_fttr_dts.sh"
check_dts() {
    env BUILD_DIR="$B" PATH="$1:$PATH" bash "$REPO_DIR/scripts/check_fttr_dts.sh"
}
STUBS_BAD=$WORK/stubs_bad
make_dtc_stub "$STUBS_BAD" "$WORK/bad.dts"

run_expect pass "设备树给了驱动要的线" "" check_dts "$STUBS_OK"
run_expect fail "线名对不上要拦" "clk-gpios" check_dts "$STUBS_BAD"

# 没有可解析对象时不许静默通过。dtc 在不在取决于机器（CI 装了 device-tree-compiler），
# 所以只要求「非零退出 + 说出合法原因之一」，不锁死措辞；
# 有夹具 DTB 的那条正常路径由上面两个用例负责。
out3=$(mktemp)
env BUILD_DIR="$B" PATH=/usr/bin:/bin bash "$REPO_DIR/scripts/check_fttr_dts.sh" >"$out3" 2>&1
rc3=$?
if [ "$rc3" -ne 0 ] && grep -qE "没有 dtc|反编译失败|找不到编译出的 DTB" "$out3"; then
    say "√ [无 dtc / 无有效 DTB → 明确拒绝（本机分支：$(grep -oE '没有 dtc|反编译失败|找不到编译出的 DTB' "$out3" | head -1)）]"
    pass=$((pass + 1))
else
    say "× [期望明确拒绝，实际 rc=$rc3：$(head -2 "$out3" | tr '\n' ' ')]"
    failed=$((failed + 1))
fi
rm -f "$out3"

say
say "### 场景 5：load_signing_key.sh"
# 用真生成的 EC 私钥，才能走到「usign 那一对没配」这条分支上；
# 拿假密钥喂进去只会在第一步就报「不是能读的私钥」，测不到后面的判据。
if openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/apk-key.pem" 2>/dev/null; then
    real_key() {
        env BUILD_DIR="$B" \
            APK_SIGNING_PRIVATE_KEY="$(cat "$WORK/apk-key.pem")" \
            USIGN_PRIVATE="${1-}" USIGN_PUBLIC="${2-}" \
            bash "$REPO_DIR/scripts/load_signing_key.sh"
    }
    # 只缺 usign：应当放行（构建系统会生成临时固件钥匙），但要说出那句话
    run_expect pass "缺 usign 时降级放行并说明" "" real_key "" ""
    out_usign=$(mktemp)
    env BUILD_DIR="$B" APK_SIGNING_PRIVATE_KEY="$(cat "$WORK/apk-key.pem")" \
        USIGN_PRIVATE="" USIGN_PUBLIC="" bash "$REPO_DIR/scripts/load_signing_key.sh" >"$out_usign" 2>&1
    if grep -q "临时生成固件签名钥匙" "$out_usign"; then
        say "√ [缺 usign 时确实说出了后果，不是静默跳过]"
        pass=$((pass + 1))
    else
        say "× [缺 usign 时没打印降级说明]"
        failed=$((failed + 1))
    fi
    rm -f "$out_usign"
    run_expect fail "usign 私钥不是合法 base64 要拦" "不是合法的 base64" \
        real_key "这不是base64@@@@@@@" "YWJjZA=="
else
    say "! [跳过：本机没有 openssl，测不到 usign 分支]"
fi

load_key() {
    env BUILD_DIR="$B" \
        APK_SIGNING_PRIVATE_KEY="${1-}" USIGN_PRIVATE="${2-}" USIGN_PUBLIC="${3-}" \
        bash "$REPO_DIR/scripts/load_signing_key.sh"
}
run_expect fail "两个密钥都没配要拦" "APK_SIGNING_PRIVATE_KEY" load_key "" "" ""
run_expect fail "私钥读不出来要拦" "EC 私钥" load_key "not-a-real-key" "abc" "def"

say
say "### 场景 6：feed_pins/apply.sh 真的把未锁版本的上游 feed 锁住"
FP=$WORK/feedpin
mkdir -p "$FP/recipes/feed_pins"
cp "$REPO_DIR/pins.feeds" "$FP/recipes/feed_pins/pins.feeds"
# 用 ponwrt 上游 feeds.conf.default 的真实形态（一条都没锁）
cat >"$FP/feeds.conf.default" <<'EOF'
src-git packages https://github.com/immortalwrt/packages.git
src-git luci https://github.com/immortalwrt/luci.git
src-git routing https://github.com/openwrt/routing.git
src-git telephony https://github.com/openwrt/telephony.git
src-git video https://github.com/openwrt/video.git
src-git pon_drivers https://github.com/pbs05/openwrt-pon-drivers.git
src-git pon_userspace https://github.com/pbs05/openwrt-pon-userspace.git
#src-git targets https://github.com/openwrt/targets.git
EOF
run_expect pass "锁版本并自检通过" "" \
    env BUILD_DIR="$FP" RECIPE_DIR="$FP/recipes/feed_pins" \
    bash "$REPO_DIR/overlay/recipes/feed_pins/apply.sh"

locked=$(grep -cE '^src-git [a-z_]+ https://[^ ]+\^[0-9a-f]{40}$' "$FP/feeds.conf.default")
if [ "$locked" -eq 7 ]; then
    say "√ [7 条全部变成 ^<sha>，注释行没被动]"
    pass=$((pass + 1))
else
    say "× [只有 $locked/7 条被锁上]"
    grep -n 'src-git' "$FP/feeds.conf.default" | sed 's/^/    /'
    failed=$((failed + 1))
fi
if grep -q '^#src-git targets' "$FP/feeds.conf.default"; then
    say "√ [注释行保持原样]"
    pass=$((pass + 1))
else
    say "× [注释行被误改]"
    failed=$((failed + 1))
fi

# feeds.conf 与 default 同时存在时，两份都得锁（引擎只读其中一个，漏一个就是静默失效）
cp "$FP/feeds.conf.default" "$FP/feeds.conf"
printf 'src-git packages https://github.com/immortalwrt/packages.git\n' >"$FP/feeds.conf"
printf 'src-git luci https://github.com/immortalwrt/luci.git\n' >>"$FP/feeds.conf"
printf 'src-git routing https://github.com/openwrt/routing.git\n' >>"$FP/feeds.conf"
printf 'src-git telephony https://github.com/openwrt/telephony.git\n' >>"$FP/feeds.conf"
printf 'src-git video https://github.com/openwrt/video.git\n' >>"$FP/feeds.conf"
printf 'src-git pon_drivers https://github.com/pbs05/openwrt-pon-drivers.git\n' >>"$FP/feeds.conf"
printf 'src-git pon_userspace https://github.com/pbs05/openwrt-pon-userspace.git\n' >>"$FP/feeds.conf"
run_expect pass "两份文件都锁" "" \
    env BUILD_DIR="$FP" RECIPE_DIR="$FP/recipes/feed_pins" \
    bash "$REPO_DIR/overlay/recipes/feed_pins/apply.sh"
n2=$(grep -cE '^src-git [a-z_]+ https://[^ ]+\^[0-9a-f]{40}$' "$FP/feeds.conf")
if [ "$n2" -eq 7 ]; then
    say "√ [feeds.conf 也锁上了（$n2/7）]"
    pass=$((pass + 1))
else
    say "× [feeds.conf 漏锁：$n2/7]"
    failed=$((failed + 1))
fi

# 清单里 SHA 写错（不是 40 位）必须当场失败，不能退化成「不锁」
printf 'packages https://github.com/immortalwrt/packages.git abc123\n' >"$FP/recipes/feed_pins/pins.feeds"
run_expect fail "SHA 不是 40 位要拦" "不是 40 位十六进制" \
    env BUILD_DIR="$FP" RECIPE_DIR="$FP/recipes/feed_pins" \
    bash "$REPO_DIR/overlay/recipes/feed_pins/apply.sh"

say
say "### 场景 7：fttr 的 6.18/apk 适配补丁（fmcs.c + fmcs.h + fttr-fmcs Makefile）"
# 夹具不复制第三方源码，而是从补丁自身重建：按 +++ 头切分文件，
# 每个文件取它自己那些 hunk 的上下文行与删除行。补丁和测试因此永远同步。
FT=$WORK/fttrpatch
RECIPE_SRC="$REPO_DIR/overlay/recipes/h3c-hm2004-du_fttr"
mkdir -p "$FT/feeds/hm2004/original/driver" "$FT/package/feeds/hm2004/fttr-fmcs"
# 按 +++ 头切分文件，每个文件取自己那些 hunk 的上下文行与删除行。
rebuild_from_patch() { # $1=补丁 $2=输出根
    awk -v base="$2" '
        /^\+\+\+ b\// {
            p = substr($0, 7); sub(/\t.*/, "", p)
            out = base "/" p
            n = split(p, parts, "/")
            d = ""
            for (i = 1; i < n; i++) { d = d parts[i] "/"; system("mkdir -p \"" base "/" d "\"") }
            inh = 1; next
        }
        /^--- / || /^diff / || /^index / || /^@@/ { next }
        inh && (/^ / || /^-/) { print substr($0, 2) >> out }
    ' "$1"
}
rm -rf "$FT/src"
rebuild_from_patch "$RECIPE_SRC/patches/fmcs-kernel6.18-adapt.patch" "$FT/src"
cp -Rf "$FT/src/feeds/." "$FT/feeds/"
: # 三份文件随目录一起拷
if [ ! -s "$FT/feeds/hm2004/original/driver/fmcs.c" ] ||
    [ ! -s "$FT/feeds/hm2004/original/driver/fmcs.h" ] ||
    [ ! -s "$FT/feeds/hm2004/package/fttr-fmcs/Makefile" ]; then
    say "× [没能从补丁重建出三份夹具文件，后面的判定不可信]"
    failed=$((failed + 1))
fi
printf 'define KernelPackage/fttr-fmcs\n  KCONFIG:=CONFIG_FTTR_FMCS=m CONFIG_FTTR_FMCS_LOAD_AT_PROBE=y\nendef\n' \
    >"$FT/package/feeds/hm2004/fttr-fmcs/Makefile"
printf 'obj-$(CONFIG_FTTR_FMCS)\t\t+= fttr-fmcs.o\n' >"$FT/feeds/hm2004/original/driver/Makefile"

run_fttr() {
    env BUILD_DIR="$FT" RECIPE_DIR="$RECIPE_SRC" bash "$RECIPE_SRC/apply.sh"
}
run_expect pass "补丁能打上且自检通过" "" run_fttr
if grep -q 'strscpy(family->name' "$FT/feeds/hm2004/original/driver/fmcs.c" &&
    ! grep -q '= no_llseek,' "$FT/feeds/hm2004/original/driver/fmcs.c" &&
    grep -q 'include <linux/cdev.h>' "$FT/feeds/hm2004/original/driver/fmcs.h"; then
    say "√ [no_llseek、genl name、头文件自含三处都改掉了]"
    pass=$((pass + 1))
else
    say "× [补丁打完但目标写法还在]"
    failed=$((failed + 1))
fi
run_expect pass "第二次跑不重复打" "" run_fttr

# feed 漂移（头文件少一行 include）时，fuzz=0 必须炸出来
cp "$RECIPE_SRC/patches/fmcs-kernel6.18-adapt.patch" "$WORK/patch.copy"
rm -rf "$FT/src"
rebuild_from_patch "$WORK/patch.copy" "$FT/src"
cp -Rf "$FT/src/feeds/." "$FT/feeds/"
: # 三份文件随目录一起拷
sed -i '/^#include <linux\/netdevice.h>$/d' "$FT/feeds/hm2004/original/driver/fmcs.h"
printf 'define KernelPackage/fttr-fmcs\n  KCONFIG:=CONFIG_FTTR_FMCS=m CONFIG_FTTR_FMCS_LOAD_AT_PROBE=y\nendef\n' \
    >"$FT/package/feeds/hm2004/fttr-fmcs/Makefile"
printf 'obj-$(CONFIG_FTTR_FMCS)\t\t+= fttr-fmcs.o\n' >"$FT/feeds/hm2004/original/driver/Makefile"
run_expect fail "feed 源码漂移要拦" "打不上" run_fttr

say
say "### 场景 8：rootfs 内容核验（看文件系统，不看构建记账）"
RG=$WORK/rootfs_good
mkdir -p "$RG/www/luci-static/vantage/luci" "$RG/etc/uci-defaults" \
    "$RG/usr/lib/lua/luci/i18n" "$RG/lib/modules/6.18.55" "$RG/etc/apk/keys"
touch "$RG/www/luci-static/vantage/luci.js" \
    "$RG/etc/uci-defaults/30_luci-theme-vantage" \
    "$RG/usr/lib/lua/luci/i18n/vantage-theme.zh-cn.lmo" \
    "$RG/lib/modules/6.18.55/cls_bpf.ko" "$RG/lib/modules/6.18.55/act_bpf.ko" \
    "$RG/etc/apk/keys/hm2004.pub"
mkdir -p "$WORK/rf_fw"
check_rootfs() {
    env FW_DIR="$WORK/rf_fw" ROOTFS_DIR="$RG" IMAGE_PROFILE=h3c_hm2004-du \
        PINS="$WORK/pins4.env" bash "$REPO_DIR/scripts/assert_rootfs.sh"
}
run_expect pass "rootfs 内容齐" "" check_rootfs

mv "$RG/www/luci-static/vantage" "$RG/www/luci-static/vantage.bak"
run_expect fail "清单说装了但文件系统里没有要拦" "文件系统里没有" check_rootfs
mv "$RG/www/luci-static/vantage.bak" "$RG/www/luci-static/vantage"

printf '#!/bin/sh\n' >"$RG/etc/uci-defaults/990_set_fluent_default"
run_expect fail "Fluent 默认脚本混进 rootfs 要拦" "起来还是 Fluent" check_rootfs
rm -f "$RG/etc/uci-defaults/990_set_fluent_default"

mv "$RG/usr/lib/lua/luci/i18n/vantage-theme.zh-cn.lmo" "$WORK/lmo.bak"
run_expect fail "中文语言文件缺要拦" "界面会是英文" check_rootfs
mv "$WORK/lmo.bak" "$RG/usr/lib/lua/luci/i18n/vantage-theme.zh-cn.lmo"

rm -f "$RG/lib/modules/6.18.55/cls_bpf.ko"
run_expect fail "TC 模块没进 rootfs 要拦" "cls_bpf.ko 不在" check_rootfs
: >"$RG/lib/modules/6.18.55/cls_bpf.ko"

rm -rf "$RG/etc/apk/keys"
run_expect fail "apk 公钥没进镜像要拦" "/etc/apk/keys" check_rootfs
mkdir -p "$RG/etc/apk/keys"; : >"$RG/etc/apk/keys/hm2004.pub"

# 没有可判的东西时，必须拒绝执行或明确失败，绝不能"没检查就当通过"。
# 注意别再锁本机环境：CI 的 /usr/bin 里真有 unsquashfs（squashfs-tools 是工作流装的），
# 所以「有工具/没工具」两种落点都是合法的拒绝分支。这里：
#   A) 用 PATH 桩强行提供 unsquashfs → 钉住「抠不到镜像」这条分支的措辞；
#   B) 用本机自然环境跑一次 → 只要求「非零退出 + 说出具体原因」，不锁措辞。
stub_sq=$WORK/stub_sq; mkdir -p "$stub_sq"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub_sq/unsquashfs"; chmod +x "$stub_sq/unsquashfs"

out_a=$(mktemp)
env FW_DIR="$WORK/rf_fw" PATH="$stub_sq:/usr/bin:/bin" IMAGE_PROFILE=h3c_hm2004-du \
    PINS="$WORK/pins4.env" bash "$REPO_DIR/scripts/assert_rootfs.sh" >"$out_a" 2>&1
rc_a=$?
if [ "$rc_a" -eq 0 ]; then
    say "× [A：没镜像却通过了，这道门禁会假绿]"
    failed=$((failed + 1))
elif grep -q "找不到 sysupgrade 镜像" "$out_a"; then
    say "√ [A：有 unsquashfs、无镜像 → 点名镜像缺失]"
    pass=$((pass + 1))
else
    say "× [A：失败了但没点名镜像，输出：$(head -2 "$out_a" | tr '\n' ' ')]"
    failed=$((failed + 1))
fi
rm -f "$out_a"

out_b=$(mktemp)
env FW_DIR="$WORK/rf_fw" IMAGE_PROFILE=h3c_hm2004-du PINS="$WORK/pins4.env" \
    PATH="$stub_sq:/usr/bin:/bin" bash "$REPO_DIR/scripts/assert_rootfs.sh" >"$out_b" 2>&1
rc_b=$?
if [ "$rc_b" -ne 0 ] && grep -qE "没给 ROOTFS_DIR|找不到 sysupgrade 镜像" "$out_b"; then
    say "√ [B：非零退出且说出具体原因（本机分支：$(grep -oE '没给 ROOTFS_DIR|找不到 sysupgrade 镜像' "$out_b" | head -1)）]"
    pass=$((pass + 1))
else
    say "× [B：退出码 $rc_b，也没说出合法原因：$(head -2 "$out_b" | tr '\n' ' ')]"
    failed=$((failed + 1))
fi
rm -f "$out_b"

# 只有真的没有 unsquashfs 时，才谈得上「缺工具就拒绝执行」这条分支；
# 有工具就不该误报这条，所以按实际环境判定，不写死期望。
if ! PATH=/usr/bin:/bin command -v unsquashfs >/dev/null 2>&1; then
    out_c=$(mktemp)
    env FW_DIR="$WORK/rf_fw" PATH=/usr/bin:/bin IMAGE_PROFILE=h3c_hm2004-du \
        PINS="$WORK/pins4.env" bash "$REPO_DIR/scripts/assert_rootfs.sh" >"$out_c" 2>&1
    rc_c=$?
    if [ "$rc_c" -ne 0 ] && grep -q "没给 ROOTFS_DIR" "$out_c"; then
        say "√ [C：本机确实无 unsquashfs → 明确拒绝而不是当通过]"
        pass=$((pass + 1))
    else
        say "× [C：期望拒绝执行，实际 rc=$rc_c：$(head -2 "$out_c" | tr '\n' ' ')]"
        failed=$((failed + 1))
    fi
    rm -f "$out_c"
else
    say "· [C 跳过：本机 /usr/bin 里就有 unsquashfs，缺工具分支在本机不可达]"
fi

say "======================================"
say "通过 $pass 项，失败 $failed 项"
[ "$failed" -eq 0 ] || exit 1
