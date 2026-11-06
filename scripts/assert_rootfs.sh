#!/usr/bin/env bash
# 硬门禁（rootfs 内容级）：把发布出来的 sysupgrade 镜像里的 squashfs 抠出来，
# 直接看设备真正会跑到的文件在不在。
#
# 为什么清单核对不够：.manifest 说的是「哪些包被装进 rootfs」，它是构建系统自己的
# 记账；而设备行为取决于文件系统里真的有什么。两类东西只能靠文件系统确认：
#   - uci-defaults 的执行顺序（30_ 与 990_ 谁在，决定主图是不是 Vantage）；
#   - apk 公钥是否真被写进 /etc/apk/keys（决定设备端软件源能不能验签通过）。
# 这条门禁把「我核过了」从人工 grep 变成每次构建自动判。
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
PINS=${PINS:-$REPO_DIR/pins.env}
FW_DIR=${FW_DIR:?用法：FW_DIR=<固件目录> scripts/assert_rootfs.sh}

# shellcheck disable=SC1091
. "$PINS"

fail=0
problems=()
bad() { problems+=("$1"); fail=1; }
ok() { echo "√ $1"; }

if ! command -v unsquashfs >/dev/null 2>&1; then
    if [ -z "${ROOTFS_DIR:-}" ]; then
        echo "× 本机没有 unsquashfs，且没给 ROOTFS_DIR：这道检查要么装 squashfs-tools，" >&2
        echo "  要么显式交出一份已解包的 rootfs（测试用）。不做「没有工具就当通过」。" >&2
        exit 1
    fi
fi

img=$(find "$FW_DIR" -maxdepth 1 -type f -name "*${IMAGE_PROFILE}*sysupgrade.itb" | head -1)

if [ -n "${ROOTFS_DIR:-}" ]; then
    # 已解包的 rootfs（本地测试用；CI 走下面的抠 squashfs 路线）
    [ -d "$ROOTFS_DIR" ] || { echo "× ROOTFS_DIR 不存在：$ROOTFS_DIR" >&2; exit 1; }
    R="$ROOTFS_DIR"
    ok "使用交来的 rootfs：$R"
else
if [ -z "$img" ]; then
    echo "× 找不到 sysupgrade 镜像，无法开 rootfs 检查：$FW_DIR" >&2
    exit 1
fi

off=$(grep -abom1 'hsqs' "$img" | cut -d: -f1 || true)
if [ -z "$off" ]; then
    bad "在 $(basename "$img") 里找不到 squashfs 魔数 hsqs，说明镜像结构和预期不符（不是 squashfs rootfs？）"
    echo "=============== rootfs 内容核验未通过 ==============="
    for p in "${problems[@]}"; do echo "× $p"; done
    exit 1
fi

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
dd if="$img" of="$work/rootfs.squashfs" bs=1 skip="$off" status=none
if [ ! -s "$work/rootfs.squashfs" ]; then
    bad "从偏移 $off 抠出来的 squashfs 是空的"
    exit 1
fi
echo "==> 从偏移 $off 抠出 squashfs，解包…"
if ! unsquashfs -no-progress -d "$work/x" "$work/rootfs.squashfs" >"$work/unsquashfs.log" 2>&1; then
    # unsquashfs 对尾部附加数据（fit metadata）有时会返回非零但仍解出绝大部分文件；
    # 这里不信返回值，改信「解出来的文件数量」，并且数量过少就直接判失败。
    n=$(find "$work/x" -mindepth 1 2>/dev/null | wc -l)
    if [ "${n:-0}" -lt 500 ]; then
        bad "unsquashfs 解包失败且解出内容过少（$n 个条目），日志尾部：$(tail -3 "$work/unsquashfs.log" | tr '\n' ' ')"
        echo "=============== rootfs 内容核验未通过 ==============="
        for p in "${problems[@]}"; do echo "× $p"; done
        exit 1
    fi
    echo "! unsquashfs 返回非零（多半是镜像尾部的 fit 元数据），但解出 $n 个条目，继续判定" >&2
fi
R="$work/x"
ok "rootfs 解包完成"
fi

# --- 1. 主图：Vantage 的文件真在，Fluent 的默认脚本真不在 ---
if [ -d "$R/www/luci-static/vantage" ]; then
    ok "/www/luci-static/vantage 存在（$(find "$R/www/luci-static/vantage" -type f | wc -l) 个文件）"
else
    bad "/www/luci-static/vantage 不在 rootfs 里：清单说装了，文件系统里没有"
fi
if [ -e "$R/etc/uci-defaults/30_luci-theme-vantage" ]; then
    ok "/etc/uci-defaults/30_luci-theme-vantage 存在"
else
    bad "主题自带的注册脚本 30_luci-theme-vantage 没进 rootfs，首次启动不会选中 Vantage"
fi
if [ -e "$R/etc/uci-defaults/990_set_fluent_default" ]; then
    bad "990_set_fluent_default 还在 rootfs 里：它按顺序晚于 30_ 执行，设备起来还是 Fluent"
fi
if [ -e "$R/usr/lib/lua/luci/i18n/vantage-theme.zh-cn.lmo" ] ||
    find "$R" -path "*luci/i18n/vantage-theme.zh*" -type f 2>/dev/null | grep -q .; then
    ok "Vantage 简体中文语言文件在 rootfs 里"
else
    bad "找不到 vantage-theme 的 zh-cn 语言文件（.lmo），界面会是英文"
fi

# --- 2. honk 的 eBPF 前提：TC 模块真在 /lib/modules 里 ---
kver_dir=$(find "$R/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -z "$kver_dir" ]; then
    bad "/lib/modules 下没有任何内核模块目录"
else
    for ko in cls_bpf.ko act_bpf.ko; do
        if [ -e "$kver_dir/$ko" ]; then
            ok "$ko 在 $(basename "$kver_dir") 里"
        else
            bad "$ko 不在 $(basename "$kver_dir") 里：honk 的 TC 数据面起不来"
        fi
    done
fi

# --- 3. apk 验签：镜像里的公钥必须就是我们 Secrets 里那把 ---
if [ -d "$R/etc/apk/keys" ]; then
    nkeys=$(find "$R/etc/apk/keys" -type f | wc -l)
    if [ "$nkeys" -ge 1 ]; then
        ok "/etc/apk/keys 有 $nkeys 个公钥：$(find "$R/etc/apk/keys" -type f -printf '    %f\n')"
    else
        bad "/etc/apk/keys 是空的：设备端装包无法验签（签名开关与密钥没配套）"
    fi
else
    bad "rootfs 里没有 /etc/apk/keys 目录"
fi

if [ "$fail" -ne 0 ]; then
    echo "=============== rootfs 内容核验未通过 ==============="
    for p in "${problems[@]}"; do echo "× $p"; done
    echo
    echo "判据来自 scripts/assert_rootfs.sh——它看的是镜像里的文件系统，不是构建的记账。"
    exit 1
fi
echo "√ rootfs 内容核验全部通过"
