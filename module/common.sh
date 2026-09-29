#!/bin/sh
# OpenSesame 公共函数: vermagic 学习/回写 + 内核模块加载
# 由 action.sh / service.sh source, 不单独执行。

MODDIR="${MODDIR:-${0%/*}}"
KO="$MODDIR/opensesame.ko"
MODNAME=opensesame

# KSU/SukiSU/Magisk 自带的 busybox (grep -a/-o/dd 行为比 toybox 稳)
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox busybox; do
	if [ -x "$b" ] || command -v "$b" >/dev/null 2>&1; then
		BB="$b"
		break
	fi
done

log() { echo "[opensesame] $*"; }

# 并发锁: action 与 service 同时跑时, 内核里两份 finit_module 竞争同一文件
# 曾导致 mod_sysfs_setup 崩溃 (pstore 实锤), 任何加载前必须持锁
LOCK_DIR="/data/local/tmp/.opensesame.lock"
acquire_lock() {
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		log "另一个加载流程正在执行, 本次跳过"
		return 1
	fi
	return 0
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null; }

# 设备真实 vermagic 优先从厂商自带模块读取 (不产生失败日志)
vermagic_from_vendor() {
	local f v
	for f in /vendor_dlkm/lib/modules/*.ko /vendor/lib/modules/*.ko /odm/lib/modules/*.ko; do
		[ -f "$f" ] || continue
		v=$(sed -n "s/.*vermagic=\([ -~]\{1,\}\).*/\1/p" "$f" 2>/dev/null | head -n 1)
		if [ -n "$v" ]; then
			echo "$v"
			return 0
		fi
	done
	return 1
}

# 兜底: 试载失败后, 从内核日志解析 "version magic '..' should be '..'" (ksuinit 同款思路)
vermagic_from_kmsg() {
	dmesg 2>/dev/null | sed -n "s/.*version magic '[^']*' should be '\([^']*\)'.*/\1/p" | tail -n 1
}

device_vermagic() {
	local v
	v=$(vermagic_from_vendor) && [ -n "$v" ] && { echo "$v"; return 0; }
	v=$(vermagic_from_kmsg) && [ -n "$v" ] && { echo "$v"; return 0; }
	return 1
}

# 把设备 vermagic 原位写进 ko 的 .modinfo
# 偏移/长度来自 CI 生成的 opensesame.offset (busybox grep 没有 -a/-b, 设备端不做二进制查找)
rewrite_ko_vermagic() {
	local v="$1" off oldlen
	[ -f "$KO" ] || return 1
	if [ -f "$MODDIR/opensesame.offset" ]; then
		off=$(cut -d' ' -f1 "$MODDIR/opensesame.offset")
		oldlen=$(cut -d' ' -f2 "$MODDIR/opensesame.offset")
	else
		# 兜底: 系统 toybox grep 通常支持 -b/-a; 不行就让用户重装最新模块
		off=$(grep -abo 'vermagic=' "$KO" 2>/dev/null | head -n 1 | cut -d: -f1)
		if [ -z "$off" ]; then
			log "定位不到 vermagic, 请重新安装最新版模块 (缺少 opensesame.offset)"
			return 1
		fi
		off=$(( off + 9 ))
		oldlen=$(grep -aoh 'vermagic=[ -~]*' "$KO" 2>/dev/null | head -n 1 | wc -c)
		oldlen=$(( oldlen - 1 ))
	fi
	if [ ${#v} -gt $oldlen ]; then
		log "设备 vermagic(${#v} 字节) 比占位(${oldlen} 字节)还长, 无法回写"
		return 1
	fi
	# 写入: 设备串 + NUL 填满原串长度 (含原结尾的 NUL)
	{ printf '%s' "$v"; $BB dd if=/dev/zero bs=1 count=$(( oldlen - ${#v} + 1 )) 2>/dev/null; } |
		$BB dd of="$KO" bs=1 seek=$off conv=notrunc 2>/dev/null
	log "vermagic 已回写: $v"
}

# 加载: 先直接试; vermagic 失败则 学习 -> 回写 -> 重试
load_ko() {
	$BB insmod "$KO" 2>/dev/null && return 0
	local v
	v=$(device_vermagic) || {
		log "拿不到设备 vermagic (vendor 模块和 kmsg 里都没有)"
		return 1
	}
	rewrite_ko_vermagic "$v" || return 1
	$BB insmod "$KO"
}

loaded() {
	grep -q "$MODNAME" /proc/modules 2>/dev/null
}
