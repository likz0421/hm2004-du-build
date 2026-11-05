; 由 scripts/apply_overlay.sh 用 pins.env 里的值替换 @占位符@ 后，
; 覆盖到引擎的 wrt_core/compilecfg/lk_h3c_hm2004_du.ini。
; 与上游同名文件的差异全部由 apply_overlay.sh 打印进 CI 日志。

REPO_URL=@PONWRT_REPO@
REPO_BRANCH=@PONWRT_BRANCH@
; 需求文档「四、3」的落地点：上游 ini 从来不填这一行，等于每次构建都跟着分支头走。
; 填了之后 CI 会按这个 SHA fetch，并在构建后从产物版本号反查，对不上就失败。
COMMIT_HASH=@PONWRT_SHA@

BUILD_DIR=ponwrt-an7581
CONFIG_FRAGMENTS=proxy,ebpf_btf,honk@FTTR_FRAG@
RECIPE_SET=mini
TARGET_TAGS=an7581
; disable_initramfs 被移出了 ADD_RECIPES 并放进 DISABLE_RECIPES：
; 那个 recipe 在 pre_defconfig 阶段往 .config 追加 CONFIG_TARGET_ROOTFS_INITRAMFS=n，
; 写得比设备配置和片段都晚，于是 -recovery.itb 直接不产出（实测构建 42116233200 就这样）。
; recipe 的意图是「加快编译、省空间」，与需求文档「四、4 要救砖完整固件」相冲，
; 这里按文档优先。sysupgrade.itb 的内容不受这项影响，多出来的只是一个独立镜像。
ADD_RECIPES=airoha_an7581,luci_app_airoha_npu,feed_pins,ebpf_btf,honk,disable_mosdns@FTTR_ADD@
DISABLE_RECIPES=luci_app_cpu_temp_status,tailscale_awg,disable_initramfs
