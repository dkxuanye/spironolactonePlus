#!/bin/bash
# tests/test_validate_ssh.sh - static checks for validate_mounts.sh and ssh.sh
set -u
cd "$(dirname "$0")/.."

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi }

bash -n scripts/validate_mounts.sh 2>/dev/null; check "validate_mounts.sh syntax" 0 $?
bash -n ssh.sh 2>/dev/null; check "ssh.sh syntax" 0 $?
grep -q 'push-helpers' ssh.sh; check "ssh.sh has push-helpers" 0 $?
grep -q 'mount_helpers.sh' ssh.sh; check "push-helpers pushes mount_helpers.sh" 0 $?
grep -q '/mnt1' scripts/validate_mounts.sh; check "validator checks /mnt1" 0 $?
grep -q '/mnt6' scripts/validate_mounts.sh; check "validator checks /mnt6" 0 $?
grep -q '/mnt7' scripts/validate_mounts.sh; check "validator checks /mnt7" 0 $?
grep -q 'gigalocker' scripts/validate_mounts.sh; check "validator checks gigalocker" 0 $?
grep -q 'cat /mnt6/active' scripts/validate_mounts.sh; check "validator resolves /mnt6/active" 0 $?
grep -q 'lib/common.sh' ssh.sh; check "ssh.sh sources lib/common.sh" 0 $?
grep -q 'setup_log' ssh.sh; check "ssh.sh logs push-helpers" 0 $?
grep -qE 'READY|WARNINGS|FAIL' scripts/validate_mounts.sh; check "validator 3-level verdict" 0 $?
grep -q 'seputil' scripts/validate_mounts.sh && check "validator MUST NOT call seputil" 1 0 || check "validator no seputil" 0 0

if [ "$fails" -gt 0 ]; then echo "test_validate_ssh: $fails FAILURES"; exit 1; fi
echo "test_validate_ssh: all pass"
