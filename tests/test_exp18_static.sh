#!/bin/bash
# tests/test_exp18_static.sh - static safety checks for the on-device experiment script
set -u
cd "$(dirname "$0")/.."
F="resources/mount_experiment_18.sh"

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi }

[ -f "$F" ]; check "exists" 0 $?
sh -n "$F" 2>/dev/null; check "sh syntax" 0 $?
grep -q -- '--ich-safe' "$F"; check "has --ich-safe mode" 0 $?
grep -q -- '--unlockcd-chain-sep' "$F"; check "has --unlockcd-chain-sep mode" 0 $?
grep -q 'gigalocker-init' "$F"; check "unlockcd flow: gigalocker-init" 0 $?
grep -q 'seputil' "$F"; check "unlockcd flow: seputil --load" 0 $?
grep -q 'run_bg_timeout' "$F"; check "timeout guard present" 0 $?
grep -q 'nand-enable-reformat' "$F"; check "refuses dangerous boot-args" 0 $?
grep -q '/mnt2/mobile' "$F"; check "three-dir verdict check" 0 $?
grep -q 'VERDICT' "$F"; check "machine-parseable VERDICT line" 0 $?
grep -q 'oblit-inprogress' "$F"; check "oblit nvram guard" 0 $?

# every SEPUTIL/MOUNT_APFS invocation must go through run_bg_timeout
grep -E '"(\$SEPUTIL|\$MOUNT_APFS)"' "$F" | grep -v 'run_bg_timeout' | grep -vE '^\s*#|SEPUTIL=|MOUNT_APFS=|\[ -x' | grep -q . \
    && check "unguarded SEPUTIL/MOUNT_APFS call" 1 0 || check "all heavy calls guarded" 0 0
grep -q 'FLOW_BROKEN' "$F"; check "flow-broken verdict exists" 0 $?

grep -q 'probe_volumes' "$F"; check "probe_volumes function" 0 $?
awk '/seputil --load rc=/,/try_data/' "$F" | grep -q 'probe_volumes' \
    && check "post-SEP re-probe before try_data" 0 $? || check "post-SEP re-probe before try_data" 1 0
grep -q "grep -E '\^\[0-9A-Fa-f\]{40" "$F"; check "hex-dir SEP fallback" 0 $?

grep -q -- '--unlockcd-R' "$F"; check "has --unlockcd-R mode" 0 $?
grep -q '"\$MOUNT_APFS" -R' "$F"; check "mount_apfs -R path" 0 $?
awk '/--unlockcd\|--unlockcd-chain-sep\)/,/gigalocker-init/' "$F" | grep -n 'sep-firmware.img4\|/mnt6/active' | head -2 | sed -n '1p' | grep -q 'mnt1/usr/standalone' \
    && check "System-volume SEP preferred" 0 $? || check "System-volume SEP preferred" 1 0

if [ "$fails" -gt 0 ]; then echo "test_exp18_static: $fails FAILURES"; exit 1; fi
echo "test_exp18_static: all pass"
