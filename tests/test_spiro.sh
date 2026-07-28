#!/bin/bash
# tests/test_spiro.sh - spiro.sh executor tests (offline, dry-run only)
set -u
cd "$(dirname "$0")/.."

fails=0
note_fail() { echo "FAIL: $1"; fails=$((fails+1)); }

BK="/tmp/boot_order_backup.$$.json"
trap '[ -f "$BK" ] && mv "$BK" "bootchain/n841ap-14.4.2-18D70-ramdisk/boot_order.json"' EXIT

CHAIN="n841ap-14.4.2-18D70-ramdisk"
JSON="bootchain/$CHAIN/boot_order.json"

# 1) JSON path vs legacy fallback: dry-run sequences must be identical
if [ -f "$JSON" ]; then
    out_json=$(bash ./spiro.sh boot "$CHAIN" --dry-run 2>/dev/null | grep '^DRYRUN:')
    mv "$JSON" "$BK"
    out_legacy=$(bash ./spiro.sh boot "$CHAIN" --dry-run 2>/dev/null | grep '^DRYRUN:')
    mv "$BK" "$JSON"
    if [ "$out_json" = "$out_legacy" ] && [ -n "$out_json" ]; then
        echo "ok: dry-run JSON == legacy"
    else
        note_fail "dry-run JSON != legacy"
        diff <(printf '%s\n' "$out_json") <(printf '%s\n' "$out_legacy") | head -10
    fi
else
    echo "SKIP: $JSON missing (created in Task 6)"
fi

# 2) dangerous boot-args gate fires even in dry-run
out=$(bash ./spiro.sh boot tests/fixtures/bc-danger --dry-run 2>&1)
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "refusing dangerous boot-args" \
    && echo "ok: dangerous boot-args refused" || note_fail "danger gate (rc=$rc): $out"

# 3) dangerous gate overridable
out=$(ALLOW_DANGEROUS_BOOTARGS=1 bash ./spiro.sh boot tests/fixtures/bc-danger --dry-run 2>&1)
rc=$?
[ "$rc" -eq 0 ] && echo "ok: ALLOW_DANGEROUS_BOOTARGS=1 override" || note_fail "danger override (rc=$rc)"

# 4) missing bootchain dir reported
out=$(bash ./spiro.sh boot no-such-chain --dry-run 2>&1)
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not found" \
    && echo "ok: missing bootchain reported" || note_fail "missing bootchain (rc=$rc)"

# 5) sequence-less JSON dies instead of fake-success
out=$(bash ./spiro.sh boot tests/fixtures/bc-noseq --dry-run 2>&1)
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no usable sequence" \
    && echo "ok: sequence-less JSON refused" || note_fail "noseq gate (rc=$rc): $out"

if [ "$fails" -gt 0 ]; then echo "test_spiro: $fails FAILURES"; exit 1; fi
echo "test_spiro: all pass"
