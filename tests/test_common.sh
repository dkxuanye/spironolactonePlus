#!/bin/bash
# tests/test_common.sh - lib/common.sh unit tests (no device needed)
set -u
cd "$(dirname "$0")/.."
. lib/common.sh

fails=0
check() { # check <desc> <expected_rc> <actual_rc>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want rc=$2 got rc=$3)"; fails=$((fails+1)); fi
}

# scan_dangerous_bootargs
scan_dangerous_bootargs "rd=md0 -v"; check "clean boot-args allowed" 0 $?
scan_dangerous_bootargs "rd=md0 nand-enable-reformat=1"; check "nand-enable-reformat rejected" 1 $?
scan_dangerous_bootargs "oblit-inprogress=1"; check "oblit rejected" 1 $?
scan_dangerous_bootargs "wdt=0"; check "wdt=0 rejected" 1 $?
scan_dangerous_bootargs "wdt=-1"; check "wdt=-1 allowed" 0 $?

# run_timeout
run_timeout 5 true; check "run_timeout true" 0 $?
run_timeout 1 sleep 5; check "run_timeout kills sleep 5 after 1s" 124 $?
run_timeout 5 false; check "run_timeout propagates rc" 1 $?

# is_img4_or_im4p
mkdir -p tests/tmp
printf '0IMG4payload' > tests/tmp/fake.img4   # ASN.1 SEQ byte + IMG4 magic
printf 'not an image' > tests/tmp/notimg.bin
is_img4_or_im4p tests/tmp/fake.img4; check "IMG4 magic detected" 0 $?
is_img4_or_im4p tests/tmp/notimg.bin; check "non-IMG4 rejected" 1 $?
rm -rf tests/tmp

# die / log / warn exist and die exits nonzero
( die "boom" ) 2>/dev/null; check "die exits nonzero" 1 $?

# run_timeout log capture path
setup_log test_common
run_timeout 5 echo capture_check_marker
grep -q capture_check_marker "$LOG_FILE"; check "run_timeout writes to LOG_FILE" 0 $?

# stale LOG_FILE: command still runs
LOG_FILE="/nonexistent-dir-$$/x.log"
out=$(run_timeout 5 echo still_runs); rc=$?
check "stale LOG_FILE still runs command (rc)" 0 $?
printf '%s' "$out" | grep -q still_runs; check "stale LOG_FILE output visible" 0 $?
LOG_FILE=""

# lib/common.sh must source cleanly under zsh too (consumers may run shebang-less)
zshout=$(zsh -c 'set -u; . lib/common.sh; printf "%s" "$SPIRO_ROOT"' 2>/dev/null); zrc=$?
check "lib/common.sh sources under zsh" 0 $?
printf '%s' "$zshout" | grep -q "$(pwd)"; check "SPIRO_ROOT correct under zsh" 0 $?

if [ "$fails" -gt 0 ]; then echo "test_common: $fails FAILURES"; exit 1; fi
echo "test_common: all pass"
