# SpironolactonePlus

基于 [Orangera1n/spironolactone](https://github.com/Orangera1n/spironolactone) 的个人强化分支。原项目用于引导 dualboot、SSH ramdisk 和 tether 降级（当前主要支持 SSH ramdisk 的生成与引导）。本分支在 2026-07 做了全面的工程整合与加固，并沉淀了 A12 设备 ramdisk 的研究成果，行为与上游已不完全相同。

## 与上游的差异（本分支的强化）

- **数据驱动的引导链**：每个 bootchain 目录带一份 `boot_order.json` 描述发送序列，`spiro.sh` 按序执行；无 JSON 时回退到与上游逐字节一致的 legacy 序列（有 dry-run 回归测试强制保证）
- **全链路超时 + 失败即停**：每次 irecovery/usbliter8 调用默认 15s，大文件（ramdisk/kernelcache）90s，`SPIRO_IRECV_TIMEOUT` 可覆盖
- **前置检查与安全闸**：引导前检查 PWND DFU 状态；`--dry-run` 无设备离线演练；危险 boot-args（`nand-enable-reformat`/`oblit`/`wdt=0`）默认拒绝执行，`ALLOW_DANGEROUS_BOOTARGS=1` 显式覆盖
- **构建脚本非交互化**：`makebootfiles.sh` 支持 `--type/--bootargs/--dualboot-disk/--im4m` 参数与 `SPIRO_*` 环境变量（TTY 下保持原交互习惯）；BuildManifest 按 DeviceClass 精确匹配（修复 beta 清单拿错固件的致命问题）；构建结束自动生成 `boot_order.json`
- **共享库 `lib/`**：统一日志、`run_timeout`、设备检测（557 条 iBoot→iOS 映射、机型识别）
- **设备端挂载助手** `resources/mount_helpers.sh`：按 APFS 卷标探测挂载 System/Preboot/xART，每次挂载 20s 超时，oblit nvram 守卫；**遵守 A12 禁令（绝不调用 seputil）**；Data 卷默认拒绝（SEP BPR 限制），`--try-data` 才带守卫尝试
- **主机端挂载校验器** `scripts/validate_mounts.sh`：READY / WARNINGS / FAIL 三级结论
- **`ssh.sh` 增强**：`push-helpers` 一键推送挂载助手、端口占用检测、无参数时正确进入交互 shell
- **离线测试套件**：`bash tests/run_tests.sh`，7 个套件，无需设备
- **研究沉淀**（本地保留，不上传）：`RESEARCH_A12_MNT2.md`（A12 挂载 Data 的 BPR 结论与 10 组实验矩阵）、`research/unlockcd/`（UnlockCD 工具逆向分析报告与提取物）

## 重要说明

1. 仅支持 usbliter8 兼容设备（A12、A13）；A12X/Z 因缺偏移未实现；A14+ 基本不会支持
2. iBoot patch 现状：A12 支持 iOS 12.0–14.4.2，A13 支持 iOS 13.0–13.7，请勿询问新版本的 ETA
3. **A12 的 ramdisk 内严禁调用任何 seputil**（SEPOS 双初始化 → kernel panic）
4. A12 在 DFU 上下文中挂载 iOS ≤17 创建的 Data 卷目前不可行（SEP BPR 在 DFU 时锁定用户数据密钥），详见 `RESEARCH_A12_MNT2.md`
5. 需要 macOS（Linux 理论易移植但未实现）和一块 RP2350 开发板（推荐 Waveshare RP2350A USB Mini）

## 用法

0. 给 RP2350 刷写 [usbliter8 1.0 固件](https://github.com/prdgmshift/usbliter8/releases/tag/1.0)
1. 获取固件密钥 JSON：到 [theapplewiki](https://theapplewiki.com/wiki/Firmware) 找到你的 iOS 版本页面 → 设备型号页面 → 下载 keys json
2. 克隆本仓库并 `cd spironolactonePlus`
3. 构建 bootchain：
   ```bash
   ./makebootfiles.sh <iOS版本或IPSW地址> <固件密钥.json> \
     --type ramdisk --bootargs neither
   ```
   （`--type ramdisk|dualboot|downgrade`、`--bootargs verbose|serial|neither`、`--dualboot-disk`、`--im4m`；也可用 `SPIRO_TYPE` 等环境变量；不传参数且终端交互时保持原问答模式）
4. 引导：
   ```bash
   ./spiro.sh boot <chain>             # 按 bootchain/<chain>/boot_order.json 执行
   ./spiro.sh boot <chain> --dry-run   # 无设备离线演练序列
   ```
5. SSH 与挂载：
   ```bash
   ./ssh.sh                            # 交互 shell（密码 alpine）
   ./ssh.sh push-helpers               # 推送挂载助手到设备
   ./ssh.sh 'sh /var/root/mount_helpers.sh'          # 挂载 System/Preboot/xART
   ./ssh.sh 'sh /var/root/mount_helpers.sh --try-data'  # 带 20s 守卫尝试 Data
   ./scripts/validate_mounts.sh        # 主机端校验挂载结果
   ```
6. 运行离线测试：`bash tests/run_tests.sh`

## 目录结构

```
makebootfiles.sh     构建 bootchain（下载/解密/补丁/打包 + 生成 boot_order.json）
spiro.sh             引导执行器（JSON 驱动 + legacy 回退 + 超时 + 安全闸）
ssh.sh               SSH 入口（iproxy 管理 + push-helpers）
lib/                 共享库（日志/超时/设备检测）
resources/           ssh.tar、IM4M、iboot_mapping.json、mount_helpers.sh
scripts/             validate_mounts.sh 等主机端工具
bootchain/           构建产物（gitignored，boot_order.json 除外）
tests/               离线测试套件
Darwin/              macOS 预置工具（irecovery/img4/kairos/pzb 等）
```

## 致谢

- 上游项目 [Orangera1n/spironolactone](https://github.com/Orangera1n/spironolactone) 及其作者
- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice)（libirecovery、iproxy）
- [Duy Tran](https://github.com/AldazActivator)（devicetree-parse）
- [Nathan](https://github.com/verygenericname)（[sshtars](https://github.com/verygenericname/sshtars/)、[SSHRD_Script](https://github.com/verygenericname/)）
- [Paradigm Shift](https://github.com/prdgmshift)（[usbliter8](https://github.com/prdgmshift/usbliter8)）
- [tihmstar](https://github.com/tihmstar)（pzb、iBoot64Patcher、img4tool）
- [xerub](https://github.com/xerub)（img4lib、restored_external）
- [Cryptic](https://github.com/Cryptiiiic)（iBoot64Patcher fork）
- [opa334](https://github.com/opa334)（TrollStore）
- [AldazActivation](https://github.com/AldazActivator)（usbliter8_boot）
- 本分支的研究参考：Pa7r0n/ICH_A12_plus_Ramdisk、ElcomSoft usbliter8/ipwndfu_usbliter8、Leeksov usbliter8ra1n
