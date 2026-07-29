#!/bin/sh
# mount_experiment_18.sh - iOS 18/26 ramdisk Data-mount experiment (Phase 0 go/no-go).
# Runs ON DEVICE inside the 18.x SSH ramdisk.
#   --ich-safe             label-probe mounts + bare Data attempt (control group)
#   --unlockcd             gigalocker-init + seputil --load <SEP> + Data mount
#   --unlockcd-R           same as --unlockcd but ALL mounts use mount_apfs -R (Flashcel technique, iOS 16+ convention)
#   --unlockcd-chain-sep   gigalocker-init + seputil --load /var/root/sep-chain.img4 + Data mount
# --unlockcd/--unlockcd-R SEP resolution is System-FIRST (Flashcel technique): /mnt1 (System volume)
#   is the running system's own SEP — inherently matched; /mnt6 preboot active/hex-dir is the fallback.
# Heavy calls (mount_apfs, seputil) are guarded by a 20s timeout with bounded reap. Verdict: /mnt2/{mobile,root,containers}.
# Exit codes: 0=MOUNTED 75=NOT_READY 2=ERROR(no SEP/seputil) 4=FLOW_BROKEN(gigalocker-init) 76=refused(boot-args) 64=usage
# Note: a kernel-wedged seputil yields rc 124 via the guard, but a device panic yields
# NO output at all — hosts must treat missing VERDICT / ssh failure as panic-or-hang.
set +e
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/System/Library/Filesystems/apfs.fs
APFS_UTIL=/System/Library/Filesystems/apfs.fs/apfs.util
MOUNT_APFS=/System/Library/Filesystems/apfs.fs/mount_apfs
[ -x "$MOUNT_APFS" ] || MOUNT_APFS=/sbin/mount_apfs
SEPUTIL=/usr/libexec/seputil

MODE="${1:-}"
MOUNT_R=0
case "$MODE" in
    --ich-safe|--unlockcd|--unlockcd-chain-sep) ;;
    --unlockcd-R) MOUNT_R=1; MODE="--unlockcd" ;;
    *) echo "usage: $0 --ich-safe|--unlockcd|--unlockcd-R|--unlockcd-chain-sep" >&2; exit 64;;
esac

log(){ echo "[exp18] $*"; }

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
            # bounded reap: an unkillable (kernel-wedged) child must not hang the script
            _j=0
            while kill -0 "$_pid" 2>/dev/null; do
                [ "$_j" -ge 3 ] && { log "WARNING: child $_pid unkillable, abandoning"; return 124; }
                sleep 1; _j=$((_j+1))
            done
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
    *nand-enable-reformat*)
        log "refuse: boot-args contain nand-enable-reformat: $ba"
        exit 76
        ;;
esac

cleanup_oblit
for d in /mnt1 /mnt2 /mnt6 /mnt7; do /bin/mkdir -p "$d" 2>/dev/null; done

probe_volumes(){
    SYS=""; PREBOOT=""; XART=""; DATA=""
    for prefix in /dev/disk1s /dev/disk0s1s; do
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
    log "resolved sys=${SYS:-N/A} preboot=${PREBOOT:-N/A} xart=${XART:-N/A} data=${DATA:-N/A}"
}

probe_volumes

mount_one(){
    dev="$1"; mp="$2"
    [ -n "$dev" ] || { log "skip $mp: no device"; return 1; }
    cur=$(mounted_on "$mp")
    if [ -n "$cur" ]; then
        log "skip $mp: already mounted as $cur"
        return 0
    fi
    log "mount $dev -> $mp (20s timeout)"
    if [ "$MOUNT_R" = "1" ]; then
        run_bg_timeout 20 "$MOUNT_APFS" -R "$dev" "$mp"
    else
        run_bg_timeout 20 "$MOUNT_APFS" "$dev" "$mp"
    fi
    rc=$?
    [ $rc -eq 0 ] || log "mount failed rc=$rc: $dev -> $mp"
    return $rc
}

mount_one "$SYS" /mnt1
mount_one "$PREBOOT" /mnt6
mount_one "$XART" /mnt7

ready_data(){ [ -d /mnt2/mobile ] && [ -d /mnt2/root ] && [ -d /mnt2/containers ]; }

try_data(){
    mount_one "$DATA" /mnt2
    sleep 1
    if ready_data; then
        log "VERDICT: MOUNTED"
        return 0
    fi
    log "VERDICT: NOT_READY"
    return 75
}

rc=0
case "$MODE" in
    --ich-safe)
        try_data
        rc=$?
        ;;
    --unlockcd|--unlockcd-chain-sep)
        if [ "$MODE" = "--unlockcd-chain-sep" ]; then
            SEP=/var/root/sep-chain.img4
        else
            # Flashcel technique: System volume SEP is the running system's own SEP — inherently matched
            SEP=/mnt1/usr/standalone/firmware/sep-firmware.img4
            if [ ! -f "$SEP" ]; then
                SEP=""
                if [ -f /mnt6/active ]; then
                    a=$(/bin/cat /mnt6/active 2>/dev/null)
                    case "$a" in */*|*..*) a="" ;; esac
                    [ -n "$a" ] && SEP="/mnt6/$a/usr/standalone/firmware/sep-firmware.img4"
                fi
            fi
            if [ -z "$SEP" ] || [ ! -f "$SEP" ]; then
                first=$(/bin/ls /mnt6 2>/dev/null | /usr/bin/grep -E '^[0-9A-Fa-f]{40,}$' | /usr/bin/head -n1)
                [ -n "$first" ] && SEP="/mnt6/$first/usr/standalone/firmware/sep-firmware.img4"
            fi
        fi
        if [ ! -f "$SEP" ]; then
            log "VERDICT: ERROR no SEP file found (mode=$MODE)"
            cleanup_oblit
            exit 2
        fi
        [ -x "$SEPUTIL" ] || { log "VERDICT: ERROR no seputil"; cleanup_oblit; exit 2; }
        log "gigalocker-init"
        run_bg_timeout 20 "$SEPUTIL" --gigalocker-init
        grc=$?
        log "gigalocker-init rc=$grc"
        if [ "$grc" -ne 0 ]; then
            log "VERDICT: FLOW_BROKEN gigalocker-init rc=$grc"
            cleanup_oblit
            exit 4
        fi
        log "seputil --load $SEP"
        run_bg_timeout 20 "$SEPUTIL" --load "$SEP"
        log "seputil --load rc=$?"
        log "post-SEP re-probe (Data may only appear after SEP is up)"
        probe_volumes
        try_data
        rc=$?
        ;;
esac

cleanup_oblit
exit $rc
