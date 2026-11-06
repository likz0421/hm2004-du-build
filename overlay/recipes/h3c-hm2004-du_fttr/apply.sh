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

# ---- 3) 驱动源码对 6.18 内核的适配 ----
# 两处失败都是真实构建日志给出的，不是推测：
#   构建 42098806007：fmcs.c:636 'no_llseek' undeclared（v6.x 已删该符号）
#                     fmcs.c:918 assignment to expression with array type
#                     （genl_family.name 是 char[GENL_NAMSIZ]，见 genetlink.h:80）
#   构建 42126367809：过了 fmcs.o 之后，fmcs_spi.o 报
#                     fmcs.h:112 field 'cdev' has incomplete type
#                     —— 头文件用了 struct cdev / atomic_t / wait_queue_head_t，
#                     却没 include 对应头；fmcs.c 恰好先包含了 cdev.h 所以它编得过，
#                     换个编译单元就崩。修法是把头文件补自含（这是头文件该有的样子）。
#   同一场收尾时：.ko 能编了，打包却报
#                     ERROR: info field 'version' has invalid value:
#                     package version is invalid
#                     —— 上游把驱动版本串原值 V2024-0418-0001 当 PKG_VERSION 用，
#                     而 apk-tools 的版本格式不接受字母开头的组件。补丁追加一行
#                     make 侧规范化（patsubst 去前导 V、subst 把 - 换成 .），
#                     得到 2024.0418.0001；驱动真实版本仍由 fmcs.h 决定，不改它本身。
# 对应文档「二、约束：驱动补丁要适配当前内核版本」。补丁用 --fuzz=0：
# feed 一漂移就失败，绝不容忍"上下文对不上也硬打"。
#   构建 42242418204：fmcs 编过了，换 fttr-tools 报
#       make[4]: *** No rule to make target '../driver/fmcs_uapi.h', needed by 'miniolt'
#     —— 包定义把 userspace/* 和 driver/fmcs_uapi.h 平铺拷进同一个 PKG_BUILD_DIR，
#     而 userspace/Makefile 仍按 feed 里的嵌套布局写依赖与 -I../driver。
#     miniolt.c 自己 include 的是 "fmcs_uapi.h"（同目录），所以改成平铺形式即可。
SRC="$BUILD_DIR/feeds/hm2004/original/driver/fmcs.c"
HDR="$BUILD_DIR/feeds/hm2004/original/driver/fmcs.h"
USR="$BUILD_DIR/feeds/hm2004/original/userspace/Makefile"
PKG="$BUILD_DIR/feeds/hm2004/package/fttr-fmcs/Makefile"
PATCH="$RECIPE_DIR/patches/fmcs-kernel6.18-adapt.patch"
for f in "$SRC" "$HDR" "$USR" "$PKG" "$PATCH"; do
    if [ ! -f "$f" ]; then
        echo "fttr: 期待的文件不存在：$f" >&2
        exit 1
    fi
done

if grep -q 'fmcs_no_llseek' "$SRC" && grep -q 'include <linux/cdev.h>' "$HDR" &&
    grep -q '^miniolt: miniolt\.c fmcs_uapi\.h$' "$USR" && grep -q 'patsubst V%' "$PKG"; then
    echo "fttr: 驱动源码与包定义已打过适配补丁，跳过"
else
    if ! (cd "$BUILD_DIR" && patch -p1 -N --fuzz=0 -i "$PATCH"); then
        echo "× fttr: 适配补丁打不上（--fuzz=0，上下文必须逐行对得上）——" >&2
        echo "  feed 的 fmcs.c / fmcs.h / userspace/Makefile / fttr-fmcs/Makefile 变了。" >&2
        echo "  要重新核对：no_llseek（已删）、genl_family.name（数组不是指针）、" >&2
        echo "  fmcs.h 的 cdev/atomic/wait 自含头、userspace 里 ../driver 的布局假设、" >&2
        echo "  PKG_VERSION 对 apk 版本格式是否合法" >&2
        exit 1
    fi
    echo "fttr: 已应用适配补丁（4 个文件）"
fi

# ---- 4) 自检：确认每一处报错点真的被改掉 ----
if grep -q '^[[:space:]]*\.llseek[[:space:]]*=[[:space:]]*no_llseek,' "$SRC"; then
    echo "fttr: 自检失败，仍然在用被删除的 no_llseek：$SRC" >&2
    exit 1
fi
if ! grep -q 'strscpy(family->name' "$SRC"; then
    echo "fttr: 自检失败，genl_family.name 还是赋值写法（它是数组，编译会直接报错）" >&2
    exit 1
fi
if ! grep -q 'include <linux/cdev.h>' "$HDR"; then
    echo "fttr: 自检失败，fmcs.h 仍不自含：用 struct cdev 却不 include linux/cdev.h" >&2
    exit 1
fi
if ! grep -q 'patsubst V%' "$PKG"; then
    echo "fttr: 自检失败，PKG_VERSION 没做规范化：V2024-0418-0001 会被 apk 判 version invalid" >&2
    exit 1
fi
# 判 make 真正会用到的那两行，不能宽泛 grep "../driver"——
# 补丁自带的注释里就出现这个词，宽判会自己误伤自己（本机测试抓到过）。
if ! grep -qE '^miniolt:[[:space:]]+miniolt\.c[[:space:]]+fmcs_uapi\.h[[:space:]]*$' "$USR"; then
    echo "fttr: 自检失败，miniolt 的依赖不是平铺形式（../driver 会让 make 报 No rule to make target）" >&2
    grep -nE '^miniolt:' "$USR" >&2 || true
    exit 1
fi
if grep -qE '^[[:space:]]*CPPFLAGS[[:space:]]*\+[=][:]?=?[[:space:]]*-I\.\./driver' "$USR"; then
    echo "fttr: 自检失败，userspace/Makefile 还在用 -I../driver" >&2
    exit 1
fi

# ---- 5) 自检：确认前两处修正真的落到了文件里 ----
if grep -q '^[[:space:]]*KCONFIG:=CONFIG_FTTR_FMCS' "$PKG_MK"; then
    echo "fttr: 自检失败，KCONFIG 行仍在 $PKG_MK" >&2
    exit 1
fi
if ! grep -q '^obj-m := fttr-fmcs\.o$' "$DRV_MK"; then
    echo "fttr: 自检失败，obj-m 行不在 $DRV_MK" >&2
    exit 1
fi
echo "fttr: out-of-tree 修正完成并通过自检"
