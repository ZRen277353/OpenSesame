# OpenSesame

> 芝麻开门 —— 让内核全局放行 vermagic 校验, 所有内核驱动都能直接 insmod

<div align="center">
  <img src="https://count.getloli.com/get/@ZRen277353-OpenSesame?theme=moebooru" alt="访问计数" />
  <br/>
  <sub>猫娘计数板 · 本页面被打开的次数</sub>
</div>

一个 SakiSU / KernelSU 模块: 加载后在内核的 `same_magic()` (vermagic 比对
函数) 上挂 kretprobe, 返回值恒改为 true —— 此后 **任何 vermagic 不匹配的
内核驱动都能直接加载**, driver_auto 等自动安装脚本原样可用。符号 CRC
(CONFIG_MODVERSIONS) 校验**有意保留**, ABI 不兼容的驱动仍会被干净地拒绝,
这是本项目的安全边界。

## 实战状态

| 设备 | 内核 | 状态 |
|---|---|---|
| vivo PD2339M / iQOO Neo9S Pro (MT6989) | 6.1.124-android14-11-maybe-dirty | 模块加载成功, 为 6.1.159 GKI 编译的闭源驱动成功加载 |
| 其他 GKI 设备 | 见支持范围 | 理论可用, 欢迎实测反馈 issue |

## 工作原理

```
insmod xxx.ko
  └─ check_modinfo() ── same_magic()   <- kretprobe 把返回值改写为恒真
                             |
                             └─ vermagic 不匹配 => 原本返回 -ENOEXEC ("Exec format error")
```

- 在 `same_magic()` 上挂 kretprobe: 函数本体照常执行, 返回时把 `x0` 改写
  为 1。arm64 的 `__kretprobe_trampoline` 会从 handler 看到的同一份
  pt_regs 恢复寄存器, 因此调用方读到的返回值恒为 true;
- **只使用已导出的 `register_kretprobe` API, 不修改任何内核内存**:
  注册失败就是干净失败, `rmmod` 即完全还原;
- ko 自身的 vermagic 由加载脚本运行时适配 (ksuinit 同款思路): CI 构建时
  随包附带占位 vermagic 的字节偏移文件, 设备侧优先从厂商模块读取真实
  vermagic, 兜底从一次失败 insmod 的 kmsg 里解析 `should be '...'`,
  原地回写后再加载。

## 支持范围与自动适配

- 架构: arm64, GKI 内核;
- CI 矩阵为每个 KMI 分支构建一个 ko: `android14-6.1` / `android13-5.15` /
  `android14-5.15` / `android15-6.6` (ddk 还支持 android12-5.10、
  android13-5.10、android16-6.12, 需要时在 workflow 矩阵里追加);
- **一体包 (`OpenSesame-all-kmi`) 内含全部 ko, 加载时按 `uname -r`
  自动选择对应 KMI** —— 与 SakiSU 管理器为不同内核挑选 LKM 是同一逻辑;
- 前提: 内核启用 CONFIG_KPROBES, 且 kallsyms 保留了 `same_magic` 符号
  (若被编译器内联则该内核不受支持)。不确定请跑探测脚本:

```bash
adb push scripts/probe.sh /data/local/tmp/
adb shell "su -c 'sh /data/local/tmp/probe.sh'"
```

## 使用方法

1. **禁止本地编译**: push 到 `main` 后 GitHub Actions 自动矩阵构建
   (或手动 workflow_dispatch), 从产物下载:
   - `OpenSesame-all-kmi` —— 全 KMI 一体包 (推荐, 装哪个机型都行);
   - `OpenSesame-<kmi>` —— 单 KMI 包, 须与设备 KMI 一致
     (两种包布局 v0.2.1 起均支持自动选择);
2. SakiSU / KernelSU 管理器安装;
3. **安装后默认不自动加载、不改内核**。点模块的「操作」按钮:
   第一次点击 = 加载 + 启用开机自动加载; 再点一次 = 卸载 + 关闭;
4. 加载成功后, 直接跑你的驱动安装脚本即可。

## 防 bootloop 设计

内核交互全部为 RAM-only (kretprobe 钩子), 重启即归零, 最坏情况是循环
重启而不是砖。四道保险:

1. 默认不自动加载, 必须先手动验证 (action 按钮);
2. 自动加载发生在开机末尾 (service.sh + 20s 延迟);
3. 熔断: 连续 2 次"加载后 60 秒内系统未稳定"就拒绝自动加载;
4. 加载流程持并发锁, 杜绝双脚本竞争 (曾实测导致 mod_sysfs_setup 崩溃)。

## 排查

```bash
su -c 'dmesg | grep opensesame'        # 模块自身日志
su -c 'cat /sys/fs/pstore/console-ramoops-0 | tail -c 6000'   # 上次崩溃现场
```

常见失败: `kretprobe 注册失败` = 内核把 same_magic 内联了 (不支持);
`disagrees about version of symbol` = 驱动 ABI 与内核不兼容 (CRC 校验
正确拦截, 属预期行为, 请勿绕过);
`模块目录里找不到 ko 文件` = 装了 v0.2.0 及更早的**单 KMI 包**
(旧版加载脚本只认一体包的 kos/ 布局) —— 更新模块到 v0.2.1+,
或改装 `OpenSesame-all-kmi` 一体包。

关于系统 OTA 小版本更新 (如 6.1.124 → 6.1.145): **同一 KMI 内 ko 通用**,
GKI 承诺同 KMI 分支内核 ABI 稳定, 无需重新构建; 若 OTA 跨了 KMI
(如 6.1 → 6.6), 加载脚本会自动切换到对应的 ko。

## 目录结构

```
open-sesame/
├── kernel/                    # 内核补丁模块源码 (ddk 云端矩阵构建)
│   ├── opensesame.c
│   └── Makefile
├── module/                    # SakiSU/KernelSU 模块
│   ├── module.prop
│   ├── customize.sh           # 安装脚本
│   ├── common.sh              # KMI 识别 / vermagic 学习回写 / 加载
│   ├── action.sh              # 「操作」按钮: 手动加载/卸载开关
│   ├── service.sh             # 开机自动加载 (默认关, 带熔断)
│   └── uninstall.sh
├── scripts/
│   ├── probe.sh               # 设备侧支持性自测
│   └── patch_boot.py          # (已废弃的) boot 镜像补丁器, 留档
└── .github/workflows/build.yml
```

## 已知限制

- 各厂商对 GKI 的魔改程度不同, 结构体布局极端偏离 GKI 的内核上, ko 自身
  可能无法加载 (实测 case: 见 git 历史 v0.1.x 的 pstore 分析);
- `same_magic` 被内联的内核不受支持;
- 放行 vermagic 后, 加载来源不明的 `.ko` 风险自担;
- 仅用于自有设备的实验与研究, 请遵守当地法律法规。

## 致谢

- vermagic 运行时适配思路来自
  [SakiSU](https://github.com/XingChenRS/SakiSU) 的 ksuinit;
- 构建环境来自 [5ec1cff/ddk](https://github.com/5ec1cff/ddk)
  (SakiSU 官方 LKM 同款)。

## License

GPL-2.0-only
