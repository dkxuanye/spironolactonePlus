#!/bin/bash
# preflight_18x.sh - verify all Phase 0 assets are in place and print the manual upgrade checklist.
set -u
oscheck="${SPIRO_OSCHECK:-$(uname)}"
ICH_ROOT="${ICH_ROOT:-$HOME/Desktop/ICH_A12_plus_Ramdisk}"
CHAIN_DIR="${CHAIN_DIR:-$ICH_ROOT/bootchain/n841ap-18.7.9-22H355-ramdisk}"
. lib/common.sh

fails=0
chk(){ # chk <desc> <rc>
    if [ "$2" -eq 0 ]; then log "$1"; else warn "MISSING: $1"; fails=$((fails+1)); fi
}

echo "=== Phase 0 preflight ==="
[ -d "$CHAIN_DIR" ]; chk "ICH chain dir" $?
for f in iBoot.patched.bin sep-firmware.img4 devicetree.img4 trustcache.img4 ramdisk.img4 kernelcache.img4 AOP.img4 ANE.img4 AVE.img4 ISP.img4 GFX.img4 SIO.img4; do
    [ -s "$CHAIN_DIR/$f" ]; chk "chain: $f" $?
done
[ -x "$ICH_ROOT/boot.sh" ]; chk "ICH boot.sh" $?
[ -f resources/mount_experiment_18.sh ]; chk "device experiment script" $?
[ -x scripts/experiment_18x_mount.sh ]; chk "host orchestrator" $?
[ -f bootchain/ich-18.7.9/boot_order.json ]; chk "spiro alt-path JSON" $?
[ -e bootchain/ich-18.7.9/kernelcache.img4 ]; chk "spiro alt-path symlinks resolve" $?
for t in iproxy sshpass irecovery jq usbliter8_boot; do
    [ -x "$oscheck/$t" ]; chk "tool: $t" $?
done
command -v lsof >/dev/null 2>&1; chk "tool: lsof (system)" $?

echo
if [ "$fails" -gt 0 ]; then
    warn "preflight: $fails missing items — fix before proceeding"
    exit 1
fi
log "all assets present"
cat <<'EOF'

=== 手动升级清单（用户执行，不可逆）===
1. 备份设备个人数据（照片等）
2. 用 Finder/iTunes 或爱思将 XR 保资料升级到 iOS 18.7.9 (22H355)
   （当前唯一签名版本；update 保资料，不要选 restore）
3. 升级后确认：
   - 设备正常激活进系统
   - ideviceinfo | grep ProductVersion 应为 18.7.9
4. 设备进 DFU（RP2350 接好，irecovery -q 应有 PWND: usbliter8）
5. 依次执行实验：
   bash scripts/experiment_18x_mount.sh --mode ich-safe
   bash scripts/experiment_18x_mount.sh --mode unlockcd
   bash scripts/experiment_18x_mount.sh --mode unlockcd-R
   bash scripts/experiment_18x_mount.sh --mode unlockcd-chain-sep
6. 把四条 RESULT 行发回来，结论写入 RESEARCH_A12_18X.md
EOF
