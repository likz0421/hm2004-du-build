#!/usr/bin/env bash
# 按 pins.env 的 SHA 精确取固件源码树，放进引擎约定的 action_build 目录。
#
# 为什么自己做而不是调引擎的 wrt_core/pre_clone_action.sh：
# 那个脚本只有 `git clone --depth 1 -b 分支`，也就是永远跟分支头走，
# 需求文档「四、3 锁定固定 commit hash」在引擎现状下是没落地的。
#
# 这里刻意不把 HEAD 切成分离状态：引擎 update.sh 的 reset_feeds_conf 会依次做
#   git reset --hard origin/<分支>  →  git pull  →  git clean -f -d  →  git checkout <COMMIT_HASH>
# 只有前三步在「当前就在分支上」时才安全（分离 HEAD 下 git pull 会直接报错），
# 而最后一步会替我们落到 ini 里 pin 的那个 SHA。真正的核验在 assert_prebuild.sh。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

PINS=${PINS:-$REPO_DIR/pins.env}
ENGINE_DIR=${ENGINE_DIR:-$REPO_DIR/engine}
BUILD_DIR=${BUILD_DIR:-$ENGINE_DIR/action_build}

# shellcheck disable=SC1090
. "$PINS"

if [ ! -d "$ENGINE_DIR/.git" ]; then
    echo "先跑 scripts/apply_overlay.sh，引擎工作树还不存在：$ENGINE_DIR" >&2
    exit 1
fi

# ini 里的 COMMIT_HASH 必须与 pins.env 一致，否则源码树会跟着分支头漂。
grep -q "^COMMIT_HASH=$PONWRT_SHA$" "$ENGINE_DIR/wrt_core/compilecfg/$BUILD_TARGET.ini" || {
    echo "引擎 ini 的 COMMIT_HASH 与 pins.env 不一致，overlay 没生效" >&2
    exit 1
}

if [ -d "$BUILD_DIR/.git" ]; then
    echo "==> 源码树已存在，复用：$BUILD_DIR"
else
    echo "==> 克隆 $PONWRT_REPO 分支 $PONWRT_BRANCH"
    git clone --depth 1 -c credential.helper= -b "$PONWRT_BRANCH" "$PONWRT_REPO" "$BUILD_DIR"
fi

echo "==> fetch pin 住的提交 $PONWRT_SHA"
git -C "$BUILD_DIR" fetch --depth 1 origin "$PONWRT_SHA"

if ! git -C "$BUILD_DIR" cat-file -e "$PONWRT_SHA^{commit}" 2>/dev/null; then
    echo "pin 的提交在源码树里取不到：$PONWRT_SHA（$PONWRT_REPO/$PONWRT_BRANCH）" >&2
    echo "可能是提交已被 force-push 掉，或 pins.env 写错了仓库。" >&2
    exit 1
fi

# 分支头与 pin 的关系写进日志，方便一眼看出落后了多少。
tip=$(git -C "$BUILD_DIR" rev-parse "origin/$PONWRT_BRANCH")
if [ "$tip" = "$PONWRT_SHA" ]; then
    echo "==> pin 就是 $PONWRT_BRANCH 分支头"
else
    echo "==> 分支头 $tip，pin $PONWRT_SHA（构建后仍会校验实际编译的是 pin 那个）"
fi

# 与引擎 pre_clone_action.sh 一致的两件小事：去掉国内镜像源、写缓存用的 repo_flag。
mirrors="$BUILD_DIR/scripts/projectsmirrors.json"
if [ -f "$mirrors" ]; then
    sed -i '/.cn\//d; /tencent/d; /aliyun/d' "$mirrors"
    echo "==> 已从 projectsmirrors.json 移除国内镜像"
fi
printf '%s/%s\n' "$PONWRT_REPO" "$PONWRT_BRANCH" >"$ENGINE_DIR/repo_flag"

echo "==> 源码树准备完成，HEAD=$(git -C "$BUILD_DIR" rev-parse HEAD)"
