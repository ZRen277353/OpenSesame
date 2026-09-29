#!/bin/sh
# OpenSesame 公共函数: KMI 识别 / vermagic 学习回写 / 内核模块加载
# 由 action.sh / service.sh source, 不单独执行。

MODDIR="${MODDIR:-${0%/*}}"
MODNAME=opensesame
KO=""; KOOFF=""; KMI=""

# KSU/SukiSU/Magisk 自带的 busybox
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox busybox; do
	if [ -x "$b" ] || command -v "$b" >/dev/null 2>&1; then
		BB="$b"
		break
	fi
done

LOCK_DIR="/data/local/tmp/.opensesame.lock"
acquire_lock() {
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		log "另一个加载流程正在执行, 本次跳过"
		return 1
	fi
	return 0
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null; }

log() { echo "[opensesame] $*"; }

# 按 uname -r 识别设备的 GKI KMI, 选择对应的 ko (SakiSU 式自动适配)
select_ko() {
	local kv
	kv=$(uname -r)
	case "$kv" in
		*android16*6.12*|*6.12*android16*) KMI=android16-6.12 ;;
		*android15*6.6*|*6.6*android15*)   KMI=android15-6.6 ;;
		*android14*5.15*|*5.15*android14*) KMI=android14-5.15 ;;
		*android13*5.15*|*5.15*android13*) KMI=android13-5.15 ;;
		*android13*5.10*|*5.10*android13*) KMI=android13-5.10 ;;
		*android12*5.10*|*5.10*android12*) KMI=android12-5.10 ;;
		*6.1*)                             KMI=android14-6.1 ;;
		*6.6*)                             KMI=android15-6.6 ;;
		*) return 1 ;;
	esac
	# 一体包布局: kos/opensesame-<KMI>.ko; 单 KMI 包布局: 根目录 opensesame.ko
	if [ -f "$MODDIR/kos/opensesame-$KMI.ko" ]; then
		KO="$MODDIR/kos/opensesame-$KMI.ko"
		KOOFF="$MODDIR/kos/opensesame-$KMI.offset"
	elif [ -f "$MODDIR/opensesame.ko" ]; then
		KO="$MODDIR/opensesame.ko"
		KOOFF="$MODDIR/opensesame.offset"
	else
		log "KMI 识别为 $KMI, 但模块目录里找不到 ko 文件, 请重新安装最新版模块包"
		return 1
	fi
	log "设备 KMI: $KMI (uname: $kv)"
	return 0
}

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
# 偏移/长度来自 CI 生成的 opensesame.offset (busybox grep 无 -a/-b, 设备端不做二进制查找)
rewrite_ko_vermagic() {
	local v="$1" off oldlen
	[ -f "$KO" ] || return 1
	if [ -f "$KOOFF" ]; then
		off=$(cut -d' ' -f1 "$KOOFF")
		oldlen=$(cut -d' ' -f2 "$KOOFF")
	else
		# 兜底: 系统 toybox grep 通常支持 -b/-a; 不行就让用户重装最新模块
		off=$(grep -abo 'vermagic=' "$KO" 2>/dev/null | head -n 1 | cut -d: -f1)
		if [ -z "$off" ]; then
			log "定位不到 vermagic, 请重新安装最新版模块 (缺少 offset 文件)"
			return 1
		fi
		off=$(( off + 9 ))
		oldlen=$(grep -aoh 'vermagic=[ -~]*' "$KO" 2>/dev/null | head -n 1 | wc -c)
		oldlen=$(( oldlen - 1 ))
	fi
	if [ ${#v} -gt $oldlen ]; then
		# 占位放不下完整设备 vermagic 时, 缩短版本号前缀 (去掉 -androidxx 等后缀):
		# 两侧都有 modversions 时, 内核比对忽略第一个空格之前的版本号段
		t=${v#* }
		rel=${v%% *}
		v="${rel%%-*} $t"
		log "占位不足, 使用缩短版本号形式 (${#v} 字节)"
		if [ ${#v} -gt $oldlen ]; then
			log "仍放不下, 无法回写"
			return 1
		fi
	fi
	# 写入: 设备串 + NUL 填满原串长度 (含原结尾的 NUL)
	{ printf '%s' "$v"; $BB dd if=/dev/zero bs=1 count=$(( oldlen - ${#v} + 1 )) 2>/dev/null; } |
		$BB dd of="$KO" bs=1 seek=$off conv=notrunc 2>/dev/null
	log "vermagic 已回写: $v"
}

# 加载: 选 ko -> 先直接试; vermagic 失败则 学习 -> 回写 -> 重试
load_ko() {
	if ! select_ko; then
		# ko 文件缺失时 select_ko 已给出具体原因, 这里只报 KMI 不识别的情况
		[ -n "$KMI" ] || log "没有适配本机内核 ($(uname -r)) 的 KMI, 请到仓库用 CI 构建对应 KMI 的模块包"
		return 1
	fi
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
