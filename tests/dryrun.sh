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
HONK_SHA=1111111111111111111111111111111111111111
FTTR_FEED_URL=https://github.com/rayniel/openwrt-hm2004-feed
FTTR_SHA=2222222222222222222222222222222222222222
BUILD_TARGET=lk_h3c_hm2004_du
IMAGE_PROFILE=h3c_hm2004-du
DTS_COMPAT=h3c,hm2004-du
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

    cat >"$dir/feeds.conf" <<'EOF'
src-git packages https://github.com/immortalwrt/packages.git
src-git honk https://github.com/kenzok8/openwrt-honk.git^1111111111111111111111111111111111111111
src-git hm2004 https://github.com/rayniel/openwrt-hm2004-feed.git^2222222222222222222222222222222222222222
EOF

    cat >"$dir/feeds/hm2004/original/driver/fmcs_load.c" <<'EOF'
	ret = fmcs_bitstream_get_gpio(dev, "nconfig", GPIOD_OUT_HIGH, &bs->nconfig);
	ret = fmcs_bitstream_get_gpio(dev, "clk", GPIOD_OUT_LOW, &bs->clk);
	ret = fmcs_bitstream_get_gpio(dev, "data", GPIOD_OUT_LOW, &bs->data);
EOF
    : >"$dir/feeds/hm2004/original/driver/fmcs.c"

    cat >"$dir/.config" <<'EOF'
CONFIG_TARGET_airoha=y
CONFIG_TARGET_airoha_an7581=y
CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_h3c_hm2004-du=y
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
CONFIG_USE_APK=y
CONFIG_SIGNED_PACKAGES=y
CONFIG_SIGN_FIRMWARE=y
EOF
    printf 'binary\n' >"$dir/private-key.pem"
    printf '# snapshot\n' >"$dir/config.buildinfo"

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

if grep -q "src-git honk" "$E1/wrt_core/recipes/honk/recipe.json" &&
    grep -q "^COMMIT_HASH=" "$E1/wrt_core/compilecfg/lk_h3c_hm2004_du.ini" &&
    ! grep -q "openwrt-fttr" "$E1/wrt_core/recipes/h3c-hm2004-du_fttr/recipe.json" &&
    [ ! -f "$E1/wrt_core/recipes/h3c-hm2004-du_fttr/configs/stale.config" ]; then
    say "√ [旧 recipe 目录被清掉、私有源引用被替换、ini 带上了 COMMIT_HASH]"
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
mkdir -p "$B"
git -C "$B" init -q
make_build_tree "$B"
git -C "$B" add -A
commit_here "$B" tree
BSHA=$(git -C "$B" rev-parse HEAD)
make_pins "$WORK/pins4.env" "$E1SHA" "$BSHA"

PINENV=("$B")
prebuild() {
    env PINS="$WORK/pins4.env" ENGINE_DIR="$E1" BUILD_DIR="$B" WITH_FTTR=1 \
        bash "$REPO_DIR/scripts/assert_prebuild.sh"
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

mv "$B/private-key.pem" "$B/private-key.pem.bak"
run_expect fail "缺签名私钥要拦" "APK_SIGNING_PRIVATE_KEY" prebuild
mv "$B/private-key.pem.bak" "$B/private-key.pem"

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

say
say "### 场景 4：check_fttr_dts.sh"
check_dts() {
    env BUILD_DIR="$B" PATH="$1:$PATH" bash "$REPO_DIR/scripts/check_fttr_dts.sh"
}
STUBS_BAD=$WORK/stubs_bad
make_dtc_stub "$STUBS_BAD" "$WORK/bad.dts"

run_expect pass "设备树给了驱动要的线" "" check_dts "$STUBS_OK"
run_expect fail "线名对不上要拦" "clk-gpios" check_dts "$STUBS_BAD"

run_expect fail "没有 dtc 时不许静默通过" "dtc" \
    env BUILD_DIR="$B" PATH=/usr/bin:/bin bash "$REPO_DIR/scripts/check_fttr_dts.sh"

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

say "======================================"
say "通过 $pass 项，失败 $failed 项"
[ "$failed" -eq 0 ] || exit 1
