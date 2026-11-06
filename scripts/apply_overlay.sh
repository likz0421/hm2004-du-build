#!/usr/bin/env bash
# 把本工程 overlay/ 里的东西盖到引擎工作树上，并把差异完整打进日志。
#
# 为什么不 fork 引擎仓库：需求文档要求「以 LazuliKao/wrt_release 为基底」，
# 而 fork 会把作者的个人配置一起带过来、上游更新也看不见。这里的做法是
# 按 SHA 取引擎，然后只覆盖我们这几个文件，diff 就是本仓库真正的改动量。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

PINS=${PINS:-$REPO_DIR/pins.env}
ENGINE_DIR=${ENGINE_DIR:-$REPO_DIR/engine}
WITH_FTTR=${WITH_FTTR:-1}

# shellcheck disable=SC1090
. "$PINS"

FTTR_ADD=""
FTTR_FRAG=""
if [ "$WITH_FTTR" = "1" ]; then
    FTTR_ADD=",hm2004_fttr_feed,h3c-hm2004-du_fttr"
    FTTR_FRAG=",fttr"
fi

if [ ! -d "$ENGINE_DIR/.git" ]; then
    echo "==> 取引擎 $ENGINE_REPO @ $ENGINE_SHA"
    git clone --depth 1 "$ENGINE_REPO" "$ENGINE_DIR"
    git -C "$ENGINE_DIR" fetch --depth 1 origin "$ENGINE_SHA"
    git -C "$ENGINE_DIR" checkout --detach --quiet "$ENGINE_SHA"
fi

# 先确认引擎就是我们以为的那一个版本，再往上盖东西。
actual_engine=$(git -C "$ENGINE_DIR" rev-parse HEAD)
if [ "$actual_engine" != "$ENGINE_SHA" ]; then
    echo "引擎 HEAD 不是 pin 的 SHA：期望 $ENGINE_SHA，实际 $actual_engine" >&2
    exit 1
fi

WT="$ENGINE_DIR/wrt_core"

echo "==> 生成 compilecfg/$BUILD_TARGET.ini"
sed -e "s|@PONWRT_REPO@|$PONWRT_REPO|g" \
    -e "s|@PONWRT_BRANCH@|$PONWRT_BRANCH|g" \
    -e "s|@PONWRT_SHA@|$PONWRT_SHA|g" \
    -e "s|@FTTR_ADD@|$FTTR_ADD|g" \
    -e "s|@FTTR_FRAG@|$FTTR_FRAG|g" \
    "$REPO_DIR/overlay/compilecfg/lk_h3c_hm2004_du.ini.tpl" \
    >"$WT/compilecfg/$BUILD_TARGET.ini"

echo "==> 覆盖 deconfig 与片段"
cp "$REPO_DIR/overlay/deconfig/lk_h3c_hm2004_du.config" \
   "$WT/deconfig/$BUILD_TARGET.config"
for frag in ebpf_btf honk fttr; do
    cp "$REPO_DIR/overlay/deconfig/fragments/$frag.config" \
       "$WT/deconfig/fragments/$frag.config"
done

echo "==> 安装 recipe（先删上游同名目录，避免留下没引用的旧文件）"
for r in ebpf_btf honk hm2004_fttr_feed h3c-hm2004-du_fttr feed_pins vantage_feed luci_theme_vantage; do
    rm -rf "$WT/recipes/$r"
    cp -R "$REPO_DIR/overlay/recipes/$r" "$WT/recipes/$r"
done

# feed_pins 在构建期只认 recipe 目录里的那份清单；这里把根目录的 pins.feeds
# 复制过去，并当场比对，杜绝两份清单各说各话。
cp "$REPO_DIR/pins.feeds" "$WT/recipes/feed_pins/pins.feeds"
cmp -s "$REPO_DIR/pins.feeds" "$WT/recipes/feed_pins/pins.feeds" || {
    echo "pins.feeds 复制后不一致" >&2
    exit 1
}
# recipe.json 里的 @占位符@ 在这里渲染。分隔符用 |，因为 URL 里有冒号。
for entry in "honk|@HONK_FEED_URL@|@HONK_SHA@|$HONK_FEED_URL|$HONK_SHA" \
    "hm2004_fttr_feed|@FTTR_FEED_URL@|@FTTR_SHA@|$FTTR_FEED_URL|$FTTR_SHA" \
    "vantage_feed|@VANTAGE_FEED_URL@|@VANTAGE_SHA@|$VANTAGE_FEED_URL|$VANTAGE_SHA"; do
    IFS='|' read -r rdir ph_url ph_sha real_url real_sha <<EOF
$entry
EOF
    f="$WT/recipes/$rdir/recipe.json"
    if [ ! -f "$f" ]; then
        echo "要渲染的 recipe 不存在：$f" >&2
        exit 1
    fi
    sed -e "s|$ph_url|$real_url|g" -e "s|$ph_sha|$real_sha|g" "$f" >"$f.tmp" || {
        echo "占位符替换失败：$f" >&2
        exit 1
    }
    mv "$f.tmp" "$f"
    # 替换没生效就是模板或变量名写串了，当场失败，而不是把 @占位符@ 带进构建。
    if grep -q '@' "$f"; then
        echo "recipe.json 里还留着占位符：$f" >&2
        grep -n '@' "$f" >&2
        exit 1
    fi
done
chmod +x "$WT/recipes/h3c-hm2004-du_fttr/apply.sh"

echo "==> 检查该盖上的文件真的盖上了"
for f in \
    "compilecfg/$BUILD_TARGET.ini" \
    "deconfig/$BUILD_TARGET.config" \
    "deconfig/fragments/ebpf_btf.config" \
    "deconfig/fragments/honk.config" \
    "deconfig/fragments/fttr.config" \
    "recipes/ebpf_btf/recipe.json" \
    "recipes/ebpf_btf/files/airoha_an7581_ebpf.config" \
    "recipes/honk/recipe.json" \
    "recipes/hm2004_fttr_feed/recipe.json" \
    "recipes/feed_pins/recipe.json" \
    "recipes/feed_pins/apply.sh" \
    "recipes/feed_pins/pins.feeds" \
    "recipes/vantage_feed/recipe.json" \
    "recipes/luci_theme_vantage/recipe.json" \
    "recipes/luci_theme_vantage/configs/vantage.config" \
    "recipes/h3c-hm2004-du_fttr/recipe.json" \
    "recipes/h3c-hm2004-du_fttr/apply.sh"; do
    if [ ! -f "$WT/$f" ]; then
        echo "overlay 文件缺失：wrt_core/$f" >&2
        exit 1
    fi
done

# ini 里的 SHA 必须和 pins.env 一致，否则就是模板漏替换或者写串了。
grep -q "^COMMIT_HASH=$PONWRT_SHA$" "$WT/compilecfg/$BUILD_TARGET.ini" || {
    echo "ini 里的 COMMIT_HASH 与 pins.env 不一致" >&2
    exit 1
}
grep -q "$HONK_SHA" "$WT/recipes/honk/recipe.json" || {
    echo "honk recipe 里的 feed SHA 与 pins.env 不一致" >&2
    exit 1
}
if [ "$WITH_FTTR" = "1" ]; then
    grep -q "$FTTR_SHA" "$WT/recipes/hm2004_fttr_feed/recipe.json" || {
        echo "fttr recipe 里的 feed SHA 与 pins.env 不一致" >&2
        exit 1
    }
fi

# recipe.json 必须符合引擎自己的 schema 校验入口，坏 JSON 在这里就拦掉。
if command -v jq >/dev/null 2>&1; then
    for r in ebpf_btf honk hm2004_fttr_feed h3c-hm2004-du_fttr feed_pins vantage_feed luci_theme_vantage; do
        jq -e . "$WT/recipes/$r/recipe.json" >/dev/null || {
            echo "recipe.json 不是合法 JSON：$r" >&2
            exit 1
        }
    done
fi

echo "==> 本工程相对引擎的全部改动（同时写入 overlay.diff 供归档）"
# 新文件不在 git diff 里，所以先全部 add 再看 --cached；这个 clone 只存在于
# 构建机本地，不会推回任何地方。
git -C "$ENGINE_DIR" add -A >/dev/null
git -C "$ENGINE_DIR" diff --cached >"$REPO_DIR/overlay.diff" 2>&1 || true
git -C "$ENGINE_DIR" diff --cached --stat || true
echo "差异明细已存到 $REPO_DIR/overlay.diff"
echo "==> overlay 应用完成（WITH_FTTR=$WITH_FTTR）"
