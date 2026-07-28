#!/bin/bash
# tests/test_mount_helpers_static.sh - static safety checks for the on-device helper
set -u
cd "$(dirname "$0")/.."
F="resources/mount_helpers.sh"

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi }

[ -f "$F" ]; check "exists" 0 $?
sh -n "$F" 2>/dev/null; check "sh syntax" 0 $?

# Check for actual command invocations only: strip comments first, since the
# helper's header documents the rule by naming seputil/gigalocker as words.
NOCOMMENT=$(sed 's/#.*//' "$F")
echo "$NOCOMMENT" | grep -q 'seputil' && check "MUST NOT call seputil (A12 panic)" 1 0 || check "no seputil" 0 0
echo "$NOCOMMENT" | grep -q 'gigalocker' && check "MUST NOT call gigalocker" 1 0 || check "no gigalocker" 0 0
grep -q -- '--try-data' "$F"; check "has --try-data opt-in" 0 $?
grep -q 'nand-enable-reformat' "$F"; check "refuses dangerous boot-args" 0 $?
grep -q 'run_bg_timeout' "$F"; check "run_bg_timeout present" 0 $?
grep 'MOUNT_APFS"' "$F" | grep -v 'run_bg_timeout' | grep -v 'MOUNT_APFS=' | grep -q . && check "unguarded MOUNT_APFS call found" 1 0 || check "all MOUNT_APFS calls guarded" 0 0
grep -q 'apfs.util' "$F"; check "label probing via apfs.util" 0 $?
grep -q 'oblit-inprogress' "$F"; check "oblit nvram guard" 0 $?

if [ "$fails" -gt 0 ]; then echo "test_mount_helpers_static: $fails FAILURES"; exit 1; fi
echo "test_mount_helpers_static: all pass"
