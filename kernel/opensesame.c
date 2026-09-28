// SPDX-License-Identifier: GPL-2.0
/*
 * OpenSesame - 放行 vermagic 校验不通过的内核模块
 *
 * 原理:
 *   insmod 时, 内核在 check_modinfo() 中调用静态函数 same_magic() 比对
 *   模块与运行中内核的 vermagic, 不匹配返回 -ENOEXEC, 用户态表现为
 *   "Exec format error"。本模块用 kprobe 按符号名定位 same_magic(),
 *   校验原始指令后, 将其前两条指令改写为:
 *
 *       mov w0, #1
 *       ret
 *
 *   使 vermagic 比对恒通过。符号 CRC (CONFIG_MODVERSIONS) 校验不受影响,
 *   ABI 不兼容的模块仍会被正常拒绝 —— 这是有意为之的安全边界。
 *
 * 安全设计:
 *   - 默认 dry-run (enable=0): 只探测、打印, 不改写任何内核内存
 *   - patch 前检查目标指令: 全零等异常直接放弃, 已 patch 则幂等跳过
 *   - rmmod 卸载时还原原始指令
 *   - 找不到符号时明确报错退出, 绝不盲写
 *
 * 限制:
 *   - 仅 arm64; 需要 CONFIG_KPROBES=y 与 CONFIG_KALLSYMS
 *   - 若编译器把 same_magic() 内联进 check_modinfo(), kallsyms 中将没有
 *     该符号, 本模块会报错退出 (该内核不受支持, 用 scripts/probe.sh 自测)
 *   - aarch64_insn_patch_text() 未导出, 通过 kallsyms 取地址后按其原型
 *     调用; 内核开启 CFI 时按类型哈希校验, 原型一致即可通过
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kprobes.h>

static int enable;                /* 默认 0: dry-run, 不改内核 */
module_param(enable, int, 0444);
MODULE_PARM_DESC(enable, "1 = 真正 patch; 0 = 只探测 (默认)");

static char sym[64] = "same_magic";
module_param_string(sym, sym, sizeof(sym), 0444);
MODULE_PARM_DESC(sym, "要放行的比对函数符号名 (默认 same_magic)");

/* int aarch64_insn_patch_text(void *addrs, u32 *insns, int cnt) */
typedef int (*patch_text_fn)(void *addrs, u32 *insns, int cnt);

#define OP_MOV_W0_1 0x52800020u   /* mov w0, #1 */
#define OP_RET      0xd65f03c0u   /* ret        */

static patch_text_fn patch_text;
static void *target;
static u32 orig[2];
static bool patched;

/* kallsyms_lookup_name 自 5.7 起不再导出, 用 kprobe 拿符号地址 */
static void *symbol_addr(const char *name)
{
	struct kprobe kp = { .symbol_name = name };
	void *addr;

	register_kprobe(&kp);          /* 即使注册失败, kp.addr 也已被填上 */
	addr = (void *)kp.addr;
	unregister_kprobe(&kp);
	return addr;
}

static int __init opensesame_init(void)
{
	u32 insns[2] = { OP_MOV_W0_1, OP_RET };
	u32 *p;

	if (!IS_ENABLED(CONFIG_ARM64)) {
		pr_err("仅支持 arm64\n");
		return -EINVAL;
	}

	patch_text = (patch_text_fn)symbol_addr("aarch64_insn_patch_text");
	if (!patch_text) {
		pr_err("kallsyms 中没有 aarch64_insn_patch_text(), 无法安全改写内核文本\n");
		return -ENXIO;
	}

	target = symbol_addr(sym);
	if (!target) {
		pr_err("kallsyms 中没有 %s() —— 可能已被编译器内联, 本内核不受支持\n",
		       sym);
		return -EOPNOTSUPP;
	}

	p = (u32 *)target;
	orig[0] = p[0];
	orig[1] = p[1];
	pr_info("%s() @ %pS, 原指令: %08x %08x\n", sym, target, orig[0], orig[1]);

	if (orig[0] == OP_MOV_W0_1 && orig[1] == OP_RET) {
		pr_info("目标已是补丁状态 (重复加载?), 幂等跳过\n");
		return 0;
	}
	if (!orig[0] && !orig[1]) {
		pr_err("目标指令全为 0, 异常, 拒绝 patch\n");
		return -EINVAL;
	}

	if (!enable) {
		pr_info("dry-run (enable=0): 未修改内核; 确认无误后用 enable=1 重新加载\n");
		return 0;
	}

	if (patch_text(target, insns, 2)) {
		pr_err("patch 失败\n");
		return -EFAULT;
	}
	patched = true;
	pr_info("已放行: %s() 恒返回 true, vermagic 校验不再生效 (rmmod 可还原)\n",
		sym);
	return 0;
}

static void __exit opensesame_exit(void)
{
	u32 insns[2] = { orig[0], orig[1] };

	if (!patched)
		return;
	if (patch_text(target, insns, 2))
		pr_err("还原原始指令失败! 建议尽快重启\n");
	else
		pr_info("已还原 %s() 原始指令\n", sym);
}

module_init(opensesame_init);
module_exit(opensesame_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("ZRen277353");
MODULE_DESCRIPTION("OpenSesame: patch same_magic() so vermagic-mismatched modules load");
