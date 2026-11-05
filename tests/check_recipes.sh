#!/usr/bin/env bash
# 用引擎自己的校验器验我们的 recipe.json，而不是自己重写一份判据。
#
# 判据从 wrt_core/recipe.sh 里原样抽出（recipe_validate_structure 的 jq 程序，
# 以及 RECIPE_PHASES 数组）。自己另写一套「看着像」的校验，会出现测试一直绿、
# 真构建一直炸的情况。
#
# 额外拦两个引擎本身不拦、但会静默失效的点：
#   1) phase 拼错：引擎只校验「是个非空字符串」，不在 RECIPE_PHASES 里的 phase
#      不会被任何阶段执行——recipe 等于没写，而且不报错。
#   2) when.targets 与目标名不符：会被计划器直接过滤掉，同样静默。
#
# 跑法：ENGINE_DIR=<引擎目录> ./tests/check_recipes.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ENGINE_DIR=${ENGINE_DIR:-$REPO_DIR/engine}
RS="$ENGINE_DIR/wrt_core/recipe.sh"

status=0
fail() {
    echo "× $*" >&2
    status=1
}

if [ ! -f "$RS" ]; then
    echo "找不到引擎的 wrt_core/recipe.sh：$RS（先跑 scripts/apply_overlay.sh 或用 ENGINE_DIR 指定）" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "本机没有 jq，无法跑引擎校验器。" >&2
    exit 1
fi

# shellcheck disable=SC1091
. "$REPO_DIR/pins.env"

# ---- 抽引擎的 jq 校验程序 ----
prog=$(awk '
    !start && /^    jq -e '\''$/ { start = 1; next }
    start && /"\$file" >\/dev\/null/ { exit }
    start { gsub(//, ""); print }
' "$RS")
[ -n "$prog" ] || fail "没能从 $RS 里抽出校验程序，去看 recipe_validate_structure"
if [ "$(printf '%s\n' "$prog" | wc -l)" -lt 20 ]; then
    fail "抽出的校验程序只有 $(printf '%s\n' "$prog" | wc -l) 行，明显不完整，拒绝用它判定"
fi

# ---- 抽引擎认识的阶段名 ----
phases=$(awk '
    !start && /^RECIPE_PHASES=\($/ { start = 1; next }
    start && /^\)/ { exit }
    start { gsub(/\r/, ""); gsub(/^[[:space:]]+/, ""); print }
' "$RS")
if [ -z "$phases" ]; then
    fail "没能从 $RS 里抽出 RECIPE_PHASES"
fi
echo "引擎认识的阶段：$(printf '%s ' $phases)"

# ---- 逐个验我们的 recipe ----
for r in ebpf_btf honk hm2004_fttr_feed h3c-hm2004-du_fttr; do
    f="$REPO_DIR/overlay/recipes/$r/recipe.json"
    recipe_ok=1
    if [ ! -f "$f" ]; then
        fail "缺文件：$f"
        continue
    fi
    if ! jq -e "$prog" "$f" >/dev/null; then
        fail "$r 结构不合法（引擎判据）"
        jq -e "$prog" "$f" >&2 || true
        continue
    fi

    phase=$(jq -r '.phase' "$f" | tr -d '\r')
    if ! printf '%s\n' "$phases" | grep -qx "$phase"; then
        fail "$r 的 phase「$phase」不在引擎的阶段列表里，这个 recipe 永远不会被执行"
        continue
    fi

    want_target=$(jq -r '.when.targets[]?' "$f" | tr -d '\r' | head -1)
    if [ -n "$want_target" ] && [ "$want_target" != "$BUILD_TARGET" ]; then
        fail "$r 的 when.targets 是「$want_target」，与 pins.env 的 BUILD_TARGET「$BUILD_TARGET」不符，会被计划器过滤掉"
        continue
    fi

    # 引用的文件动作必须真存在，否则引擎在构建中途才 recipe_die。
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        if [ ! -f "$REPO_DIR/overlay/recipes/$r/$src" ]; then
            fail "$r 引用了不存在的文件：$src"
            recipe_ok=0
        fi
    done < <(jq -r '.actions.files[]?.source' "$f" | tr -d '\r')

    # script 动作同理。
    while IFS= read -r sc; do
        [ -n "$sc" ] || continue
        if [ ! -f "$REPO_DIR/overlay/recipes/$r/$sc" ]; then
            fail "$r 引用了不存在的脚本：$sc"
            recipe_ok=0
        fi
    done < <(jq -r '.actions.script // empty' "$f" | tr -d '\r')

    [ "$recipe_ok" = "1" ] && echo "√ $r：结构合法、phase=$phase 可执行、目标匹配、引用文件齐全"
done

# ---- 反向自测：这套判据得真的会拒东西 ----
bad=$(mktemp)
trap 'rm -f "$bad"' EXIT

printf '{"name":"x","description":"d","enabled":"yes","phase":"post_clone","depends":[],"conflicts":[],"tags":[],"when":{"targets":[],"repo":[],"branch":[],"tags":[]},"actions":{"addFeeds":[],"removeFeeds":[],"importPackages":[],"removePackageDirs":[],"patches":[],"files":[],"configs":[],"script":null}}\n' >"$bad"
if jq -e "$prog" "$bad" >/dev/null 2>&1; then
    fail "jq 判据失效：enabled 不是布尔值也放行了"
else
    echo "√ 判据有效：非法 enabled 类型被拒绝"
fi

printf '{"name":"x","description":"d","enabled":true,"phase":"post_feeds_install","depends":[],"conflicts":[],"tags":[],"when":{"targets":[],"repo":[],"branch":[],"tags":[]},"actions":{"addFeeds":[],"removeFeeds":[],"importPackages":[],"removePackageDirs":[],"patches":[],"files":[],"configs":[],"script":null}}\n' >"$bad"
badphase=$(jq -r '.phase' "$bad")
if printf '%s\n' "$phases" | grep -qx "$badphase"; then
    : # 这个 phase 是合法的，换一种非法的
    badphase="definitely_not_a_phase"
fi
if printf '%s\n' "$phases" | grep -qx "$badphase"; then
    fail "阶段判据失效：$badphase 竟被认为是合法阶段"
else
    echo "√ 阶段判据有效：非法 phase 被拒绝"
fi

exit "$status"
