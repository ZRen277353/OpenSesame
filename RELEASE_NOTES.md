# OpenSesame v0.3.0 更新报告

> 芝麻开门: 可开关放行 `vermagic` 与符号 CRC 校验, 增加 KernelSU / SakiSU WebUI 控制。

## 更新内容

### 新增

- 新增符号 CRC 放行开关: hook `check_version()`, 打开后返回成功。
- 新增 WebUI 控制页: 控制模块加载、vermagic 放行、CRC 放行、开机自启。
- 新增 WebUI 日志区: 可查看脚本日志和 `dmesg` 中 opensesame 的内核日志。
- 新增持久配置: 开关状态写入模块目录 `config.conf`, 重启后保留。

### 调整

- 所有功能默认关闭: 安装后不会自动加载, 也不会改变内核校验行为。
- 模块「操作」按钮改为总开关: 加载当前 WebUI 已启用的校验放行功能, 或卸载模块。
- 开机自启改为 WebUI 独立开关: 只有开启自启且至少打开一个校验开关时, 开机才会加载。
- 内核模块现在暴露 `vermagic` / `crc` 两个 sysfs 参数, 模块已加载时可动态开关。
- CI 打包流程会携带 `webroot/`, 确保安装包内包含 WebUI。

### 安全说明

- `vermagic` 放行只绕过版本字符串校验, 风险相对低。
- `crc` 放行会跳过符号 ABI 指纹校验。布局不兼容的模块也可能进入内核, 可能导致报错或内核崩溃。
- 不需要 CRC 放行时请保持 `crc` 开关关闭。

## 升级提示

v0.2.x 升级到 v0.3.0 后, 所有开关默认关闭。需要到模块 WebUI 中重新选择要启用的校验开关, 再点击「加载模块」或管理器里的「操作」按钮应用。

## 支持范围

| 下载 | 适用内核 |
|---|---|
| **OpenSesame-all-kmi.zip (推荐)** | android14-6.1 / android13-5.15 / android14-5.15 / android15-6.6, 设备端按 `uname -r` 自动选择 |
| OpenSesame-android14-6.1.zip | 6.1 GKI |
| OpenSesame-android13-5.15.zip | 5.15 GKI, Android 13 |
| OpenSesame-android14-5.15.zip | 5.15 GKI, Android 14 |
| OpenSesame-android15-6.6.zip | 6.6 GKI, Android 15 |

前提: arm64 + `CONFIG_KPROBES`。`vermagic` 开关需要 `same_magic` 符号, `crc` 开关需要 `check_version` 符号; 不确定时先运行 `scripts/probe.sh`。

## 使用方式

1. SakiSU / KernelSU 管理器安装 zip。
2. 打开模块 WebUI。
3. 按需打开 `vermagic 校验放行` / `符号 CRC 校验放行`。
4. 点击 WebUI 的「加载模块」或管理器里的「操作」按钮。
5. 确认稳定后再打开「开机自启」。
6. 在 WebUI 底部日志区查看开关状态、脚本输出和内核日志。

## 本次构建

- Workflow: `Build OpenSesame #13`
- Commit: `a6a316861332e573c306cc31db8da0b620f76d37`
- Run: https://github.com/ZRen277353/OpenSesame/actions/runs/37617671549

## SHA-256

```text
e30dc1652af128381bd95e2bdda802b9045af7ba28df7d11463f37e975102c1c  OpenSesame-all-kmi.zip
8ac5acefec71fafab6c425d89c4274f4cea42d0b6f5f6f9789fb6d1467f07458  OpenSesame-android14-6.1.zip
9e179e314a9e732b3dde2d075a2c66dcd5595b0128a2dbaf928a8490e5d122a6  OpenSesame-android13-5.15.zip
40aff003f987e6ecc730f2e7e7dfe546e66558f126a53bbddc09c8f785a9357c  OpenSesame-android14-5.15.zip
6f5c8f662a8a312f6a78401aebb0f839ac5b00a2542c87793d27c75f00f65528  OpenSesame-android15-6.6.zip
```
