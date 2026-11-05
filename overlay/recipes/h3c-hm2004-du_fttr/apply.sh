#!/usr/bin/env bash
# 由 recipe h3c-hm2004-du_fttr 在 ./scripts/feeds install 之后执行。
#
# 要解决的问题（已核对 rayniel/openwrt-hm2004-feed@19135e79 的真实文件）：
#   package/fttr-fmcs/Makefile 写了
#       KCONFIG:=CONFIG_FTTR_FMCS=m CONFIG_FTTR_FMCS_LOAD_AT_PROBE=y
#       FILES:=$(PKG_BUILD_DIR)/fttr-fmcs.ko
#   而 original/driver/Makefile 用的是
#       obj-$(CONFIG_FTTR_FMCS) += fttr-fmcs.o
#   这两个符号只存在于 feed 自带的 original/driver/Kconfig 里，那个 Kconfig
#   从没被 source 进内核 Kconfig 树，所以内核 .config 里永远不会有它们：
#   obj-$(CONFIG_FTTR_FMCS) 展开成 obj- 被 kbuild 忽略，.ko 根本不生成，
#   到 FILES 那一步才炸。另外 fmcs.c:752 有
#       #ifdef CONFIG_FTTR_FMCS_LOAD_AT_PROBE
#   外部模块编译拿不到 autoconf.h 里的这个宏，探针时加载位流的那段会被编译掉。
#
# 这里做两处最小修正，让 out-of-tree 编译路径成立；不改驱动 C 源码本身。
set -eu

BUILD_DIR=${BUILD_DIR:?BUILD_DIR 未由 recipe.sh 注入}
PKG_MK="$BUILD_DIR/package/feeds/hm2004/fttr-fmcs/Makefile"
DRV_MK="$BUILD_DIR/feeds/hm2004/original/driver/Makefile"
MARKER="hm2004-du-build out-of-tree fix"

for f in "$PKG_MK" "$DRV_MK"; do
    if [ ! -f "$f" ]; then
        echo "fttr: 期待的文件不存在：$f" >&2
        echo "fttr: feed 的目录结构可能变了，请对照 pins.env 里的 FTTR_FEED_URL 重新核对后再改。" >&2
        exit 1
    fi
done

# ---- 1) 去掉指向不存在内核符号的 KCONFIG 依赖 ----
if grep -q '^[[:space:]]*KCONFIG:=CONFIG_FTTR_FMCS' "$PKG_MK"; then
    sed -i '/^[[:space:]]*KCONFIG:=CONFIG_FTTR_FMCS/d' "$PKG_MK"
    echo "fttr: 已从 $(basename "$PKG_MK") 删除 KCONFIG:=CONFIG_FTTR_FMCS 行"
elif grep -q 'KCONFIG' "$PKG_MK"; then
    echo "fttr: KCONFIG 行的写法和预期不同，请人工确认后再放行构建：" >&2
    grep -n 'KCONFIG' "$PKG_MK" >&2
    exit 1
else
    echo "fttr: KCONFIG 行已不在（此前已处理），跳过"
fi

# ---- 2) 驱动 Makefile：强制 obj-m + 补上位流加载宏 ----
if grep -Fq "$MARKER" "$DRV_MK"; then
    echo "fttr: 驱动 Makefile 已修正过，跳过"
else
    if ! grep -q 'fttr-fmcs\.o' "$DRV_MK"; then
        echo "fttr: 驱动 Makefile 里找不到 fttr-fmcs.o，目标文件可能改名了：$DRV_MK" >&2
        exit 1
    fi
    {
        printf '\n# %s\n' "$MARKER"
        printf 'obj-m := fttr-fmcs.o\n'
        printf 'ccflags-y += -DCONFIG_FTTR_FMCS_LOAD_AT_PROBE=1\n'
    } >>"$DRV_MK"
    echo "fttr: 已在驱动 Makefile 追加 obj-m 与 CONFIG_FTTR_FMCS_LOAD_AT_PROBE 宏"
fi

# ---- 3) 自检：确认两处修正真的落到了文件里 ----
if grep -q '^[[:space:]]*KCONFIG:=CONFIG_FTTR_FMCS' "$PKG_MK"; then
    echo "fttr: 自检失败，KCONFIG 行仍在 $PKG_MK" >&2
    exit 1
fi
if ! grep -q '^obj-m := fttr-fmcs\.o$' "$DRV_MK"; then
    echo "fttr: 自检失败，obj-m 行不在 $DRV_MK" >&2
    exit 1
fi
echo "fttr: out-of-tree 修正完成并通过自检"
