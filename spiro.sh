#!/bin/bash
set -u
oscheck="${SPIRO_OSCHECK:-$(uname)}"
option="${1:-}"
bootchain="${2:-}"
dry_run=0
[ "${3:-}" = "--dry-run" ] && dry_run=1

BUILD=$(grep "BUILD" verinfo | cut -d':' -f2)
VERSION=$(grep "VERSION" verinfo | cut -d':' -f2)
BRANCH=$(git branch --show-current 2>/dev/null || true)

IRECOVERY="$oscheck"/irecovery
JQ="$oscheck"/jq
IBOOT_MAPPING="resources/iboot_mapping.json"
. lib/common.sh
. lib/device.sh

echo "Welcome to Spironolactone v$VERSION (Build: $BUILD-$BRANCH)!"

[ "$option" = boot ] || die 'To boot, run the script as "./spiro.sh boot <chain> [--dry-run]"'
[ -n "$bootchain" ] || die 'To boot, you need to provide a bootchain name with "./spiro.sh boot"'
if [ -d "$bootchain" ]; then BC_DIR="$bootchain"; else BC_DIR="bootchain/$bootchain"; fi
[ -d "$BC_DIR" ] || die "bootchain dir not found: $BC_DIR"

setup_log spiro
if [ "$dry_run" != 1 ]; then
    is_pwned_dfu || die "no pwned DFU device (irecovery -q should show PWND:). Attach the RP2350 and enter DFU first."
fi

send_file() { # send_file <path> <timeout>
    local f="$1" t="$2"
    [ -f "$f" ] || die "missing file: $f"
    if [ "$dry_run" = 1 ]; then printf 'DRYRUN: %s -f %s\n' "$IRECOVERY" "$f"; return 0; fi
    run_timeout "$t" "$IRECOVERY" -f "$f" || die "send failed/timeout (${t}s): $f (log: $LOG_FILE)"
}

send_cmd() { # send_cmd <command> <timeout>
    local c="$1" t="$2"
    case "$c" in
        "setenv boot-args "*)
            if ! scan_dangerous_bootargs "$c" && [ "${ALLOW_DANGEROUS_BOOTARGS:-0}" != "1" ]; then
                die "refusing dangerous boot-args: $c (set ALLOW_DANGEROUS_BOOTARGS=1 to override)"
            fi ;;
    esac
    log "CMD: $c"
    if [ "$dry_run" = 1 ]; then printf 'DRYRUN: %s -c %s\n' "$IRECOVERY" "$c"; return 0; fi
    run_timeout "$t" "$IRECOVERY" -c "$c" || die "command failed/timeout (${t}s): $c (log: $LOG_FILE)"
}

maybe_sleep() { # maybe_sleep <secs> — 0 skips; prints in dry-run
    [ "${1:-0}" != "0" ] || return 0
    if [ "$dry_run" = 1 ]; then printf 'DRYRUN: sleep %s\n' "$1"; return 0; fi
    sleep "$1"
}

big_timeout() { # big_timeout <filename>
    case "$1" in
        ramdisk.img4|kernelcache.img4) printf '%s' "${SPIRO_IRECV_TIMEOUT:-90}" ;;
        *) printf '%s' "${SPIRO_IRECV_TIMEOUT:-15}" ;;
    esac
}

boot_usbliter8() { # boot_usbliter8 <path> <sleep_after>
    local f="$1"
    [ -f "$f" ] || die "missing file: $f"
    log "Loading iBoot!"
    if [ "$dry_run" = 1 ]; then
        printf 'DRYRUN: %s %s\n' "$oscheck/usbliter8_boot" "$f"
    else
        run_timeout 60 "$oscheck"/usbliter8_boot "$f" || die "usbliter8_boot failed/timeout (log: $LOG_FILE)"
    fi
    maybe_sleep "${2:-0}"
}

boot_via_json() {
    local json="$BC_DIR/boot_order.json"
    "$JQ" -e . "$json" >/dev/null 2>&1 || die "invalid JSON: $json"
    local line action filename cmd slp
    # split TSV manually: IFS=tab read would collapse empty middle fields
    while IFS= read -r line; do
        action=${line%%$'\t'*};   line=${line#*$'\t'}
        filename=${line%%$'\t'*}; line=${line#*$'\t'}
        cmd=${line%%$'\t'*};      slp=${line#*$'\t'}
        case "$action" in
            usbliter8_boot)
                boot_usbliter8 "$BC_DIR/$filename" "$slp" ;;
            command)
                send_cmd "$cmd" 15 ;;
            component)
                [ -f "$BC_DIR/$filename" ] || die "missing file: $BC_DIR/$filename"
                if [ "$dry_run" != 1 ]; then
                    is_img4_or_im4p "$BC_DIR/$filename" || die "not an IMG4/IM4P: $BC_DIR/$filename"
                fi
                send_file "$BC_DIR/$filename" "$(big_timeout "$filename")"
                maybe_sleep "$slp"
                send_cmd "$cmd" 15 ;;
            *) die "unknown action in $json: $action" ;;
        esac
    done < <("$JQ" -r '.sequence | sort_by(.send_order)[] | [.action, (.filename // ""), (.irecv_command // .command // ""), (.sleep_after // 0)] | @tsv' "$json")
}

boot_legacy() {
    warn "no boot_order.json in $BC_DIR; using legacy built-in sequence (see docs/superpowers/specs/2026-07-27-pipeline-hardening-design.md)"
    boot_usbliter8 "$BC_DIR/iBoot.patched.bin" 4
    if [ -e "$BC_DIR"/sep-firmware.img4 ]; then
        log "Loading SEP"
        send_file "$BC_DIR/sep-firmware.img4" 15
        send_cmd "rsepfirmware" 15
    fi
    log "Loading Devicetree!"
    send_file "$BC_DIR/devicetree.img4" 15
    send_cmd "devicetree" 15
    if [[ "$BC_DIR" == *ramdisk* ]]; then
        log "Loading Ramdisk!"
        send_file "$BC_DIR/ramdisk.img4" "$(big_timeout ramdisk.img4)"
        maybe_sleep 2
        send_cmd "ramdisk" 15
    fi
    log "Loading trustcache!"
    send_file "$BC_DIR/trustcache.img4" 15
    send_cmd "firmware" 15
    for c in AOP ANE AVE ISP GFX SIO; do
        log "Loading $c!"
        send_file "$BC_DIR/$c.img4" 15
        send_cmd "firmware" 15
    done
    log "Loading and Booting Kernel!"
    send_file "$BC_DIR/kernelcache.img4" "$(big_timeout kernelcache.img4)"
    send_cmd "bootx" 15
    if [[ "$BC_DIR" == *ramdisk* ]] && [ "$dry_run" != 1 ]; then
        echo 'In a few seconds, you can SSH via ./ssh.sh'
    fi
}

log "bootchain: $BC_DIR"
maybe_sleep 3
if [ -f "$BC_DIR/boot_order.json" ]; then
    log "using $BC_DIR/boot_order.json"
    boot_via_json
else
    boot_legacy
fi
log "done: boot sequence sent (log: $LOG_FILE)"
