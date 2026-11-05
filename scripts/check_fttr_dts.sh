#!/usr/bin/env bash
# 检查编译出来的 DTB 里 fmcs 节点，是否给了驱动真正要的 GPIO 线。
#
# 为什么要单独立一道闸：这一条不影响编译，只影响 fttr 到底能不能用。
# 驱动（rayniel/openwrt-hm2004-feed@19135e79 的 original/driver/fmcs_load.c:300-315）
# 按 con_id 取线，也就是要 clk-gpios / data-gpios / nconfig-gpios / rst-gpios /
# status-gpios / conf-done-gpios；而 pbs05/ponwrt 的
# target/linux/airoha/dts/an7581-hm2004-du.dts 写的是 fpga-clk-gpios /
# fpga-data-gpios 这种带前缀的名字，con_id 变成 fpga-clk —— 名字对不上，
# probe 时拿不到线，位流加载不了。kmod 编出来了也不等于 fttr 可用。
#
# 输入用「这次构建真正产出的 DTB」，不是仓库里的 .dts 文本，避免审的和发的不是一份。
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

dtb=""
for d in "$BUILD_DIR"/build_dir/target-*/linux-airoha_an7581/linux-*/arch/arm64/boot/dts/airoha/"$DTS_NAME".dtb; do
    [ -f "$d" ] && dtb=$d
done
if [ -z "$dtb" ]; then
    echo "× 找不到编译出的 DTB：*arch/arm64/boot/dts/airoha/$DTS_NAME.dtb" >&2
    exit 1
fi

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
driver_dir="$BUILD_DIR/feeds/hm2004/original/driver"
if [ ! -d "$driver_dir" ]; then
    echo "× 找不到驱动源码目录：$driver_dir" >&2
    exit 1
fi
want=$(grep -ohE 'get_gpio\(dev, "[a-z0-9-]+"|gpiod_get_optional\(dev, "[a-z0-9-]+"' "$driver_dir"/*.c 2>/dev/null |
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
    echo "× FTTR 运行时门禁失败：设备树缺以下线$(printf '%s\n' "$missing" | sed 's/^/    - /')"
    echo "  后果：kmod-fttr-fmcs 能编出来、能装上，但 probe 时取不到 FPGA 的配置线，"
    echo "  位流加载和 M-OLT 功能不可用。这不是编译问题，是硬件接线还没确认。"
    echo "  上游作者自己的话（original/docs/NEXT_STEPS.md）：'The physical GPIO transport"
    echo "  pins have not been identified on the HM2004-DU and must be validated before use.'"
    echo "  可做的事：先用 with_fttr=false 出 PON+honk 可用的固件；要上 FTTR，"
    echo "  得先在真机上确认 FPGA 配置脚的 GPIO 编号，再往设备树里补 *-gpios。"
    exit 1
fi

echo "√ 驱动请求的 GPIO 线在编译出的设备树里都有"
