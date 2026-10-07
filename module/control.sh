#!/bin/sh
# OpenSesame WebUI / action.sh 控制入口。
# 输出保持简单 key=value 或纯文本日志, 避免设备端依赖 jq/python。

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

usage() {
	echo "usage: control.sh {status|start|stop|toggle|set <key> <0|1>|logs|clearlog}"
}

status_output() {
	if loaded; then loaded_value=1; else loaded_value=0; fi
	if any_feature_enabled; then any_feature=1; else any_feature=0; fi

	echo "loaded=$loaded_value"
	echo "vermagic=$(config_get vermagic 0)"
	echo "crc=$(config_get crc 0)"
	echo "auto_start=$(config_get auto_start 0)"
	echo "active_vermagic=$(active_feature vermagic)"
	echo "active_crc=$(active_feature crc)"
	echo "any_feature=$any_feature"
	echo "kernel=$(uname -r)"
	echo "module_dir=$MODDIR"
}

start_module() {
	if loaded; then
		log "模块已经加载"
		return 0
	fi
	if ! any_feature_enabled; then
		log "没有启用任何校验放行开关, 请先在 WebUI 中打开 vermagic 或 CRC"
		return 1
	fi

	log "手动加载: $(feature_summary)"
	acquire_lock || return 1
	if load_ko; then
		release_lock
		echo 0 > "$MODDIR/failcount"
		rm -f "$MODDIR/attempt" "$MODDIR/stable" "$MODDIR/verified"
		log "加载成功: $(feature_summary)"
		dmesg 2>/dev/null | tail -n 5
		return 0
	fi

	release_lock
	log "加载失败, 请查看内核日志"
	dmesg 2>/dev/null | tail -n 20
	return 1
}

stop_module() {
	if ! loaded; then
		log "模块未加载"
		return 0
	fi
	rmmod "$MODNAME" 2>/dev/null || $BB rmmod "$MODNAME" 2>/dev/null
	if loaded; then
		log "卸载失败, 请查看内核日志"
		return 1
	fi
	log "已卸载, 内核补丁已还原"
	return 0
}

logs_output() {
	echo "== 脚本日志 =="
	if [ -f "$LOG_FILE" ]; then
		tail -n 160 "$LOG_FILE" 2>/dev/null
	else
		echo "(暂无脚本日志)"
	fi
	echo
	echo "== 内核日志 (opensesame) =="
	dmesg 2>/dev/null | grep -i "$MODNAME" | tail -n 80 || echo "(暂无内核日志)"
}

set_flag() {
	key="$1"
	value="$2"
	case "$key" in
		vermagic|crc)
			if loaded; then
				write_feature "$key" "$value" || return 1
			fi
			config_set "$key" "$value" || return 1
			log "开关已更新: $key=$value"
			;;
		auto_start)
			config_set "$key" "$value" || return 1
			if [ "$value" = "1" ]; then
				echo 0 > "$MODDIR/failcount"
				rm -f "$MODDIR/attempt" "$MODDIR/stable"
			fi
			log "开机自启已更新: $value"
			;;
		*)
			usage
			return 1
			;;
	esac
	return 0
}

case "$1" in
	status)
		status_output
		;;
	start)
		start_module
		;;
	stop)
		stop_module
		;;
	toggle)
		if loaded; then
			stop_module
		else
			start_module
		fi
		;;
	set)
		[ -n "$2" ] && [ -n "$3" ] || { usage; exit 1; }
		set_flag "$2" "$3"
		;;
	logs)
		logs_output
		;;
	clearlog)
		: > "$LOG_FILE"
		log "日志已清空"
		;;
	*)
		usage
		exit 1
		;;
esac
