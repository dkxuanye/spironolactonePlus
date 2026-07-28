#!/bin/bash
# lib/common.sh - shared helpers for Spironolactone scripts.
# Sourced by spiro.sh / makebootfiles.sh / scripts/validate_mounts.sh.

log()  { printf '\033[1;36m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[-] %s\033[0m\n' "$*" >&2; exit 1; }

LOG_FILE=""
setup_log() {
    # setup_log <name> — create work/logs/<name>_<timestamp>.log; run_timeout output lands there
    local name="$1" ts
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p work/logs
    LOG_FILE="work/logs/${name}_${ts}.log"
    : > "$LOG_FILE"
}

run_timeout() {
    # run_timeout <seconds> <cmd...> — macOS has no GNU timeout; bg + poll + kill.
    # rc 124 on timeout, otherwise the command's own rc.
    local secs="$1"; shift
    if [ -n "$LOG_FILE" ]; then
        "$@" >>"$LOG_FILE" 2>&1 &
    else
        "$@" &
    fi
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$secs" ]; then
            kill -9 "$pid" 2>/dev/null
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
