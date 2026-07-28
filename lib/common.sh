#!/bin/bash
# lib/common.sh - shared helpers for Spironolactone scripts.
# Sourced by spiro.sh / makebootfiles.sh / scripts/validate_mounts.sh.

log()  { printf '\033[1;36m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[-] %s\033[0m\n' "$*" >&2; exit 1; }

SPIRO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"

LOG_FILE=""
setup_log() {
    # setup_log <name> — create $SPIRO_ROOT/work/logs/<name>_<timestamp>.$$.log;
    # run_timeout output lands there. $$ avoids same-second collisions.
    local name="$1" ts
    ts=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="$SPIRO_ROOT/work/logs/${name}_${ts}.$$.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    : > "$LOG_FILE"
}

run_timeout() {
    # run_timeout <seconds> <cmd...> — macOS has no GNU timeout; bg + poll + kill.
    # rc 124 on timeout, otherwise the command's own rc.
    # On timeout we first try to kill the child's process group (works when the
    # child became a group leader, e.g. via setsid); best-effort only — if the
    # child shares our group, the group kill is refused and we fall back to
    # killing just the pid, so orphaned grandchildren are possible.
    local secs="$1"; shift
    if [ -n "$LOG_FILE" ] && [ -d "$(dirname "$LOG_FILE")" ]; then
        "$@" >>"$LOG_FILE" 2>&1 &
    else
        if [ -n "$LOG_FILE" ]; then
            warn "run_timeout: log dir missing for $LOG_FILE; running without log capture"
        fi
        "$@" &
    fi
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$secs" ]; then
            kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1; i=$((i+1))
    done
    wait "$pid"
}

scan_dangerous_bootargs() {
    # scan_dangerous_bootargs <string> — rc 1 if a dangerous flag is present
    case "$1" in
        *nand-enable-reformat*|*oblit*|*wdt=0*) return 1 ;;
    esac
    return 0
}

is_img4_or_im4p() {
    # is_img4_or_im4p <file> — rc 0 if first 32 bytes contain IMG4/IM4P magic
    xxd -p -l 32 "$1" 2>/dev/null | tr -d '\n' | grep -qiE '494d3450|494d4734'
}
