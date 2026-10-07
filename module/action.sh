#!/bin/sh
# OpenSesame 操作按钮 (管理器里点击执行)
# 未加载 -> 加载当前 WebUI 已开启的校验放行功能
# 已加载 -> 卸载 (还原内核)
# 开机自启开关由 WebUI 单独控制，不受本按钮影响。

MODDIR="${0%/*}"
exec sh "$MODDIR/control.sh" toggle
