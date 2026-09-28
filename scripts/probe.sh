#!/bin/sh
# 设备侧支持性探测: 在设备 root shell 里运行 (sh probe.sh)
# 目的: 确认你的内核是否保留了 same_magic 符号 —— 这是 OpenSesame 能否工作的前提
# 用法: adb push probe.sh /data/local/tmp/ && adb shell "su -c 'sh /data/local/tmp/probe.sh'"

echo "== 内核 =="
uname -a
echo
echo "== 关键符号 (/proc/kallsyms) =="
for s in same_magic check_modinfo layout_and_allocate aarch64_insn_patch_text aarch64_insn_write; do
		if grep -qE " $s\$" /proc/kallsyms 2>/dev/null; then
			echo "  [存在] $s"
		else
			echo "  [缺失] $s   <-- same_magic 缺失 = 本内核不受支持 (被内联)"
		fi
	done
echo
echo "== 设备 vermagic 期望值 (从厂商模块读取) =="
for f in /vendor_dlkm/lib/modules/*.ko /vendor/lib/modules/*.ko /odm/lib/modules/*.ko; do
	[ -f "$f" ] || continue
	grep -aoh 'vermagic=[ -~]*' "$f" | head -n 1
	break
done
echo
echo "== 内核配置 =="
if [ -r /proc/config.gz ]; then
	zcat /proc/config.gz | grep -E "^CONFIG_(KPROBES|KALLSYMS|KALLSYMS_ALL|MODVERSIONS|MODULE_SIG_FORCE|ARM64)=" || echo "  (未匹配到相关配置)"
else
	echo "  (无 /proc/config.gz, 跳过)"
fi
