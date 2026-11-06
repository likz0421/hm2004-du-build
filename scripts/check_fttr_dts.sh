#!/usr/bin/env bash
# 检查编译出来的 DTB 里 fmcs 节点，是否给了驱动真正要的 GPIO 线。
#
# 为什么要单独立一道闸：这一条不影响编译，只影响 fttr 到底能不能用。
# 驱动按 con_id 取线（rayniel/openwrt-hm2004-feed@19135e79）：
#   original/driver/fmcs_load.c:300-315 → nconfig / rst / clk / data / status / conf-done
#   original/driver/fmcs_spi.c:321-324  → sck / mosi / miso / cs（位流是用 GPIO 位敲进去的）
# 也就是要 10 条 *-gpios。而 ponwrt 的
# target/linux/airoha/dts/an7581-h3c-hm2004-du.dts:125-127 只给了三条，名字还带 fpga- 前缀
# （fpga-spi-int / fpga-clk / fpga-data）—— con_id 对不上就等于没给。
# con_id 取不到线时 devm_gpiod_get_optional 只给 NULL，不报错；但 fmcs_spi.c:335 见
# sck 为空就 -ENODEV 返回，而它是 fmcs.c:729 fmcs_probe_common() 的第一步，所以驱动
# 根本绑不上设备。配置线那条另有守卫：fmcs_load.c:143 见 nconfig/clk/data 为空也 -ENODEV。
# kmod 编出来了、装上了，也不等于 fttr 可用。
#
# 输入用「这次构建真正嵌进镜像的那份 DTB」，不是仓库里的 .dts 文本，避免审的和发的不是一份。
set -uo pipefail

BUILD_DIR=${BUILD_DIR:?用法：BUILD_DIR=<源码树> scripts/check_fttr_dts.sh}
DTS_NAME=${DTS_NAME:-an7581-h3c-hm2004-du}
COMPAT_PATTERN='"h3c,fmcs"'

DTCC="$BUILD_DIR/staging_dir/host/bin/dtc"
if [ ! -x "$DTCC" ]; then
    DTCC=$(command -v dtc || true)
fi
if [ -z "${DTCC:-}" ]; then
    echo "× 没有 dtc（staging_dir/host/bin/dtc 和 PATH 里都没找到），这道检查没法执行。" >&2
    exit 1
fi

# DTB 的真实落点由镜像定义决定，不是内核 dts 目录：
#   target/linux/airoha/image/an7581.mk:317  DEVICE_DTS := an7581-h3c-hm2004-du
#   同文件 :329                    fit gzip $(KDIR)/image-$(DEVICE_DTS).dtb ...
#   include/image.mk:40/691        KDIR = KERNEL_BUILD_DIR，产物名是 image-<dts>.dtb
# 也就是 build_dir/target-*/linux-airoha_an7581/image-an7581-h3c-hm2004-du.dtb，
# 带 image- 前缀、在 KDIR 这一层。构建 42286251323 就是按 arch/arm64/boot/dts/...
# 找，什么都没找到，把「门禁跑不了」报成了「门禁拦住」。
# 内核 dts 目录那条留作兜底：换 target 或换 OpenWrt 版本时布局可能真是那样。
dtb=""
dtb_tried=""
for pat in \
    "$BUILD_DIR"/build_dir/target-*/linux-*/image-"$DTS_NAME".dtb \
    "$BUILD_DIR"/build_dir/target-*/linux-*/linux-*/arch/*/boot/dts/*/"$DTS_NAME".dtb; do
    dtb_tried="$dtb_tried $pat"
    for f in $pat; do
        if [ -f "$f" ]; then dtb=$f; break; fi
    done
    [ -n "$dtb" ] && break
done
if [ -z "$dtb" ]; then
    echo "× 找不到编译出的 DTB，这道闸没法审产物。找过的位置：" >&2
    for p in $dtb_tried; do echo "    $p" >&2; done
    echo "  能编出镜像却在这里找不到，说明镜像的 DTB 落点变了（DEVICE_DTS / KDIR 命名），" >&2
    echo "  去 target/linux/airoha/image/an7581.mk 核对 image-\$(DEVICE_DTS).dtb 那一条。" >&2
    exit 1
fi
echo "审的 DTB：$dtb"

tmp_dts=$(mktemp)
trap 'rm -f "$tmp_dts"' EXIT
if ! "$DTCC" -I dtb -O dts -o "$tmp_dts" "$dtb" 2>/dev/null; then
    echo "× dtc 反编译失败：$dtb" >&2
    exit 1
fi

# 取出 compatible = "h3c,fmcs" 那个节点的完整文本块。
node=$(awk -v pat="$COMPAT_PATTERN" '
    { lines[NR] = $0 }
    index($0, pat) > 0 && hit == 0 { hit = NR }
    END {
        if (hit == 0) exit 3
        s = hit
        while (s > 1 && lines[s] !~ /\{$/) s--
        e = hit
        while (e < NR && lines[e] !~ /^[[:space:]]*\};/) e++
        for (i = s; i <= e; i++) print lines[i]
    }' "$tmp_dts")
if [ -z "$node" ]; then
    echo "× 编译出的设备树里没有 compatible = \"h3c,fmcs\" 节点，FTTR 驱动没有可绑定的对象。"
    exit 1
fi

have=$(printf '%s\n' "$node" | grep -oE '[A-Za-z0-9_-]+-gpios' | sort -u)

# 驱动实际请求的 con_id 来自 feeds/hm2004/original/driver 里的源码。
# 两种写法都要认：fmcs_load.c 走本地封装 fmcs_bitstream_get_gpio(dev, "clk", ...)，
# fmcs_spi.c 走 devm_gpiod_get_optional(t->dev, "sck", ...)——第一个参数不是 dev，
# 早先按字面量 "dev," 匹配会把位敲那四条线整个漏掉。
driver_dir="$BUILD_DIR/feeds/hm2004/original/driver"
if [ ! -d "$driver_dir" ]; then
    echo "× 找不到驱动源码目录：$driver_dir" >&2
    exit 1
fi
want=$(grep -ohE '(gpiod_get[a-z_]*|get_gpio)\([^,]+,[[:space:]]*"[a-z0-9-]+"' "$driver_dir"/*.c 2>/dev/null |
    grep -oE '"[a-z0-9-]+"' | tr -d '"' | sed 's/$/-gpios/' | sort -u)

if [ -z "$want" ]; then
    echo "× 从驱动源码里没解析出任何 GPIO con_id，判据本身失效了（feed 的写法可能变了）。" >&2
    exit 1
fi

echo "驱动要的 GPIO 线 ：$(printf '%s ' $want)"
echo "设备树给的 GPIO 线：$(printf '%s ' $have)"

missing=""
for w in $want; do
    if ! printf '%s\n' "$have" | grep -qx "$w"; then
        missing="$missing $w"
    fi
done

if [ -n "$missing" ]; then
    echo
    echo "× FTTR 运行时门禁失败：设备树缺以下线"
    # 这里必须让 $missing 按空格拆开逐行打印，加引号会变成一整行。
    for m in $missing; do echo "    - $m"; done
    echo "  后果（照源码说，不是猜）：con_id 取不到线时 devm_gpiod_get_optional 返回 NULL，"
    echo "  probe 不报错；但 fmcs_spi.c:335 见 sck 为空直接 -ENODEV，而它是 fmcs.c:729"
    echo "  fmcs_probe_common() 的第一步 —— 所以驱动绑不上设备，/dev/fmcs 都不出来。"
    echo "  补齐配置线也只是第一步：寄存器通路（miniolt read/write fpga）走 0x1fa10000 上的"
    echo "  CS1，那个控制器在本树里归 spi-airoha-snfi，原厂用的是它从没实现过的 Manual Mode。"
    echo "  上游自己的话（feed README.md:55-59）：'the GPIO transport pins are not identified"
    echo "  in the stock device tree. Do not enable the FMCS node or apply"
    echo "  original/patches/0001-arm64-dts-airoha-hm2004-du-enable-fmcs.patch until the"
    echo "  transport wiring is resolved for the target kernel and board.'"
    echo "  那份补丁确实给了六个编号（nconfig 5 / rst 22 / clk 29 / data 30 / status 27 /"
    echo "  conf-done 28，由原厂 DTB + fpga_load.ko 里硬编码的 GPIO 位推出来），但作者写明"
    echo "  是推算不是实测，位敲的 sck/mosi/miso/cs 四条它也没给。"
    echo "  这里不自动改设备树：改就是替上游把「未实测」变成「已发布」。"
    echo "  可做的事：先用 with_fttr=false 出 PON+honk 可用的固件；要上 FTTR，得先在真机上"
    echo "  确认这几根脚（含是否与 pon_tx_disable、leds、keys 复用冲突），再往设备树里补。"
    exit 1
fi

echo "√ 驱动请求的 GPIO 线在编译出的设备树里都有"
