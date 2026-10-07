// SPDX-License-Identifier: GPL-2.0
/*
 * OpenSesame - 可开关放行 vermagic / 符号 CRC 校验 (kretprobe 方案)
 *
 * 两个 kretprobe 独立控制:
 *   vermagic=1   hook same_magic(), 放行 vermagic 校验
 *   crc=1        hook check_version(), 放行符号 CRC 校验
 *
 * 默认均为 0。模块加载后仍可通过:
 *   /sys/module/opensesame/parameters/vermagic
 *   /sys/module/opensesame/parameters/crc
 * 动态开关，WebUI 只负责写这两个参数并读取日志。
 *
 * 原理:
 *   insmod 时 check_modinfo() 调 same_magic() 比对 vermagic，不匹配返回
 *   -ENOEXEC。开启 vermagic 后，same_magic() 返回值恒为 true。
 *
 *   随后 check_version() 检查模块引用的符号 CRC，不匹配返回 0。开启 crc
 *   后，check_version() 返回值恒为 1。
 *
 *   arm64 的 __kretprobe_trampoline 会从 handler 看到的同一份 pt_regs
 *   恢复 x0-x30，因此改写 regs->regs[0] 能让调用方读到修改后的返回值。
 *
 * 限制:
 *   - 仅 arm64 + CONFIG_KPROBES
 *   - 若目标函数被内联 (kallsyms 无符号)，对应开关会拒绝开启
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/kstrtox.h>
#include <linux/mutex.h>
#include <linux/moduleparam.h>

static bool opensesame_vermagic_enabled;
static bool opensesame_crc_enabled;
static bool opensesame_vermagic_registered;
static bool opensesame_crc_registered;
static bool opensesame_initialized;
static DEFINE_MUTEX(opensesame_lock);

static int opensesame_vermagic_ret_handler(struct kretprobe_instance *ri,
					   struct pt_regs *regs)
{
	regs->regs[0] = 1;
	return 0;
}

static int opensesame_crc_ret_handler(struct kretprobe_instance *ri,
				      struct pt_regs *regs)
{
	regs->regs[0] = 1;
	return 0;
}

static struct kretprobe opensesame_vermagic_rp = {
	.kp = {
		.symbol_name = "same_magic",
	},
	.handler   = opensesame_vermagic_ret_handler,
	.maxactive = 4,
};

static struct kretprobe opensesame_crc_rp = {
	.kp = {
		.symbol_name = "check_version",
	},
	.handler   = opensesame_crc_ret_handler,
	.maxactive = 4,
};

static struct kretprobe *opensesame_rp(bool crc)
{
	return crc ? &opensesame_crc_rp : &opensesame_vermagic_rp;
}

static bool *opensesame_registered(bool crc)
{
	return crc ? &opensesame_crc_registered : &opensesame_vermagic_registered;
}

static const char *opensesame_name(bool crc)
{
	return crc ? "CRC" : "vermagic";
}

static int opensesame_apply_feature(bool crc, bool enable)
{
	int ret;

	if (enable) {
		ret = register_kretprobe(opensesame_rp(crc));
		if (ret) {
			pr_err("%s 放行开关开启失败 (%d): 目标符号不存在或已被内联\n",
			       opensesame_name(crc), ret);
			return ret;
		}
		*opensesame_registered(crc) = true;
		pr_info("%s 放行已开启\n", opensesame_name(crc));
		return 0;
	}

	if (*opensesame_registered(crc)) {
		unregister_kretprobe(opensesame_rp(crc));
		*opensesame_registered(crc) = false;
		pr_info("%s 放行已关闭\n", opensesame_name(crc));
	}
	return 0;
}

static int opensesame_set_feature(const char *val, const struct kernel_param *kp)
{
	bool crc = kp->arg == &opensesame_crc_enabled;
	bool *enabled = kp->arg;
	bool want;
	int ret;

	ret = kstrtobool(val, &want);
	if (ret)
		return ret;

	mutex_lock(&opensesame_lock);
	if (*enabled == want) {
		mutex_unlock(&opensesame_lock);
		return 0;
	}

	/* 模块 init 之前只记录 insmod 参数，真正注册在 init 中完成。 */
	if (!opensesame_initialized) {
		*enabled = want;
		mutex_unlock(&opensesame_lock);
		return 0;
	}

	ret = opensesame_apply_feature(crc, want);
	if (!ret) {
		*enabled = want;
	}
	mutex_unlock(&opensesame_lock);
	return ret;
}

static const struct kernel_param_ops opensesame_bool_ops = {
	.set = opensesame_set_feature,
	.get = param_get_bool,
};

module_param_cb(vermagic, &opensesame_bool_ops, &opensesame_vermagic_enabled, 0644);
MODULE_PARM_DESC(vermagic, "Bypass same_magic() vermagic checks (0/1)");

module_param_cb(crc, &opensesame_bool_ops, &opensesame_crc_enabled, 0644);
MODULE_PARM_DESC(crc, "Bypass check_version() symbol CRC checks (0/1)");

static int __init opensesame_init(void)
{
	int ret;

	if (!IS_ENABLED(CONFIG_ARM64)) {
		pr_err("仅支持 arm64\n");
		return -EINVAL;
	}

	mutex_lock(&opensesame_lock);
	if (opensesame_vermagic_enabled) {
		ret = opensesame_apply_feature(false, true);
		if (ret) {
			mutex_unlock(&opensesame_lock);
			return ret;
		}
	}
	if (opensesame_crc_enabled) {
		ret = opensesame_apply_feature(true, true);
		if (ret) {
			opensesame_apply_feature(false, false);
			mutex_unlock(&opensesame_lock);
			return ret;
		}
	}
	opensesame_initialized = true;
	mutex_unlock(&opensesame_lock);

	pr_info("模块已加载: vermagic=%s, crc=%s\n",
		opensesame_vermagic_enabled ? "on" : "off",
		opensesame_crc_enabled ? "on" : "off");
	if (!opensesame_vermagic_enabled && !opensesame_crc_enabled)
		pr_info("所有校验放行开关均为关闭, 当前不会改变内核校验行为\n");
	return 0;
}

static void __exit opensesame_exit(void)
{
	mutex_lock(&opensesame_lock);
	opensesame_initialized = false;
	if (opensesame_vermagic_registered) {
		unregister_kretprobe(&opensesame_vermagic_rp);
		opensesame_vermagic_registered = false;
	}
	if (opensesame_crc_registered) {
		unregister_kretprobe(&opensesame_crc_rp);
		opensesame_crc_registered = false;
	}
	mutex_unlock(&opensesame_lock);
	pr_info("已还原: vermagic / CRC 校验恢复原始行为\n");
}

module_init(opensesame_init);
module_exit(opensesame_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("ZRen277353");
MODULE_DESCRIPTION("OpenSesame: optional vermagic and symbol CRC bypass for module loading");
