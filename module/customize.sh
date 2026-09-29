#!/bin/sh
# OpenSesame 安装脚本 (KernelSU/SakiSU 兼容 Magisk 风格安装环境)

if [ "$ARCH" != "arm64" ]; then
	abort "! 仅支持 arm64 设备"
fi

ui_print "- OpenSesame: 放行 vermagic 校验不通过的模块"
ui_print "- 支持 arm64 GKI: 5.10/5.15/6.1/6.6/6.12 各 KMI (一体包自动匹配)"
ui_print "- 要求 kallsyms 保留 same_magic 符号"
ui_print "-   不确定请先用仓库 scripts/probe.sh 自测"
ui_print "- 安装后默认不自动加载, 不改内核"
ui_print "- 请在管理器中点击本模块的『操作』按钮手动启用"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/action.sh"  0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/common.sh"  0 0 0755
set_perm "$MODPATH/opensesame.ko" 0 0 0644
