#!/bin/sh
# OpenSesame 操作按钮 (管理器里点击执行)
# 未加载 -> 加载 + 启用开机自动加载
# 已加载 -> 卸载 (还原内核) + 关闭自动加载

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

if loaded; then
	rmmod "$MODNAME" 2>/dev/null || $BB rmmod "$MODNAME" 2>/dev/null
	if loaded; then
		echo "卸载失败, 详见内核日志"
	else
		rm -f "$MODDIR/verified"
		echo "已卸载, 内核补丁已还原, 自动加载已关闭"
	fi
	exit 0
fi

echo "== OpenSesame 手动加载 =="
echo "(首次会自动学习本机 vermagic 并回写, 失败一次属正常)"
echo
if load_ko; then
	# 重置熔断计数
	echo 0 > "$MODDIR/failcount"
	rm -f "$MODDIR/attempt" "$MODDIR/stable"
	touch "$MODDIR/verified"
	echo
	echo "加载成功, vermagic 放行已生效, 开机自动加载已启用"
	echo "(再次点击本按钮可卸载并关闭)"
	echo "---- 内核日志 ----"
	dmesg | tail -n 5
else
	echo
	echo "加载失败, 未启用自动加载 —— 请把下面的日志发给项目仓库 issue"
	echo "---- 内核日志 ----"
	dmesg | tail -n 20
fi
