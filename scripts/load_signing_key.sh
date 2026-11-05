#!/usr/bin/env bash
# 把签名密钥从 GitHub Secrets 落到源码树里要求的文件名上。
# 需求文档「四、5：使用本地电脑私钥，存入 Secrets，脚本禁止硬编码密钥」。
#
# 文件名不是随口定的，来自 pbs05/ponwrt@03c13454 的 rules.mk:353-355：
#   BUILD_KEY=$(TOPDIR)/key-build                    （usign，签 sysupgrade 元数据）
#   BUILD_KEY_APK_SEC=$(TOPDIR)/private-key.pem      （apk 仓库私钥）
#   BUILD_KEY_APK_PUB=$(TOPDIR)/public-key.pem       （apk 仓库公钥）
# 密钥内容只从环境变量读（由 workflow 步骤显式 env: 映射 Secrets），
# 脚本里没有任何密钥、也不打印密钥。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR=${BUILD_DIR:-$REPO_DIR/action_build}
CFG="$BUILD_DIR/.config"

[ -d "$BUILD_DIR" ] || {
    echo "源码树不存在：$BUILD_DIR" >&2
    exit 1
}

umask 077

need_apk_key=1
need_usign_key=1
if [ -f "$CFG" ]; then
    grep -q '^CONFIG_SIGNED_PACKAGES=y$' "$CFG" || need_apk_key=0
    grep -q '^CONFIG_SIGN_FIRMWARE=y$' "$CFG" || need_usign_key=0
fi

if [ "$need_apk_key" = "1" ]; then
    if [ -z "${APK_SIGNING_PRIVATE_KEY:-}" ]; then
        echo "× 配置要求签 apk 仓库，但 Secrets 里没有 APK_SIGNING_PRIVATE_KEY。" >&2
        echo "  不配的后果：每次构建临时生成新密钥，设备端自托管软件源一升级就验签失败，" >&2
        echo "  换固件还要重装一次信任。这正是「稳定版」要避免的。" >&2
        echo "  在自己电脑上生成一次（EC P-256，OpenWrt apk 签名用的就是它）：" >&2
        echo "    openssl ecparam -name prime256v1 -genkey -noout -out private-key.pem" >&2
        echo "  然后把 private-key.pem 的全文贴进仓库 Secret APK_SIGNING_PRIVATE_KEY。" >&2
        exit 1
    fi
    printf '%s\n' "$APK_SIGNING_PRIVATE_KEY" >"$BUILD_DIR/private-key.pem"
    if ! openssl ec -in "$BUILD_DIR/private-key.pem" -pubout \
        -out "$BUILD_DIR/public-key.pem" 2>/dev/null; then
        echo "× APK_SIGNING_PRIVATE_KEY 不是一把能读出来的 EC 私钥（格式或换行被改坏了）。" >&2
        rm -f "$BUILD_DIR/private-key.pem" "$BUILD_DIR/public-key.pem"
        exit 1
    fi
    # 公钥必须由这把私钥导出——否则装到设备上的公钥和仓库签名对不上。
    derived=$(openssl ec -in "$BUILD_DIR/private-key.pem" -pubout 2>/dev/null |
        openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')
    echo "√ apk 签名密钥就位（公钥指纹 ${derived:0:16}…）"
    if [ -n "${APK_SIGNING_PUBLIC_KEY:-}" ]; then
        printf '%s\n' "$APK_SIGNING_PUBLIC_KEY" >"$BUILD_DIR/public-key.expected.pem"
        expect=$(openssl pkey -pubin -in "$BUILD_DIR/public-key.expected.pem" -outform der 2>/dev/null |
            openssl dgst -sha256 | awk '{print $NF}')
        rm -f "$BUILD_DIR/public-key.expected.pem"
        if [ "$expect" != "$derived" ]; then
            echo "× Secrets 里的 APK_SIGNING_PUBLIC_KEY 与私钥不匹配（$expect != $derived）" >&2
            exit 1
        fi
        echo "√ 公钥与私钥自洽"
    fi
fi

if [ "$need_usign_key" = "1" ]; then
    if [ -z "${USIGN_PRIVATE:-}" ] || [ -z "${USIGN_PUBLIC:-}" ]; then
        # 不拦：Config-build.in 里 SIGN_FIRMWARE 的说明写明「OpenWrt's build
        # infrastructure signs images with temporary keys」，缺 key-build 时构建系统
        # 自己生成一把临时的，镜像照旧带签名，只是每次不同。
        # 真正有后果的是 apk 仓库那把钥匙（设备端软件源信任它），上面已经硬拦过了。
        echo "! 未配置 USIGN_PRIVATE/USIGN_PUBLIC：本次由构建系统临时生成固件签名钥匙，" >&2
        echo "!  换一次编译，sysupgrade 元数据的签名就变一次。要长期用自托管软件源之外的" >&2
        echo "!  固件校验，再补这两个 Secret（本机 usign -G -q -p key-build -d key-build.sec）。" >&2
    else
        if ! printf '%s' "$USIGN_PRIVATE" | base64 -d >"$BUILD_DIR/key-build" 2>/dev/null; then
            echo "× USIGN_PRIVATE 不是合法的 base64（要求单行 base64，不要带换行或空格）。" >&2
            rm -f "$BUILD_DIR/key-build"
            exit 1
        fi
        if ! printf '%s' "$USIGN_PUBLIC" | base64 -d >"$BUILD_DIR/key-build.pub" 2>/dev/null; then
            echo "× USIGN_PUBLIC 不是合法的 base64。" >&2
            rm -f "$BUILD_DIR/key-build" "$BUILD_DIR/key-build.pub"
            exit 1
        fi
        chmod 600 "$BUILD_DIR/key-build"
        if ! grep -q 'untrusted comment' "$BUILD_DIR/key-build.pub" 2>/dev/null; then
            echo "× USIGN_PUBLIC 解出来的内容不像 usign 公钥（首行应是 untrusted comment）。" >&2
            exit 1
        fi
        echo "√ usign 密钥对就位"
    fi
fi

echo "==> 密钥目录状态（只列名字和权限，不打印内容）"
for f in private-key.pem public-key.pem key-build key-build.pub; do
    if [ -f "$BUILD_DIR/$f" ]; then
        printf '  %s  %s\n' "$f" "$(ls -l "$BUILD_DIR/$f" | awk '{print $1}')"
    fi
done
