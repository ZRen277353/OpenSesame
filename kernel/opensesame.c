// SPDX-License-Identifier: GPL-2.0
/*
 * OpenSesame - 放行 vermagic 校验不通过的内核模块 (kretprobe 方案)
 *
 * 原理:
 *   insmod 时内核在 check_modinfo() 中调用 same_magic() 比对模块与运行中
 *   内核的 vermagic, 不匹配返回 -ENOEXEC, 用户态表现为 "Exec format error"。
 *
 *   本模块在 same_magic() 上挂一个 kretprobe: 函数本体照常执行, 返回时把
 *   x0 改写为 1 (bool true)。arm64 的 __kretprobe_trampoline 会从 handler
 *   看到的同一份 pt_regs 恢复 x0-x30 (save_all_base_regs / restore_all_
 *   base_regs), 因此调用方读到的返回值恒为 true, vermagic 校验不再生效。
 *
 *   相比直接改写内核文本 (v0.1, aarch64_insn_patch_text), 本方案:
 *   - 只使用已导出的 register_kretprobe API, 不调用任何未导出函数
 *     (v0.1 因原型与调用语义差异在 CFI/补丁路径上引发内核崩溃, 已废弃)
 *   - 不修改任何内核内存; rmmod 即完全还原, 失败也只会干净退出
 *
 * 限制:
 *   - 仅 arm64 + CONFIG_KPROBES
 *   - 若编译器将 same_magic() 内联 (kallsyms 无符号), 注册会失败并明确
 *     报错, 该内核不受支持 (用 scripts/probe.sh 自测)
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kprobes.h>

/* 强制 same_magic() 返回 true: 调用方读到的 x0 恒为 1 */
static int opensesame_ret_handler(struct kretprobe_instance *ri,
				  struct pt_regs *regs)
{
	regs->regs[0] = 1;
	return 0;
}

static struct kretprobe opensesame_rp = {
	.kp = {
		.symbol_name = "same_magic",
	},
	.handler   = opensesame_ret_handler,
	.maxactive = 4,
};

static int __init opensesame_init(void)
{
	int ret;

	if (!IS_ENABLED(CONFIG_ARM64)) {
		pr_err("仅支持 arm64\n");
		return -EINVAL;
	}

	ret = register_kretprobe(&opensesame_rp);
	if (ret) {
		pr_err("kretprobe 注册失败 (%d): same_magic() 可能已被内联, 本内核不受支持\n",
		       ret);
		return ret;
	}

	pr_info("已放行: same_magic() 返回值恒为 true, vermagic 校验不再生效 (rmmod 可还原)\n");
	return 0;
}

static void __exit opensesame_exit(void)
{
	unregister_kretprobe(&opensesame_rp);
	pr_info("已还原: same_magic() 恢复原始行为\n");
}

module_init(opensesame_init);
module_exit(opensesame_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("ZRen277353");
MODULE_DESCRIPTION("OpenSesame: override same_magic() return value so vermagic-mismatched modules load");
