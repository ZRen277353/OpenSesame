#!/bin/sh
# 模块被卸载时执行: 若补丁仍在内核中, rmmod 会还原 same_magic() 原始指令
MODDIR="${0%/*}"
if grep -q opensesame /proc/modules 2>/dev/null; then
	rmmod opensesame 2>/dev/null
fi
exit 0
