#!/usr/bin/env bash
# 官方 FTTR 那一套现在到底能不能拿到、拿到了还差什么——探一遍，把话说明白。
#
# 为什么要这道闸：文档里的 fttr 指的是 LazuliKao 的官方插件，不是逆向重写的那套。
# 上游 wrt_release@8a930846 的 recipe（wrt_core/recipes/h3c-hm2004-du_fttr/recipe.json）
# 写得很具体：importPackagesRegistry 要 luci-app-fttr 和 openwrt-fttr 两个仓库，
# importPackages 从 openwrt-fttr 取 h3c-fmcs / h3c-fmcs-firmware / h3c-fttr-tools，
# 从 luci-app-fttr 取 package/luci-app-fttr；configs 里开四个包
# （kmod-h3c-fmcs、h3c-fmcs-firmware、h3c-fttr-tools、luci-app-fttr）。
# 那个 recipe 在引擎里是 enabled:false —— 只有 ini 把它列进 ADD_RECIPES 才生效。
# 所以「fttr 开源了吗」这个问题有四个可查证的事实点，逐个查，别听转述。
#
# 私钥/令牌只走环境变量与临时 netrc（0600，退出即删），不进命令行、不进日志、不进提交。
set -uo pipefail

PINS=${PINS:-$(dirname "$0")/../pins.env}
[ -f "$PINS" ] || { echo "× 读不到 pins.env：$PINS" >&2; exit 1; }
# shellcheck disable=SC1090
. "$PINS"

BACKEND_REPO=${OFFICIAL_FTTR_BACKEND_REPO:-LazuliKao/openwrt-fttr}
APP_REPO=${OFFICIAL_FTTR_APP_REPO:-LazuliKao/luci-app-fttr}
# 官方 recipe 需要的包，少一个都编不出「能用的 fttr」
backend_pkgs="h3c-fmcs h3c-fmcs-firmware h3c-fttr-tools"
FTTR_TOKEN=${FTTR_TOKEN:-}

# 两个开关不能同时开：官方那套（h3c-fmcs / h3c-fttr-tools）与公开 feed 那套
# （kmod-fttr-fmcs / fttr-tools）是同一个 FPGA 的两套实现。官方源码看不到，
# 所以「能不能共存」这种事没人能替我保证 —— 只许选一套。
if [ "${WITH_FEED:-0}" = 1 ]; then
    echo "× with_official_fttr 和 with_fttr 同时开了。这两套是同一个 FMCS FPGA 的两个实现，" >&2
    echo "  包名不同（h3c-fmcs vs kmod-fttr-fmcs、h3c-fttr-tools vs fttr-tools），共存冲突没法验证" >&2
    echo "  （官方那套源码至今私有）。关掉其中一个再跑。" >&2
    exit 1
fi

say() { printf '%s\n' "$*"; }

# 探仓库可见性用 HTTP 状态码，不用 git ls-remote：
# 私有/不存在的仓库会让 git 弹一个看不见的凭证输入框，然后挂死（本机踩过两次，各 300 秒）。
probe_repo() {
    local repo=$1 authed=$2 code
    if [ "$authed" = 1 ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' -n --netrc-file "$NETRC" \
            "https://api.github.com/repos/$repo" 2>/dev/null)
    else
        code=$(curl -s -o /dev/null -w '%{http_code}' "https://api.github.com/repos/$repo" 2>/dev/null)
    fi
    case "$code" in
        200) say "public" ;;
        404) say "private-or-missing" ;;
        401 | 403) say "auth-rejected" ;;
        "" ) say "transport-error" ;;
        *) say "http-$code" ;;
    esac
}

NETRC=$(mktemp)
chmod 600 "$NETRC"
cleanup() { rm -f "$NETRC"; }
trap cleanup EXIT
if [ -n "$FTTR_TOKEN" ]; then
    printf 'machine api.github.com login x-access-token password %s\n' "$FTTR_TOKEN" >"$NETRC"
fi

# 缺口清单里带中文、带括号、带空格，必须用数组攒，字符串拼接会被词分割成碎块。
gaps=()
notes=()

be_anon=$(probe_repo "$BACKEND_REPO" 0)
be="anon:$be_anon"
if [ "$be_anon" != "public" ] && [ -n "$FTTR_TOKEN" ]; then
    be_auth=$(probe_repo "$BACKEND_REPO" 1)
    be="$be_anon+token:$be_auth"
    [ "$be_auth" = "public" ] && be_ok=1 || be_ok=0
else
    [ "$be_anon" = "public" ] && be_ok=1 || be_ok=0
fi
say "后端仓库 $BACKEND_REPO ：$be"

if [ "$be_ok" = 1 ]; then
    # 光有仓库还不够：recipe 按路径 import 三个包，包里必须有 Makefile。
    auth=()
    [ -n "$FTTR_TOKEN" ] && [ "$be_anon" != "public" ] && auth=(-n --netrc-file "$NETRC")
    tree=$(curl -s "${auth[@]}" \
        "https://api.github.com/repos/$BACKEND_REPO/git/trees/HEAD?recursive=1" 2>/dev/null)
    for p in $backend_pkgs; do
        if ! printf '%s' "$tree" | grep -q "\"path\":\"$p/Makefile\""; then
            gaps+=("$BACKEND_REPO:$p/Makefile")
        fi
    done
else
    gaps+=("后端仓库不可公开取用（$BACKEND_REPO）")
    [ -z "$FTTR_TOKEN" ] && notes+=("有令牌就设 Secrets 里的 FTTR_TOKEN（本脚本只从环境变量读，绝不打印）")
fi

app=$(probe_repo "$APP_REPO" 0)
say "界面仓库 $APP_REPO ：$app"
if [ "$app" = "public" ]; then
    app_sha=$(curl -s "https://api.github.com/repos/$APP_REPO/git/ref/heads/main" 2>/dev/null |
        sed -n 's/.*"sha"[: ]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
    say "  main HEAD：${app_sha:-取不到}"
    [ -n "${OFFICIAL_FTTR_APP_SHA:-}" ] && [ -n "$app_sha" ] && [ "$app_sha" != "$OFFICIAL_FTTR_APP_SHA" ] &&
        say "  ! pins.env 锁的是 $OFFICIAL_FTTR_APP_SHA，上游已经走到 $app_sha"
    # README 声称"生成的 LuCI JS 已提交进包目录，所以打 OpenWrt 包不需要 Node"，
    # 但仓库里 package/luci-app-fttr/ 只有 po/ 与 root/，没有 Makefile 也没有 htdocs
    # ——AGENTS.md 自己写明 htdocs 是「local build output ignored by Git」。
    app_tree=$(curl -s "https://api.github.com/repos/$APP_REPO/git/trees/main?recursive=1" 2>/dev/null)
    printf '%s' "$app_tree" | grep -q '"path":"package/luci-app-fttr/Makefile"' ||
        gaps+=("$APP_REPO 的 package/luci-app-fttr/Makefile（上游 recipe 要 import 这个目录，可里面没有 Makefile，它就不是个包）")
    printf '%s' "$app_tree" | grep -q '"path":"package/luci-app-fttr/htdocs/' ||
        gaps+=("$APP_REPO 里没有已构建的 htdocs（README 那句「打 OpenWrt 包不需要 Node」与仓库现状不符，AGENTS.md 写明 htdocs 是被 gitignore 的本地产物）")
else
    gaps+=("界面仓库不可取用（$APP_REPO）")
fi

say
if [ "${#gaps[@]}" -gt 0 ]; then
    say "× 官方 FTTR 现在装不出来，缺："
    for g in "${gaps[@]}"; do say "    - $g"; done
    say "  这条路的运行时契约（不是编译依赖，装上也不等于能用）：界面调的是名为 fttr 的"
    say "  ubus 对象（ACL 里列了 24 个方法）与 UCI 的 fttr 段，两者都由 h3c-fttr-tools 里的"
    say "  fttrd 提供；它属于上面那个拿不到的后端仓库。"
    say "  所以现在能公开用的 fttr 只有逆向重写的那一套（rayniel/openwrt-hm2004-feed），"
    say "  它的缺口在设备树 GPIO 与 FPGA 寄存器通路，见 scripts/check_fttr_dts.sh 与 README 第 6 节。"
    for n in "${notes[@]}"; do say "  提示：$n"; done
    exit 1
fi

say "√ 官方 FTTR 的仓库与包都在，可以走 with_official_fttr：把 recipe 的四个包接进 ini"
say "  注意还是一次「装得上」的验证，运行时能不能用要按 acl.d 里那 24 个 ubus 方法在真机上核。"
