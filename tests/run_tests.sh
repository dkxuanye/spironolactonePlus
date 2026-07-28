#!/bin/bash
# tests/run_tests.sh - run all test_*.sh, report summary
set -u
cd "$(dirname "$0")/.."
pass=0; fail=0
for t in tests/test_*.sh; do
    echo "=== $t ==="
    if bash "$t"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAILED: $t"; fi
done
echo "=============================="
echo "suites passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
