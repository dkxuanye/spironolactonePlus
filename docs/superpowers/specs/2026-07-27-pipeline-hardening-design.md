# Spironolactone 流程加固（Track A）设计文档

> 日期：2026-07-27
> 来源：UnlockCD Ramdisk V1.0.2 分析（见 `research/unlockcd/REPORT.md`）+ `RESEARCH_A12_MNT2.md` 研究结论
> 状态：设计已获用户确认（2026-07-27），待实施计划

## 1. 目标与边界

在已验证可用的 14.4.2 链（`bootchain/n841ap-14.4.2-18D70-ramdisk` + `./spiro.sh boot`）之上做纯工程加固，把 UnlockCD 的工程纪律（数据驱动、全超时、卷标探测、结果校验、危险 flag 闸）移植到本项目。

**不引入任何未验证的底层行为**：

- 不调用任何 seputil（A12 禁令，`RESEARCH_A12_MNT2.md` 坑 #3：ramdisk 内 `seputil --load` → SEPOS 双初始化 → panic）
- 不改动 iBoot patch 管线（iBoot64Patcher_cryptic + kairos）
- Data 卷（/mnt2）挂载保持"默认拒绝"，BPR 结论（坑 #4、实验 #1–#10）不变

**明确不做（YAGNI）**：动态 SEP 远程下载（Track B）、iOS 18.x ramdisk 链（Track C）、dualboot/downgrade 功能变更、Linux 支持。

## 2. 组件一：`boot_order.json` 数据驱动引导

### 2.1 格式

借鉴 UnlockCD（`research/unlockcd/bootchain/iPhoneXR_18.3/boot_order.json`），每个 bootchain 目录一份：

```json
{
  "version": 1,
  "sequence": [
    {"action": "command",   "command": "setenv auto-boot false", "send_order": 0},
    {"action": "component", "name": "RestoreSEP",   "filename": "sep-firmware.img4", "irecv_command": "rsepfirmware", "send_order": 1},
    {"action": "component", "name": "DeviceTree",   "filename": "devicetree.img4",   "irecv_command": "devicetree",   "send_order": 2},
    {"action": "component", "name": "RestoreRamDisk","filename": "ramdisk.img4",     "irecv_command": "ramdisk",      "send_order": 3}
  ]
}
```

（上例为格式示意，仅列前 4 步；实际 JSON 含 trustcache/AOP/ANE/AVE/ISP/GFX/SIO/kernelcache 全序列。）

现有 `spiro.sh` 的硬编码顺序（SEP `rsepfirmware` 在 iBoot 之后、devicetree 之前，见 `spiro.sh:19-26` 的 ICH issue #5 注释）固化为两个既有 bootchain 目录的 JSON，行为逐字节不变。

### 2.2 spiro.sh 执行器

- 用 `Darwin/jq` 解析 JSON，按 `send_order` 排序逐步执行
- 每个 component 步骤执行前三件事：
  1. 文件存在且前 32 字节含 IMG4/IM4P magic（复用 UnlockCD `is_img4_or_im4p` 的 xxd 探测法）
  2. `irecovery -f` / `irecovery -c` 调用包**超时**（macOS 无 GNU timeout，用后台 + 轮询 + kill 的纯 shell 写法，参照 `research/unlockcd/scripts/remote_mount_old.sh:8-25` 的 `run_bg_timeout`）：普通组件/命令默认 15s，大文件（ramdisk.img4、kernelcache.img4）默认 90s，可用 env `SPIRO_IRECV_TIMEOUT` 覆盖
  3. 任一步失败即停，红字打印失败步骤与日志路径
- **兼容回退**：bootchain 目录无 `boot_order.json` 时走现有硬编码序列（输出与现状一致），打印一行迁移提示

### 2.3 boot-args 安全闸

- JSON 中出现 `setenv boot-args ...` 命令时，执行前扫描危险 flag：`nand-enable-reformat`、`oblit-*`、`wdt=0`
- 命中即拒绝执行并说明原因；显式 `ALLOW_DANGEROUS_BOOTARGS=1` 才放行
- boot-args 的主要注入点维持现状（makebootfiles.sh 里 kairos `-b` 打入 iBEC），安全闸只针对 JSON 命令通道

## 3. 组件二：`makebootfiles.sh` 非交互化

- 三个 `read` 提示（`makebootfiles.sh:46-49` 类型/ bootargs、`:115` dualboot 盘符、`:147` IM4M 路径）改为参数 + 环境变量：
  - `--type ramdisk|dualboot|downgrade`（env `SPIRO_TYPE`）
  - `--bootargs verbose|serial|neither`（env `SPIRO_BOOTARGS`）
  - `--dualboot-disk disk0s1sN`（env `SPIRO_DUALBOOT_DISK`）
  - `--im4m <path>`（env `SPIRO_IM4M`）
- 缺参数且 stdin 是 TTY 时回退到现有交互提问（老用户习惯不变）；stdin 非 TTY 且缺参数时明确报错列出缺项
- 纯重构：重复 7 次的 `plutil -extract ... | grep '<string>' | cut` 管线收敛为 `bm_path <index> <component>` 辅助函数，输出逐字节不变
- 构建结束时按 §2.1 格式生成 `boot_order.json` 写入 `bootchain/<dir>/`

## 4. 组件三：设备检测库 `lib/device.sh`

新增 `lib/device.sh`，被 `makebootfiles.sh`、`spiro.sh` source。函数实现直接取自 `research/unlockcd/scripts/start.sh` 的同名单元（已验证）：

- `query_device` / `get_field <q_text> <key>` / `normalize_hex`
- `is_pwned_dfu`（检查 `PWND:`）
- `detect_iboot_version` / `map_iboot_to_ios`（查表）
- `map_product_to_model`（PRODUCT/MODEL/BDID → 机型名）

配套：

- `research/unlockcd/app/iboot_mapping.json` 复制到 `resources/iboot_mapping.json`
- `makebootfiles.sh:14,20-26` 共 4 处 `irecovery -q | grep | sed` 替换为库调用
- `spiro.sh` 增加 pre-flight：`is_pwned_dfu` 失败时明确报错退出（现状是盲目 `usbliter8_boot`）

## 5. 组件四：A12 安全的挂载助手 + 校验器

### 5.1 `resources/mount_helpers.sh`（设备端 sh 脚本）

模式参照 `research/unlockcd/scripts/remote_mount_dynamic.sh`，但遵守 A12 禁令：

- **禁止调用任何 seputil / gigalocker**（与本项目研究结论一致；UnlockCD 的流程面向 18.x 栈，不可照搬到 14.x）
- `apfs.util -p` 按卷标（System/Preboot/xART）在 `/dev/disk0s1s*` 与 `/dev/disk1s*` 两套前缀探测，挂载 System→/mnt1、Preboot→/mnt6、xART→/mnt7，每次 mount 带 20s 超时（后台 + kill）
- 幂等：先查 mount 表，已挂载则跳过
- Data 卷：**默认拒绝**（BPR 已知挂死）；显式 `--try-data` 才以后台 + 20s 超时 + 自动 kill 尝试，随后做 `/mnt2/{mobile,root,containers}` 目录级存在校验（防止挂出空壳卷）
- oblit 守卫：开始/结束时 `nvram -d oblit-inprogress`、`nvram -d obliteration`、`nvram auto-boot=true`；检测到 boot-args 含 `nand-enable-reformat` 时拒绝一切挂载（exit 76）
- 日志前缀 `[spiro-mount]`，每步有回显

### 5.2 `scripts/validate_mounts.sh`（host 端校验器）

- 经现有 SSH 隧道（`ssh.sh` 的 iproxy + root/alpine）在设备上执行检查：
  - /mnt1：关键系统路径存在（如 `usr/standalone/firmware`）
  - /mnt6：`active` 文件存在且指向有效目录
  - /mnt7：gigalocker 目录存在
- 输出三级结论：`READY` / `WARNINGS` / `FAIL`（`research/unlockcd/app/mnt2_validator` 的精简版）

### 5.3 投递方式

- 不改动 `resources/ssh.tar.gz`、trustcache 追加流程与 ramdisk 构建链（零风险）
- `ssh.sh` 增加 `push-helpers` 子命令：scp 推送 `mount_helpers.sh` 到设备 `/var/root/`，并提示用法

## 6. 错误处理与日志

- `makebootfiles.sh`、`spiro.sh`、`ssh.sh` 统一：`set -u`、`die()` 红字报错（含出错步骤）、步骤日志写入 `work/logs/<YYYYMMDD_HHMMSS>.log`，失败时打印日志路径

## 7. 验证方式

- `spiro.sh` 新增 `--dry-run`：只打印将执行的序列不发送。回归标准：既有两个 bootchain 目录（JSON 路径）与回退路径的 dry-run 输出逐行 diff 为空
- `makebootfiles.sh` 重构后：`bm_path` 输出与原管线输出 diff 为空（用既有 `work/` 目录残留比对）
- 真机冒烟（用户执行）：14.4.2 链 boot → `./ssh.sh` → `./ssh.sh push-helpers` → 设备端跑 `mount_helpers.sh` 挂 /mnt1/mnt6/mnt7 → `validate_mounts.sh` 输出 READY；`--try-data` 须在 20s 内被自动 kill 且设备不 panic、SSH 不断线

## 8. 影响文件清单（预估）

| 文件 | 改动 |
|---|---|
| `spiro.sh` | JSON 执行器 + 超时 + pre-flight + --dry-run + 回退路径 |
| `makebootfiles.sh` | 参数化 + `bm_path` 重构 + 生成 boot_order.json + 库调用 |
| `ssh.sh` | `push-helpers` 子命令 |
| `lib/device.sh` | 新增 |
| `resources/iboot_mapping.json` | 新增（复制自提取物） |
| `resources/mount_helpers.sh` | 新增 |
| `scripts/validate_mounts.sh` | 新增 |
| `bootchain/n841ap-14.4.2-18D70-ramdisk/boot_order.json` | 新增（固化现有顺序） |
| `bootchain/n841ap---ramdisk/boot_order.json` | 新增（14.0b5 链） |
| `README.md` | 用法段落同步更新 |
