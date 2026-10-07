# OpenSesame

> 芝麻开门 —— 可开关放行 vermagic / 符号 CRC 校验, 让不匹配的内核驱动直接 insmod

> 🤖 **本项目全程由 ZCode (AI 编码代理, 模型 GLM-5.3-Flash) 完成** —— 包括内核
> 模块代码、SakiSU 模块脚本、CI 工作流、各 KMI 适配、崩溃取证分析与本 README;
> 设备端实测与验证由项目所有者完成。

<div align="center">
  <img src="https://count.getloli.com/get/@ZRen277353-OpenSesame?theme=moebooru" alt="访问计数" />
  <br/>
  <sub>猫娘计数板 · 本页面被打开的次数</sub>
</div>

一个 SakiSU / KernelSU 模块: 提供两个默认关闭、可独立控制的 kretprobe 开关。
打开 `vermagic` 后, 内核 `same_magic()` 返回值恒为 true; 打开 `crc` 后,
`check_version()` 也恒为成功。两者都关闭时模块只是空载, 不改变内核行为。
模块内置 WebUI, 可控制两个校验开关、开机自启并查看运行日志。

- **可选择**: `vermagic` 与符号 CRC 两个开关独立控制, 默认全关, WebUI 手动开启;
- **全局**: 开启后放行的是内核校验逻辑本身, 对之后 insmod 的模块生效, 无需逐个适配;
- **热修补**: 不刷任何分区, 不改 boot 镜像, 全部效果 RAM-only, 重启即归零;
- **可撤除**: 卸载 = `rmmod`, kprobe 注销 + 入口指令由框架自动还原, 无残留;
- **多 KMI**: CI 矩阵预编译 android14-6.1 / android13-5.15 / android14-5.15 /
  android15-6.6, 设备端按 `uname -r` 自动选择 (SakiSU 式自动适配);
- **防 bootloop**: 默认不自动加载, 带熔断, 最坏情况是循环重启而不是砖。

## 目录

- [工作原理](#工作原理)
- [演进历程: 这个模块是怎么一步步做出来的](#演进历程-这个模块是怎么一步步做出来的)
- [实战状态](#实战状态)
- [支持范围与 KMI 自动适配](#支持范围与-kmi-自动适配)
- [使用方法](#使用方法)
- [免解锁 (漏洞 root) 设备适用性](#免解锁-漏洞-root-设备适用性)
- [防 bootloop 设计](#防-bootloop-设计)
- [排查](#排查)
- [封号风险与安全边界](#封号风险与安全边界)
- [已知限制](#已知限制)
- [致谢](#致谢)

## 工作原理

### 一次 insmod 在内核里经历了什么

```
finit_module(2)
  └─ load_module()
       ├─ check_modinfo()        <- vermagic 比对在这里, 不过 -> -ENOEXEC
       │    └─ same_magic()      <- vermagic 开关的 kretprobe 目标
       ├─ check_version()        <- 符号 CRC 比对, CRC 开关的 kretprobe 目标
       ├─ 分配/重定位/解释 .gnu.linkonce.this_module 段
       ├─ mod_sysfs_setup()      <- sysfs 节点 + 模块依赖链表
       └─ do_one_initcall()      <- 模块 init
```

`same_magic()` 是上游内核的 vermagic 比对函数, 规则:

- 两侧都开 `CONFIG_MODVERSIONS` 时, 跳过第一个空格之前的内核版本号段
  (6.1.124 与 6.1.159 之争被忽略), 只比尾部标志串
  (`SMP preempt mod_unload modversions aarch64`);
- 否则整串比对, 一个字符都不能差。

厂商内核还常在 vermagic 里附加私有标签 (vivo 内核要求 `vivo` 标签),
外来驱动 (例如为 GKI 6.1.159 编译的闭源驱动) 拿到的 vermagic 与设备
内核整串对不上, 于是:

```
same_magic() -> false
  -> check_modinfo() -> -ENOEXEC
    -> insmod 报 "Exec format error"
```

OpenSesame 默认不动这些返回值。手动打开 `vermagic` 后让 `same_magic()`
恒为 true; 手动打开 `crc` 后让 `check_version()` 恒为成功。

### kretprobe 如何全局放行 (寄存器级细节)

```
                same_magic() 入口
                ┌───────────────┐
 insmod 调用 ──>│ BRK (kprobe)  │ 原指令被 kprobes 框架移走, 断点接管
                └───────┬───────┘
                        │  函数照常执行, 算出 false
                        ▼
                __kretprobe_trampoline
                        │  ret handler: regs->regs[0] = 1
                        ▼
                调用方读到的返回值 = 1 (true)
```

- 开关打开时调用 `register_kretprobe()` 挂在 `same_magic` / `check_version` 上;
- 返回 handler 只做一件事: `regs->regs[0] = 1`。arm64 的
  `__kretprobe_trampoline` 从 handler 看到的**同一份 pt_regs** 恢复
  x0-x30, 因此调用方读到的返回值恒为 true;
- 对内核其余部分零感知: 不 hook 系统调用, 不改 LSM, 不碰任何进程;
- `rmmod` 后 kprobe 注销, 入口指令由 kprobes 框架自动还原, 一切如初。

**为什么不选别的方案:**

| 方案 | 问题 |
|---|---|
| `aarch64_insn_patch_text()` 硬改函数体 | 需要 stop_machine 停所有 CPU, 时序敏感 —— 本项目 v0.1.x 实测崩内核 (见演进历程) |
| 改 boot 镜像 / 重编内核 | 修改过内核的机器进不了任何刷机模式, 对这类设备等于强制变砖 |
| 逐个魔改驱动 ko 的 vermagic | 只治标, 改不了内核侧比对逻辑, 每换一个驱动都要重来 |

### ko 自身如何适配你的内核 (三道适配)

放行别人之前, ko 自己得先能加载进你的内核。三件事:

1. **KMI 自动选择**: 一体包内含各 KMI 的预编译 ko, 脚本按 `uname -r`
   匹配 (如 `6.1.145-android14-11-maybe-dirty` → android14-6.1);
2. **vermagic 运行时回写**: ko 里固化的是 CI 构建机的 vermagic, 与设备
   对不上。做法是 ksuinit 同款思路: 先试载 → 从设备学到真实 vermagic →
   原位回写 → 重试。学习来源两级: 先从厂商自带模块 (`/vendor_dlkm` 等
   下的 `.ko`) sed 提取, 兜底解析 kmsg 里的
   `version magic '..' should be '..'`。设备端 busybox 的 grep 没有
   `-a/-b`, 做不了二进制查找, 所以 CI 构建时就把 `vermagic=` 值的字节
   偏移/长度算好写进 offset 文件, 设备端只做 `dd`。占位放不下完整串时,
   利用 "MODVERSIONS 下版本号段被忽略" 的规则缩短前缀 (去掉
   `-androidxx` 后缀);
3. **struct module 布局**: 内核按**它自己的** `struct module` 布局去
   解释 ko 内嵌的 `.gnu.linkonce.this_module` 段 (init/exit 等指针都在
   里面), 布局不一致就会把函数指针当链表节点走, 直接 panic。本项目用
   [ddk](https://github.com/5ec1cff/ddk) (SakiSU 官方 LKM 同款构建环境)
   —— 同一套 GKI config + 工具链, 与 GKI/厂商内核天然对齐。v0.1.x 连续
   崩内核的根因就是这里, 见演进历程第 5 步。

### 安全边界: 两个校验开关

两个开关都默认关闭, WebUI 中手动开启:

- vermagic 只是版本字符串约定, 放行无实质风险;
- CRC 是每个符号真实的 ABI 指纹, 放行后布局不兼容的驱动也能进入内核,
  轻则报错重则崩内核。除非你明确知道驱动可与当前内核 ABI 共存, 否则保持
  CRC 开关关闭;
- 关闭 `crc` 时, 不兼容的驱动仍会被干净地拒绝
  (`disagrees about version of symbol`)。

## 演进历程: 这个模块是怎么一步步做出来的

### 第 0 步 · 问题与约束

设备: vivo PD2339M / iQOO Neo9S Pro (MT6989), 内核
`6.1.124-android14-11-maybe-dirty`, 通过 SakiSU 修补 init_boot 获得
LKM 方式 root。目标: 加载一套闭源驱动 (为 GKI 6.1.159 构建, 而且被加壳
在二进制里运行时动态解出 insmod, 拿不到独立 ko 文件), 全部报
`Exec format error` —— vermagic 比对不过。

约束把可行域压得很窄:

- 没有内核源码, 没有驱动源码;
- 没有本地工具链, **所有编译必须走 GitHub Actions 云端**;
- 内核镜像一旦被修改, 设备进不了任何刷机模式, **等于强制变砖** ——
  只能运行时热修补。

于是唯一的路线: 云端构建一个"能加载进这个内核"的 ko, 加载后从内核
内部放行 vermagic 校验。

### 第 1 步 · 云端构建第一个 ko (连踩三坑)

最初自搭 modules_prepare 环境 (拉 GKI config + clang), CI 连报三错:

| 坑 | 原因 | 解法 |
|---|---|---|
| modules_prepare 失败 | gki_defconfig 引用私有仓库的证书文件 | 清空 `SYSTEM_TRUSTED_KEYS` / `SYSTEM_REVOCATION_KEYS` |
| ko 体积异常/依赖 BTF | `DEBUG_INFO_BTF(_MODULES)` 需要 vmlinux 的 BTF | 关闭 |
| utsrelease 超长 | `include/generated/utsrelease.h` 有 64 字符上限 | 缩短 LOCALVERSION (总 release 压到 61 字符) |

ko 构建出来了, 但在设备上一点执行就崩 (第 3 步)。

### 第 2 步 · 设备端 vermagic 回写基建

设备 vermagic 拿不到编译期 (没有内核源码), 只能运行时学。先撞上的坑
是模块环境自带的 busybox **grep 没有 `-a/-b`**, 无法在二进制里定位
vermagic —— 解法是 CI 构建时算好 `vermagic=` 值的字节偏移和长度, 写进
offset 文件随包分发, 设备端只做 `dd` 原位写入。学习来源做成两级兜底:
厂商自带模块 sed 提取 → kmsg 解析。这样"试载 → 学 vermagic → 回写 →
重试"的流水线就绪了。

### 第 3 步 · 全局放行第一版: 文本补丁 → 崩

- v0.1.1: 用 `aarch64_insn_patch_text()` 把 `same_magic` 入口改成恒返 1
  —— 点执行后手机卡死 → 黑屏 → 自动重启, 百分百复现;
- 一度怀疑是脚本里的 `dd` 危险, 排查后确认 `dd` 只写模块目录里的文件,
  与崩溃无关; 崩的是内核态的 patch_text 路径;
- v0.1.2: 换成 kretprobe (官方 API, 不手工改内核内存) → **同样的崩**;
- v0.1.3: 加并发锁 (防双脚本竞争) + strip 调试段 → **依然同样的崩**。

三次崩溃症状完全一致, 证明崩点与放行手段无关 —— **ko 自身在加载过程
中就崩了**, 问题出在构建产物本身, 不在补丁方式。

### 第 4 步 · pstore 取证

崩溃现场从 `/sys/fs/pstore/console-ramoops` 拿到: panic 在
`mod_sysfs_setup+0x208`, 指令 `ldr x0, [x8, #0xf0]`,
`x8 = 0xb000000097501bd4` —— 明显不是合法内核地址。`mod_sysfs_setup`
负责建立模块 sysfs 节点和模块依赖链表: 内核在把 ko 里的某个数据**当
链表走**。最大嫌疑: ko 内嵌的 `.gnu.linkonce.this_module` 段
(`struct module` 实例, init/exit 指针都在里面)。

### 第 5 步 · 拆 boot 镜像, 定位根因

没有内核源码, 就从设备自己身上取证据:

1. 拿到原厂 `boot_b.im`, 解析 boot 头, kernel 是 LZ4-legacy 压缩
   (魔数 `0x184C2102`), 解出 Image;
2. `vmlinux-to-elf` 生成带 kallsyms 的 `vmlinux.elf`;
3. 确认 `same_magic` 在 `0xffffffc00818b2a4`, 未被内联、无 CFI 保护
   —— kretprobe 路线本身没问题;
4. 对比我们 ko 的 this_module 段重定位: init/exit 指针落在偏移
   **0x3c8**; 而在 vivo 内核的 `struct module` 布局里, 0x3c8 是
   `target_list` (模块依赖链表) 字段。

**完整因果链**: 自搭环境的内核编译选项与 vivo 内核有差异 → `struct
module` 布局不一致 → 内核按自己的布局解释 ko 的 this_module 段 →
`add_usage_links()` 遍历依赖链表时, 把错位落进 `target_list` 的 init
函数指针当成链表节点解引用 → panic。**布局, 就是根因。**

### 第 6 步 · 换 ddk, 一次成功

换用 [ddk](https://github.com/5ec1cff/ddk) —— SakiSU 官方 LKM 的同款
构建环境 (同一套 GKI config + 工具链 + kdir)。逻辑很简单: SakiSU 的
ksu.ko 能在这台机器上跑, 同款环境构建的 ko 布局必然兼容。复测确认
ddk 构建的 this_module 重定位 (init@0x170, exit@0x3d8) 与 vivo 内核
对齐。结果: **模块加载成功, 为 GKI 6.1.159 编译的闭源驱动直接 insmod
成功** —— 项目目标达成, 全程未触碰任何分区。

### 第 7 步 · 多 KMI 自动适配 (v0.2.0)

"这个模块只能我的手机用吗?" —— ddk 本就支持按 KMI 构建官方 GKI:

- CI 矩阵为 android14-6.1 / android13-5.15 / android14-5.15 /
  android15-6.6 各出一个 ko;
- `package-all` 作业把全部 ko 汇总进一体包 (`kos/` 目录), 设备端
  `select_ko()` 按 `uname -r` 自动选择;
- 工程化: action.sh 手动开关 / service.sh 自启 (默认关, 带熔断) /
  加载流程并发锁; 发布 v0.2.0 Release (5 资产 + SHA-256)。

顺带踩坑: `download-artifact@v4` 会自动解包, 汇总作业一开始还想再解
第二层 zip, 报 "no item named ... in the archive"。

### 第 8 步 · 社区反馈修复 (v0.2.1)

同机型用户 OTA 到 `6.1.145` 后报「没有适配本机内核的 ko」—— KMI 明明
还是 android14-6.1, 不该报。真因: 他装的是**单 KMI 包** (ko 在模块根
目录), 而 v0.2.0 的加载脚本只认一体包的 `kos/` 布局。修复:

- `select_ko()` 双布局回退 (kos/ 优先, 根目录兜底);
- 报错细分: 「KMI 不识别」与「模块目录里找不到 ko 文件」分开提示;
- vermagic 缩短前缀改为取设备真实 release, 不再硬编码。

同时印证了 GKI 的承诺: **同 KMI 小版本 OTA (6.1.124 → 6.1.145) 无需
新 ko**, ko 通用。

### 第 9 步 · WebUI 与 CRC 开关 (v0.3.0)

加入 `check_version()` kretprobe 与 WebUI 控制页:

- 内核模块暴露 `vermagic` / `crc` 两个 bool 参数, 默认都是 0;
- WebUI 开关写入 `/data/adb/modules/opensesame/config.conf`, 模块已加载时
  同步写 sysfs 参数, 立即生效;
- 开机自启改为独立开关, 只在 `auto_start=1` 且至少一个校验开关打开时加载;
- WebUI 下方展示脚本日志与 `dmesg` 中的 opensesame 内核日志。

## 实战状态

| 设备 | 内核 | 状态 |
|---|---|---|
| vivo PD2339M / iQOO Neo9S Pro (MT6989) | 6.1.124-android14-11-maybe-dirty | 模块加载成功, 为 6.1.159 GKI 编译的闭源驱动成功加载 |
| 其他 GKI 设备 | 见支持范围 | 理论可用, 欢迎实测反馈 issue |

## 支持范围与 KMI 自动适配

- 架构: arm64, GKI 内核;
- **同 KMI 内小版本 OTA (如 6.1.124 → 6.1.145) 不需要新 ko**: GKI 承诺
  同 KMI 分支 ABI 稳定, 加载脚本按 `uname -r` 自动选择; 跨 KMI 才需要
  对应 KMI 的 ko。

| KMI | 状态 |
|---|---|
| android14-6.1 | 预编译, 实战验证 |
| android13-5.15 | 预编译 |
| android14-5.15 | 预编译 |
| android15-6.6 | 预编译 |
| android12-5.10 / android13-5.10 / android16-6.12 | ddk 支持, 未纳入矩阵, 需要时在 workflow 里追加 |

前提: 内核启用 CONFIG_KPROBES, 且 kallsyms 保留对应目标符号。
`vermagic` 需要 `same_magic`, `crc` 需要 `check_version`; 若目标函数被
编译器内联, 对应开关会拒绝开启。不确定请跑探测脚本:

```bash
adb push scripts/probe.sh /data/local/tmp/
adb shell "su -c 'sh /data/local/tmp/probe.sh'"
```

## 使用方法

1. **禁止本地编译**: push 到 `main` 后 GitHub Actions 自动矩阵构建
   (或手动 workflow_dispatch), 从产物/Release 下载:
   - `OpenSesame-all-kmi` —— 全 KMI 一体包 (推荐, 装哪个机型都行);
   - `OpenSesame-<kmi>` —— 单 KMI 包, 须与设备 KMI 一致
     (两种包布局 v0.2.1 起均支持自动选择);
2. SakiSU / KernelSU 管理器安装;
3. **安装后两个校验开关和开机自启默认全关**。进入模块 WebUI:
   - `vermagic 校验放行`: 放行 vermagic 不匹配;
   - `符号 CRC 校验放行`: 放行 `check_version()` 的 CRC 不匹配;
   - `开机自动加载`: 下次开机自动应用当前已打开的两个校验开关;
4. 点 WebUI 的「加载模块」或管理器里的「操作」按钮应用当前开关;
5. 加载成功后, 直接跑你的驱动安装脚本即可。

## 免解锁 (漏洞 root) 设备适用性

OpenSesame 本质是"以 root 身份执行 `insmod opensesame-<KMI>.ko`",
**不关心 root 的来源**。靠内核漏洞加载 LKM (如 ksu.ko) 拿到 root 的
免解锁设备, 与解锁 BL 的设备对模块而言环境一致:

- 能被漏洞塞进 ksu.ko 的内核, 必然满足本模块的全部前提 (CONFIG_MODULES
  开启、无签名强制、kprobe 可用) —— 两者的门槛是同一层;
- KernelSU 系 su 是内核态放行的, 授予 CAP_SYS_MODULE + SELinux 放行,
  模块脚本 insmod 的权限路径与加载 ksu.ko 本身一致;
- 模块布局: ddk 按标准 GKI 配置编译, 锁 BL 设备跑的就是原厂 GKI, 布局
  天然匹配。

差异点: 有管理器就正常刷模块 zip (service.sh 自启可用); 纯漏洞环境
没有模块管理器的话, 解压 zip 手动 `insmod kos/opensesame-xxx.ko` 同样
生效, 只是每次重启后需手动重新加载 (ko 是内存态的, 重启即失效, 这反而
是安全网)。

## 防 bootloop 设计

内核交互全部为 RAM-only (kretprobe 钩子), 重启即归零, 最坏情况是循环
重启而不是砖。四道保险:

1. 默认不自动加载, 验证后再打开 WebUI 的开机自启;
2. 自动加载发生在开机末尾 (service.sh + 20s 延迟);
3. 熔断: 连续 2 次"加载后 60 秒内系统未稳定"就拒绝自动加载;
4. 加载流程持并发锁, 杜绝双脚本竞争 (曾实测导致 mod_sysfs_setup 崩溃)。

## 排查

```bash
su -c 'dmesg | grep opensesame'        # 模块自身日志
su -c 'cat /sys/fs/pstore/console-ramoops-0 | tail -c 6000'   # 上次崩溃现场
```

常见失败:

- `same_magic 放行开关开启失败` = 内核把 same_magic 内联了 (vermagic
  开关不可用);
- `CRC 放行开关开启失败` = 内核没有可 hook 的 check_version 符号 (CRC
  开关不可用);
- `disagrees about version of symbol` = CRC 开关未打开, 驱动 ABI 与内核
  不兼容, 被内核正确拦截;
- `模块目录里找不到 ko 文件` = 装了 v0.2.0 及更早的**单 KMI 包**
  (旧版加载脚本只认一体包的 kos/ 布局) —— 更新模块到 v0.2.1+,
  或改装 `OpenSesame-all-kmi` 一体包;
- `没有适配本机内核 (...) 的 KMI` = uname -r 未匹配任何 KMI 模式,
  到仓库用 CI 构建对应 KMI 的模块包。

## 封号风险与安全边界

对"会不会导致游戏封号 / 动内存 / 有残留"的诚实回答:

**动了什么内存**: 模块加载后只按开关在内核的 `same_magic()` /
`check_version()` 入口挂 kretprobe, 返回时改写寄存器 x0。不扫描、不读写
任何进程的内存 (包括游戏), 不 hook 系统调用, 不改 LSM。唯一涉及内核
内存的是 kprobes 框架自己在函数入口放的断点指令 (标准框架行为),
`rmmod` 时由框架自动还原。

**残留**: 内核侧 rmmod 即归零 (kprobe 注销 + 指令还原), 重启更是物理
归零 (RAM-only)。磁盘侧全部文件都在 `/data/adb/modules/opensesame/`,
不写 /system、/vendor、boot 等任何系统分区 —— 本项目从设计上就从未
刷过任何分区。应用数据不读不写。

**封号风险排序** (反作弊查的是"这台手机是否 root"):

1. root 环境本身 (SakiSU/KernelSU 的 su、管理器、/data/adb) —— 最大头,
   与本模块无关, 装不装 OpenSesame 这些特征都在;
2. 你加载的闭源驱动 —— 它们是插进内核的第三方模块, 闭源且安全性无从
   审计, 风险自担;
3. OpenSesame 本身 —— 加载期间 /proc/modules 多一个模块 + 一个或两个
   kprobe, 普通应用因 SELinux 限制读不到 /proc/modules, 且卸载即消失。

对封号敏感的游戏, 不放心就在进游戏前把模块开关切到卸载并 rmmod 掉
已加载的驱动 (无需重启)。无法承诺任何反作弊检测结果 —— 这是对抗性
问题, 但"随时可完全撤除、无持久化、不碰游戏"这三点由代码和机制保证。

## 已知限制

- 各厂商对 GKI 的魔改程度不同, 结构体布局极端偏离 GKI 的内核上, ko 自身
  可能无法加载 (实测 case: 见演进历程第 5 步的 pstore 分析);
- `same_magic` 或 `check_version` 被内联时, 对应开关不可用;
- 放行 vermagic 后, 加载来源不明的 `.ko` 风险自担; 打开 CRC 开关后,
  原本会被 ABI 指纹挡住的模块也可能进入内核;
- 加载期间在 /proc/modules 可见, 不做隐藏;
- 仅用于自有设备的实验与研究, 请遵守当地法律法规。

## 目录结构

```
open-sesame/
├── kernel/                    # 内核补丁模块源码 (ddk 云端矩阵构建)
│   ├── opensesame.c           # kretprobe 实现 (全部逻辑不到 100 行)
│   └── Makefile
├── module/                    # SakiSU/KernelSU 模块
│   ├── module.prop
│   ├── customize.sh           # 安装脚本 (arm64 检查)
│   ├── common.sh              # 配置读写 / KMI 识别 / vermagic 学习回写 / 加载
│   ├── control.sh             # WebUI 控制入口: 状态 / 开关 / 加载 / 日志
│   ├── action.sh              # 「操作」按钮: 手动加载/卸载
│   ├── service.sh             # 开机自动加载 (默认关, 带熔断)
│   ├── webroot/               # KernelSU 模块 WebUI
│   └── uninstall.sh
├── scripts/
│   ├── probe.sh               # 设备侧支持性自测 (符号/vermagic/配置)
│   └── patch_boot.py          # (已废弃的) boot 镜像补丁器, 留档
└── .github/workflows/build.yml  # ddk 矩阵构建 + 一体包汇总
```

## 致谢

- vermagic 运行时适配思路来自
  [SakiSU](https://github.com/XingChenRS/SakiSU) 的 ksuinit;
- 构建环境来自 [5ec1cff/ddk](https://github.com/5ec1cff/ddk)
  (SakiSU 官方 LKM 同款);
- 内核取证工具: [vmlinux-to-elf](https://github.com/marin-m/vmlinux-to-elf)
  (从设备 boot 镜像还原 kallsyms)。

## License

GPL-2.0-only
