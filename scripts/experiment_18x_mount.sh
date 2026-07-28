#!/bin/bash
# experiment_18x_mount.sh - Phase 0 host orchestrator: boot 18.7.9 chain, run mount experiment, collect verdict.
# Usage:
#   scripts/experiment_18x_mount.sh --mode ich-safe|unlockcd|unlockcd-chain-sep [--boot ich|spiro] [--no-reboot] [--dry-run]
# Env: ICH_ROOT (default ~/Desktop/ICH_A12_plus_Ramdisk), CHAIN_DIR, SSH_PORT
set -u
oscheck="${SPIRO_OSCHECK:-$(uname)}"
ICH_ROOT="${ICH_ROOT:-$HOME/Desktop/ICH_A12_plus_Ramdisk}"
DEVICE_SCRIPT="resources/mount_experiment_18.sh"
SSH_PORT="${SSH_PORT:-2222}"
SSH_PASS=alpine

IRECOVERY="$oscheck"/irecovery
JQ="$oscheck"/jq
IBOOT_MAPPING="resources/iboot_mapping.json"
. lib/common.sh
. lib/device.sh

MODE=""; BOOT=ich; DRY=0; NO_REBOOT=0
usage() {
    echo "usage: $0 --mode ich-safe|unlockcd|unlockcd-chain-sep [--boot ich|spiro] [--no-reboot] [--dry-run]"
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) MODE="${2:?--mode needs value}"; shift 2;;
        --boot) BOOT="${2:?--boot needs value}"; shift 2;;
        --no-reboot) NO_REBOOT=1; shift;;
        --dry-run) DRY=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
    esac
done
[ -n "$MODE" ] || die "missing --mode ich-safe|unlockcd|unlockcd-chain-sep"
case "$MODE" in ich-safe|unlockcd|unlockcd-chain-sep) ;; *) die "invalid --mode: $MODE";; esac
case "$BOOT" in ich|spiro) ;; *) die "invalid --boot: $BOOT";; esac

# boot-aware chain default: spiro boots the repo-local ich-18.7.9 symlink dir (with boot_order.json)
if [ -z "${CHAIN_DIR:-}" ]; then
    if [ "$BOOT" = spiro ]; then
        CHAIN_DIR="bootchain/ich-18.7.9"
    else
        CHAIN_DIR="$ICH_ROOT/bootchain/n841ap-18.7.9-22H355-ramdisk"
    fi
fi

# --- preflight ---
[ -d "$CHAIN_DIR" ] || die "chain dir not found: $CHAIN_DIR"
[ -f "$DEVICE_SCRIPT" ] || die "device script not found: $DEVICE_SCRIPT"
CHAIN_FILES="iBoot.patched.bin sep-firmware.img4 devicetree.img4 trustcache.img4 ramdisk.img4 kernelcache.img4 AOP.img4 ANE.img4 AVE.img4 ISP.img4 GFX.img4 SIO.img4"
for f in $CHAIN_FILES; do
    [ -s "$CHAIN_DIR/$f" ] || die "chain file missing/empty: $CHAIN_DIR/$f"
done
for t in iproxy sshpass irecovery; do
    [ -x "$oscheck/$t" ] || die "tool missing: $oscheck/$t"
done
# spiro path must never fall back to the legacy built-in sequence on 18.x;
# checked before the DRY block so --dry-run catches it too
if [ "$BOOT" = spiro ]; then
    [ -f "$CHAIN_DIR/boot_order.json" ] || die "spiro boot requires $CHAIN_DIR/boot_order.json (legacy fallback is only valid for 14.x chains)"
fi
log "preflight ok: chain=$CHAIN_DIR mode=$MODE boot=$BOOT"

if [ "$DRY" = 1 ]; then
    cat <<EOF
DRYRUN plan:
  1. check pwned DFU (irecovery -q | grep PWND:)
  2. boot chain via $BOOT ($([ "$BOOT" = ich ] && echo "$ICH_ROOT/boot.sh --sep" || echo "./spiro.sh boot $CHAIN_DIR"))
  3. start iproxy $SSH_PORT->22, wait SSH root@localhost:$SSH_PORT (alpine)
  4. scp $DEVICE_SCRIPT -> /var/root/ $( [ "$MODE" = unlockcd-chain-sep ] && echo "+ sep-firmware.img4 -> /var/root/sep-chain.img4" )
  5. ssh run: sh /var/root/mount_experiment_18.sh --$MODE (240s guard)
  6. parse VERDICT line$([ "$NO_REBOOT" = 1 ] || echo "; reboot device cleanly")
EOF
    exit 0
fi

setup_log exp18

is_pwned_dfu || die "no pwned DFU device (PWND: expected). Enter DFU with RP2350 first."

# --- boot ---
if [ "$BOOT" = ich ]; then
    [ -x "$ICH_ROOT/boot.sh" ] || die "ICH boot.sh not found: $ICH_ROOT/boot.sh"
    log "boot via ICH boot.sh --sep"
    BOOTCHAIN_NAME="$(basename "$CHAIN_DIR")" run_timeout 180 "$ICH_ROOT/boot.sh" --sep \
        || die "ICH boot failed/timeout (log: $LOG_FILE)"
else
    log "boot via spiro.sh"
    run_timeout 300 bash ./spiro.sh boot "$CHAIN_DIR" \
        || die "spiro boot failed/timeout (log: $LOG_FILE)"
fi

# --- ssh tunnel ---
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR)
ssh_run(){ "$oscheck"/sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" root@localhost "$1"; }

if ! lsof -nP -iTCP:"$SSH_PORT" -sTCP:LISTEN 2>/dev/null | grep -q iproxy; then
    "$oscheck"/iproxy "$SSH_PORT" 22 >>"$LOG_FILE" 2>&1 &
    sleep 1
fi

log "wait SSH"
deadline=$((SECONDS + 90))
until ssh_run "echo ok" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || die "SSH not reachable after 90s (log: $LOG_FILE)"
    sleep 2
done
log "SSH connected"

# --- push & run ---
"$oscheck"/sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" -P "$SSH_PORT" \
    "$DEVICE_SCRIPT" root@localhost:/var/root/mount_experiment_18.sh \
    >>"$LOG_FILE" 2>&1 || die "scp device script failed"
if [ "$MODE" = "unlockcd-chain-sep" ]; then
    "$oscheck"/sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" -P "$SSH_PORT" \
        "$CHAIN_DIR/sep-firmware.img4" root@localhost:/var/root/sep-chain.img4 \
        >>"$LOG_FILE" 2>&1 || die "scp chain SEP failed"
fi

log "run experiment: --$MODE"
out=$(LOG_FILE="" run_timeout 240 ssh_run "sh /var/root/mount_experiment_18.sh --$MODE" 2>&1)
erc=$?
printf '%s\n' "$out" | tee -a "$LOG_FILE"
verdict=$(printf '%s\n' "$out" | awk '/VERDICT:/{print $3; exit}')
log "experiment rc=$erc verdict=${verdict:-NONE}"

# --- reboot ---
if [ "$NO_REBOOT" != 1 ]; then
    log "reboot device"
    run_timeout 15 ssh_run "/usr/sbin/nvram auto-boot=true; /sbin/reboot" >>"$LOG_FILE" 2>&1 \
        || warn "reboot command failed/timeout; reboot manually"
fi

if [ -z "$verdict" ]; then
    warn "no VERDICT received (rc=$erc) — device panicked or hung; this is NOT a clean mount failure; see log"
fi

echo "RESULT: mode=$MODE verdict=${verdict:-NONE} log=$LOG_FILE"
[ "$verdict" = "MOUNTED" ]
