#!/bin/sh
# 开机自动加载: 仅在 verified 标记存在时执行 (默认关闭, 由 action.sh 启用)
# 防卡死设计: 连续 2 次加载后 60 秒内系统未稳定 => 熔断, 不再自动加载

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

[ -f "$MODDIR/verified" ] || exit 0
loaded && exit 0

(
	# 等系统基本就绪再动内核, panic 也发生在开机末尾, 代价最小
	sleep 20

	acquire_lock || exit 0

	# 上一轮有 attempt 却没有 stable => 上次加载后未稳定
	if [ -f "$MODDIR/attempt" ] && [ ! -f "$MODDIR/stable" ]; then
		fails=$(( $(cat "$MODDIR/failcount" 2>/dev/null || echo 0) + 1 ))
	else
		fails=0
	fi
	echo "$fails" > "$MODDIR/failcount"
	rm -f "$MODDIR/stable"

	if [ "$fails" -ge 2 ]; then
		release_lock
		log "连续 $fails 次加载后未稳定, 本次跳过自动加载 (重装模块或点一次操作按钮可重置)"
		exit 0
	fi

	date +%s > "$MODDIR/attempt"

	if load_ko; then
		release_lock
		log "自动加载成功"
		( sleep 60 && touch "$MODDIR/stable" ) &
	else
		release_lock
		log "自动加载失败, 详见内核日志"
	fi
) &
