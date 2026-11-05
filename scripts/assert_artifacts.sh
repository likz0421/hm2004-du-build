#!/usr/bin/env bash
# 硬门禁（构建后）：只认证物，不认日志里的自我声明。
#
# 检查顺序按「需求文档的优先级排序」来：
#   PON 光猫硬件/注册 > fttr 可用 > eBPF & honk > 其他
# 所以先确认镜像本体和 PON 那套包在，再确认 BTF 真的进了内核二进制，
# 最后才是 honk/fttr 的包。任何一项不达标都会打印它自己的判据。
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

PINS=${PINS:-$REPO_DIR/pins.env}
ENGINE_DIR=${ENGINE_DIR:-$REPO_DIR/engine}
BUILD_DIR=${BUILD_DIR:-$ENGINE_DIR/action_build}
FW_DIR=${FW_DIR:-$ENGINE_DIR/firmware}
WITH_FTTR=${WITH_FTTR:-1}

# shellcheck disable=SC1090
. "$PINS"

fail=0
problems=()

bad() {
    problems+=("$1")
    fail=1
}

ok() {
    echo "√ $1"
}

if [ ! -d "$FW_DIR" ]; then
    echo "固件目录不存在：$FW_DIR" >&2
    exit 1
fi

echo "=============== 产物核验 ==============="

# --- 1. 源码树仍然是 pin 的那个 commit（构建过程没被分支头带跑）---
head_sha=$(git -C "$BUILD_DIR" rev-parse HEAD 2>/dev/null || echo 取不到)
if [ "$head_sha" = "$PONWRT_SHA" ]; then
    ok "源码树 HEAD = pin 的 commit ${PONWRT_SHA:0:8}"
else
    bad "源码树 HEAD 漂了：期望 $PONWRT_SHA，实际 $head_sha"
fi

# --- 2. 目标镜像本体 ---
sysupgrade=""
recovery=""
while IFS= read -r f; do
    case "${f##*/}" in
    *h3c_hm2004-du*sysupgrade.itb) sysupgrade=$f ;;
    *h3c_hm2004-du*recovery.itb) recovery=$f ;;
    esac
done < <(find "$FW_DIR" -maxdepth 1 -type f -name '*.itb' | sort)

if [ -z "$sysupgrade" ]; then
    bad "没找到 h3c_hm2004-du 的 sysupgrade.itb。firmware/ 里实际是：$(find "$FW_DIR" -maxdepth 1 -type f | sort | tr '\n' ' ')"
else
    ok "sysupgrade 镜像：$(basename "$sysupgrade")（$(wc -c <"$sysupgrade") 字节）"
fi
if [ -z "$recovery" ]; then
    # 设备配置里已打开 CONFIG_TARGET_ROOTFS_INITRAMFS=y，产出 -recovery.itb 是
    # 需求文档「救砖固件」这一条的实际落点；没出来就是真缺东西，不能只警告。
    bad "没有 recovery.itb：CONFIG_TARGET_ROOTFS_INITRAMFS=y 应当产出 KERNEL_INITRAMFS_SUFFIX=-recovery.itb 的救砖镜像。firmware/ 实际内容：$(find "$FW_DIR" -maxdepth 1 -type f | sort | tr '\n' ' ')"
else
    ok "recovery 镜像：$(basename "$recovery")（$(wc -c <"$recovery") 字节）"
fi

# --- 3. 内核实际配置与 BTF 二进制证据 ---
kdir=""
for d in "$BUILD_DIR"/build_dir/target-*/linux-airoha_an7581/linux-*; do
    [ -d "$d" ] && kdir=$d
done
if [ -z "$kdir" ]; then
    bad "找不到内核构建树（build_dir/target-*/linux-airoha_an7581/linux-*）"
else
    if grep -q '^CONFIG_DEBUG_INFO_BTF=y$' "$kdir/.config"; then
        ok "内核 .config：CONFIG_DEBUG_INFO_BTF=y"
    else
        bad "内核 .config 里 DEBUG_INFO_BTF 不是 y（实际：$(grep '^CONFIG_DEBUG_INFO_BTF' "$kdir/.config" | head -1 || echo 无此行)）"
    fi
    if grep -q '^CONFIG_DEBUG_INFO_REDUCED=y$' "$kdir/.config"; then
        bad "内核 .config 里 DEBUG_INFO_REDUCED=y，它会把 BTF 挡掉"
    fi
    for sym in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_CGROUP_BPF; do
        grep -q "^$sym=y$" "$kdir/.config" || bad "内核 .config 缺 $sym=y"
    done
    for mod in net/sched/cls_bpf.ko net/sched/act_bpf.ko; do
        if [ -f "$kdir/$mod" ]; then
            ok "TC eBPF 模块已生成：$mod"
        else
            bad "TC eBPF 模块没生成：$mod（kmod-sched-bpf 会是空包，honk 起不来）"
        fi
    done

    if [ -f "$kdir/vmlinux" ]; then
        if readelf -S "$kdir/vmlinux" 2>/dev/null | grep -qE '\.BTF'; then
            ok "vmlinux 里有 .BTF 段——这是 honk 用 CO-RE 的真正前提"
        else
            bad "vmlinux 没有 .BTF 段：配置写了但没生成（pahole 失败或被裁剪）。readelf 输出：$(readelf -S "$kdir/vmlinux" 2>/dev/null | grep -c Section) 个段里没有 .BTF"
        fi
    else
        bad "找不到 $kdir/vmlinux，无法验证 BTF 段"
    fi
fi

# --- 4. 装进 rootfs 的包（用固件自带的 manifest 核对）---
# 多 profile 构建会有多份 manifest，必须用本机型那一份；挑错文件等于没检查。
manifest=$(find "$FW_DIR" -maxdepth 1 -type f -name "*${IMAGE_PROFILE}*.manifest" | head -1)
if [ -z "$manifest" ]; then
    count=$(find "$FW_DIR" -maxdepth 1 -type f -name '*.manifest' | wc -l)
    if [ "$count" = "1" ]; then
        manifest=$(find "$FW_DIR" -maxdepth 1 -type f -name '*.manifest' | head -1)
        echo "! 没有带机型名的 manifest，退回到唯一的那份：$(basename "$manifest")" >&2
    elif [ "$count" = "0" ]; then
        bad "firmware/ 里一份 .manifest 都没有，无法核对装机包"
    else
        bad "有 $count 份 manifest 但没有一份带机型名 $IMAGE_PROFILE，无法确定该信哪一份"
    fi
fi
if [ -n "$manifest" ]; then
    ok "清单：$(basename "$manifest")"
    in_manifest() {
        # 清单行形如「kmod-sched-bpf - 6.18.55 - aarch64_cortex-a53」，
        # 也可能写成 name@version。名字左边必须是行首或空白/斜杠，右边必须
        # 是分隔符——否则 honk 会被 luci-app-honk 蒙过去。
        if ! grep -qE "(^|[[:space:]/])$1([[:space:]]|[@_.:-]|$)" "$manifest"; then
            bad "rootfs 清单里没有包：$1"
        fi
    }
    for p in kmod-airoha-xpon kmod-airoha-pon-frontend airoha-pond airoha-ponctl luci-app-pon; do
        in_manifest "$p"
    done
    for p in honk luci-app-honk kmod-sched-core kmod-sched-bpf kmod-veth kmod-nft-queue; do
        in_manifest "$p"
    done
    if [ "$WITH_FTTR" = "1" ]; then
        for p in kmod-fttr-fmcs fttr-tools hm2004-fttr-firmware luci-app-h3c-fttr; do
            in_manifest "$p"
        done
    fi
fi

# --- 5. 编译配置快照（需求文档「四、4 输出 config.seed 快照」）---
if [ -f "$BUILD_DIR/.config" ]; then
    ok "config.seed 可用：$(wc -l <"$BUILD_DIR/.config") 行"
else
    bad "缺少 $BUILD_DIR/.config"
fi
# config.buildinfo 是发布物之一，落在 bin/targets 里，不在源码树根上。
buildinfo=$(find "$BUILD_DIR/bin/targets" -maxdepth 3 -type f -name config.buildinfo 2>/dev/null | head -1)
if [ -n "$buildinfo" ]; then
    ok "config.buildinfo 可用：$(basename "$(dirname "$buildinfo")")/config.buildinfo"
else
    bad "在 bin/targets 下找不到 config.buildinfo（实际搜过的根：$BUILD_DIR/bin/targets）"
fi

if [ "$fail" -ne 0 ]; then
    echo "=============== 产物核验未通过 ==============="
    for p in "${problems[@]}"; do
        echo "× $p"
    done
    echo
    echo "判据来自 scripts/assert_artifacts.sh。"
    exit 1
fi

echo "√ 产物核验全部通过"
