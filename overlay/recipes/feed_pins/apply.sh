#!/usr/bin/env bash
# 把 pins.feeds 里的 7 个 feed 锁到指定 commit。
#
# 为什么用脚本而不是 recipe 的 addFeeds/removeFeeds：引擎那两个动作只认
# get_feeds_path 返回的其中一个文件（feeds.conf 优先，否则 feeds.conf.default）。
# 构建树里同时存在两份时，改了一份、scripts/feeds 读的是另一份，锁版本会静默失效。
# 这里对存在的两份都改，改完立即自检。
set -eu

BUILD_DIR=${BUILD_DIR:?BUILD_DIR 未由 recipe.sh 注入}
RECIPE_DIR=${RECIPE_DIR:?RECIPE_DIR 未由 recipe.sh 注入}
PINS_FEEDS=${PINS_FEEDS:-$RECIPE_DIR/pins.feeds}

[ -f "$PINS_FEEDS" ] || {
    echo "feed 锁版本清单不存在：$PINS_FEEDS" >&2
    exit 1
}

targets=()
for f in "$BUILD_DIR/feeds.conf" "$BUILD_DIR/feeds.conf.default"; do
    [ -f "$f" ] && targets+=("$f")
done
if [ "${#targets[@]}" -eq 0 ]; then
    echo "× 源码树里没有 feeds.conf 也没有 feeds.conf.default，无法锁版本。" >&2
    exit 1
fi

while read -r name url sha; do
    case "$name" in '' | '#'*) continue ;; esac
    # 40 位十六进制才认；写错成分支名就当场失败，不让它静默变成不锁。
    if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
        echo "× $name 的 SHA 不是 40 位十六进制：$sha" >&2
        exit 1
    fi
    for f in "${targets[@]}"; do
        if grep -qE "^[[:space:]]*src-git[[:space:]]+$name([[:space:]]|$)" "$f"; then
            sed -i -E "s|^[[:space:]]*src-git[[:space:]]+$name[[:space:]].*|src-git $name $url^$sha|" "$f"
        else
            # 上游把这个 feed 删了/改名了：直接补一行，但要说出来，别默默多一个源。
            echo "! 上游文件里没有 $name，已补上锁版本的一行（请确认是不是 feed 改名了）" >&2
            printf 'src-git %s %s^%s\n' "$name" "$url" "$sha" >>"$f"
        fi
    done
done <"$PINS_FEEDS"

# 自检：每个名字在每个文件里都必须是带 ^<sha> 的形式。
for f in "${targets[@]}"; do
    while read -r name url sha; do
        case "$name" in '' | '#'*) continue ;; esac
        if ! grep -qE "^src-git[[:space:]]+$name[[:space:]]+${url}\^${sha}\$" "$f"; then
            echo "× 自检失败：$f 里 $name 不是锁版本的形式" >&2
            grep -nE "src-git[[:space:]]+$name" "$f" >&2 || true
            exit 1
        fi
    done <"$PINS_FEEDS"
    echo "√ $(basename "$f")：7 个 feed 已全部锁到 pins.feeds 的 commit"
done
