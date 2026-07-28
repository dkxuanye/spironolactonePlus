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

if [ "$fails" -gt 0 ]; then echo "test_exp18_static: $fails FAILURES"; exit 1; fi
echo "test_exp18_static: all pass"
