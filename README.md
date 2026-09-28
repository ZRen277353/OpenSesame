# OpenSesame

> 芝麻开门 —— 让内核放行 vermagic 校验不通过的内核模块

一个 SakiSU / KernelSU 模块, 内含一个内核补丁模块 (`.ko`): 加载后把内核里负责
比对 vermagic 的 `same_magic()` 改写为恒返回 true, 此后 `insmod` 一个 vermagic
不匹配的 `.ko` 不再报 `Exec format error`。

**只放行 vermagic, 不动符号 CRC (CONFIG_MODVERSIONS) 校验** —— ABI 不兼容的
模块依然会被内核正常拒绝, 这是本项目的安全边界。

## 原理

```
insmod xxx.ko
  └─ check_modinfo() ── same_magic()   ← patch 成 mov w0,#1 ; ret (恒真)
                             │
                             └─ vermagic 不匹配 => 原本返回 -ENOEXEC ("Exec format error")
```

- `same_magic()` 是静态函数, 通过 kprobe 按符号名在 `/proc/kallsyms` 中定位;
- `aarch64_insn_patch_text()` 未导出, 同样通过 kprobe 取地址后按原型调用
  (内核开启 CFI 时按类型哈希校验, 原型一致即可通过);
- patch 前**校验原始指令** (全零/已 patch 等异常直接放弃), `rmmod` 时还原;
- 默认 dry-run (`enable=0`), 只探测不改内核。

模块加载器自带 vermagic 适配 (ksuinit 同款思路): CI 构建时用超长
`LOCALVERSION` 把 `.ko` 的占位 vermagic 拉长, 设备侧优先从厂商模块读取真实
vermagic, 兜底从一次失败 insmod 的 kmsg 里解析 `should be '...'`, 然后**原地
回写**到 `.ko` 再加载。

## 当前支持范围 (v0.1)

| 项 | 要求 |
|---|---|
| 架构 | arm64 |
| 内核 | GKI 6.1 (`android14-6.1` 分支构建; 其他分支改 workflow 的 `KVER`) |
| 前提 | 内核启用 CONFIG_KPROBES + CONFIG_KALLSYMS, 且 **kallsyms 保留了 `same_magic` 符号** (若被编译器内联则不受支持) |

不确定自己的设备行不行? 跑一下探测脚本:

```bash
adb push scripts/probe.sh /data/local/tmp/
adb shell "su -c 'sh /data/local/tmp/probe.sh'"
```

## 使用方法

1. 本仓库**禁止本地编译**, 所有构建由 GitHub Actions 完成: push 到 `main` 后
   自动构建, 或在 Actions 页面手动触发 (workflow_dispatch);
2. 从 Actions 的构建产物里下载 `OpenSesame-android14-6.1.zip`;
3. SakiSU / KernelSU 管理器安装该 zip;
4. **安装后默认不自动加载、不改内核**。到管理器里点本模块的「操作」按钮:
   第一次点击 = 手动加载 + 启用开机自动加载; 再点一次 = 卸载 + 关闭。

## 防 bootloop 设计

内核补丁全部在内存中 (RAM-only), 重启即归零, 最坏情况是循环重启而不是砖,
`fastboot flash init_boot` 刷回备份镜像即可 100% 恢复。模块自带四道保险:

1. 默认不自动加载, 必须先手动验证 (action 按钮);
2. 自动加载发生在开机末尾 (service.sh + 20s 延迟), panic 代价最小;
3. 熔断: 连续 2 次"加载后 60 秒内系统未稳定"就拒绝自动加载;
4. `.ko` 内部防呆: patch 前比对原始指令, 不盲写; `rmmod` 可还原。

## 目录结构

```
open-sesame/
├── kernel/                    # 内核补丁模块源码 (CI 云端编译)
│   ├── opensesame.c
│   └── Makefile
├── module/                    # SakiSU/KernelSU 模块 (打包进 zip)
│   ├── module.prop
│   ├── customize.sh           # 安装脚本
│   ├── common.sh              # vermagic 学习/回写 + 加载逻辑
│   ├── action.sh              # 管理器「操作」按钮: 手动加载/卸载开关
│   ├── service.sh             # 开机自动加载 (默认关, 带熔断)
│   └── uninstall.sh
├── scripts/
│   └── probe.sh               # 设备侧支持性自测
└── .github/workflows/build.yml
```

## 已知风险

- 若 `same_magic` 已被内联, kallsyms 无此符号, 模块会明确报错退出 —— 此时
  请勿尝试其他手段强改内核;
- 放行 vermagic 后, 加载来源不明的 `.ko` 风险自担 (CRC 校验仍在, 但 CRC 相同
  不代表行为无害);
- 仅用于自有设备的实验与研究, 请遵守当地法律法规。

## 致谢

vermagic 学习/回写的思路来自 [SakiSU](https://github.com/XingChenRS/SakiSU)
的 ksuinit (runtime vermagic auto-adaptation)。

## License

GPL-2.0-only
