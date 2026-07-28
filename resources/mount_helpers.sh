#!/bin/sh
# mount_helpers.sh - A12-safe mount helper for Spironolactone SSH ramdisks.
# Runs ON DEVICE over SSH (push with ./ssh.sh push-helpers).
# HARD RULE: never call seputil/gigalocker on A12 ramdisks (double SEPOS init -> panic,
# see RESEARCH_A12_MNT2.md). Data is refused by default (BPR blocks it in DFU context).
set +e
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/System/Library/Filesystems/apfs.fs
APFS_UTIL=/System/Library/Filesystems/apfs.fs/apfs.util
MOUNT_APFS=/System/Library/Filesystems/apfs.fs/mount_apfs
[ -x "$MOUNT_APFS" ] || MOUNT_APFS=/sbin/mount_apfs

TRY_DATA=0
[ "${1:-}" = "--try-data" ] && TRY_DATA=1

log(){ echo "[spiro-mount] $*"; }

mounted_on(){ (/sbin/mount 2>/dev/null || /bin/mount 2>/dev/null) | awk -v m="$1" '$3==m{print $1; exit}'; }
label_of(){ "$APFS_UTIL" -p "$1" 2>/dev/null | sed -n '1p'; }

run_bg_timeout(){
    _sec="$1"; shift
    "$@" &
    _pid=$!; _i=0
    while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_i" -ge "$_sec" ]; then
            log "timeout ${_sec}s: $*"
            kill -9 "$_pid" 2>/dev/null
            wait "$_pid" 2>/dev/null
            return 124
        fi
        sleep 1; _i=$((_i+1))
    done
    wait "$_pid"
    return $?
}

cleanup_oblit(){
    /usr/sbin/nvram -d oblit-inprogress >/dev/null 2>&1
    /usr/sbin/nvram -d obliteration >/dev/null 2>&1
    /usr/sbin/nvram auto-boot=true >/dev/null 2>&1
}

ba=$(/usr/sbin/nvram -p 2>/dev/null | /usr/bin/grep '^boot-args')
case "$ba" in
    *nand-enable-reformat=1*)
        log "refuse: boot-args contain nand-enable-reformat=1: $ba"
        exit 76
        ;;
esac

cleanup_oblit
for d in /mnt1 /mnt2 /mnt6 /mnt7; do /bin/mkdir -p "$d" 2>/dev/null; done

SYS=""; PREBOOT=""; XART=""; DATA=""
for prefix in /dev/disk0s1s /dev/disk1s; do
    for i in 1 2 3 4 5 6 7 8 9; do
        dev="${prefix}${i}"
        [ -e "$dev" ] || continue
        lab=$(label_of "$dev")
        [ -n "$lab" ] && log "$dev label=$lab"
        case "$lab" in
            System)  [ -z "$SYS" ] && SYS="$dev" ;;
            Preboot) [ -z "$PREBOOT" ] && PREBOOT="$dev" ;;
            xART)    [ -z "$XART" ] && XART="$dev" ;;
            Data)    [ -z "$DATA" ] && DATA="$dev" ;;
        esac
    done
done
[ -z "$SYS" ] && [ -e /dev/disk0s1s1 ] && SYS=/dev/disk0s1s1
[ -z "$DATA" ] && [ -e /dev/disk0s1s2 ] && DATA=/dev/disk0s1s2
log "resolved sys=${SYS:-N/A} preboot=${PREBOOT:-N/A} xart=${XART:-N/A} data=${DATA:-N/A}"

mount_one(){
    dev="$1"; mp="$2"
    [ -n "$dev" ] || { log "skip $mp: no device"; return 1; }
    cur=$(mounted_on "$mp")
    if [ -n "$cur" ]; then
        log "skip $mp: already mounted as $cur"
        return 0
    fi
    log "mount $dev -> $mp (20s timeout)"
    run_bg_timeout 20 "$MOUNT_APFS" "$dev" "$mp"
    rc=$?
    [ $rc -eq 0 ] || log "mount failed rc=$rc: $dev -> $mp"
    return $rc
}

mount_one "$SYS" /mnt1
mount_one "$PREBOOT" /mnt6
mount_one "$XART" /mnt7

if [ "$TRY_DATA" = "1" ]; then
    log "WARNING: Data mount on A12 DFU hangs by SEP BPR (RESEARCH_A12_MNT2.md); trying with 20s guard"
    mount_one "$DATA" /mnt2
    if [ -d /mnt2/mobile ] && [ -d /mnt2/root ] && [ -d /mnt2/containers ]; then
        log "/mnt2 ready (unexpected success - please report the exact configuration!)"
    else
        log "/mnt2 not ready (expected on A12)"
    fi
else
    log "skip Data (known A12 BPR hang); pass --try-data to attempt with guard"
fi

cleanup_oblit
exit 0
