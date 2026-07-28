#!/bin/bash
# tests/test_exp18_host.sh - offline checks for the host orchestrator
set -u
cd "$(dirname "$0")/.."

fails=0
note_fail() { echo "FAIL: $1"; fails=$((fails+1)); }

bash -n scripts/experiment_18x_mount.sh 2>/dev/null || note_fail "bash syntax"
zsh -n scripts/experiment_18x_mount.sh 2>/dev/null || note_fail "zsh syntax"

# invalid --mode must die
out=$(bash scripts/experiment_18x_mount.sh --mode bogus --dry-run 2>&1)
[ $? -ne 0 ] && printf '%s' "$out" | grep -q "invalid --mode" \
    && echo "ok: invalid --mode rejected" || note_fail "invalid --mode: $out"

# missing --mode must die
out=$(bash scripts/experiment_18x_mount.sh --dry-run 2>&1)
[ $? -ne 0 ] && printf '%s' "$out" | grep -q "missing --mode" \
    && echo "ok: missing --mode reported" || note_fail "missing --mode"

# missing chain dir must die
out=$(CHAIN_DIR=/nonexistent-chain bash scripts/experiment_18x_mount.sh --mode ich-safe --dry-run 2>&1)
[ $? -ne 0 ] && printf '%s' "$out" | grep -q "chain" \
    && echo "ok: missing chain reported" || note_fail "missing chain: $out"

# dry-run with a fake chain prints planned steps without touching a device
FAKE=/tmp/fake-chain-$$
mkdir -p "$FAKE"
for f in iBoot.patched.bin sep-firmware.img4 devicetree.img4 trustcache.img4 ramdisk.img4 kernelcache.img4 AOP.img4 ANE.img4 AVE.img4 ISP.img4 GFX.img4 SIO.img4; do
    printf 'x' > "$FAKE/$f"
done
out=$(CHAIN_DIR="$FAKE" bash scripts/experiment_18x_mount.sh --mode unlockcd --dry-run 2>&1)
rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "unlockcd" \
    && echo "ok: dry-run plans steps" || note_fail "dry-run (rc=$rc): $out"
rm -rf "$FAKE"

# regression: run_timeout inside $() must still capture child output when LOG_FILE is set
. lib/common.sh
setup_log test_exp18_capture
fake_exp(){ echo "[exp18] VERDICT: MOUNTED"; }
capout=$(LOG_FILE="" run_timeout 5 fake_exp 2>&1)
printf '%s' "$capout" | grep -q "VERDICT: MOUNTED" \
    && echo "ok: capture works with LOG_FILE cleared" || note_fail "capture empty with LOG_FILE set"
[ -n "$LOG_FILE" ] && echo "ok: LOG_FILE restored after scoped clear" || note_fail "LOG_FILE clobbered"
LOG_FILE=""

# regression: verdict parse must read field 3 ([exp18] VERDICT: X)
v=$(printf '[exp18] VERDICT: MOUNTED\n' | awk '/VERDICT:/{print $3; exit}')
[ "$v" = "MOUNTED" ] && echo "ok: verdict parse MOUNTED" || note_fail "verdict parse: got [$v]"
v=$(printf '[exp18] VERDICT: FLOW_BROKEN gigalocker-init rc=1\n' | awk '/VERDICT:/{print $3; exit}')
[ "$v" = "FLOW_BROKEN" ] && echo "ok: verdict parse FLOW_BROKEN" || note_fail "verdict parse flow: got [$v]"
v=$(printf '[exp18] mount failed rc=75: /dev/disk1s2 -> /mnt2\n' | awk '/VERDICT:/{print $3; exit}')
[ -z "$v" ] && echo "ok: no verdict line yields empty" || note_fail "phantom verdict: got [$v]"

if [ "$fails" -gt 0 ]; then echo "test_exp18_host: $fails FAILURES"; exit 1; fi
echo "test_exp18_host: all pass"
