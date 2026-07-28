#!/bin/bash
# tests/test_makeboot_args.sh - non-interactive arg parsing + boot_order.json generation
set -u
cd "$(dirname "$0")/.."
chmod +x tests/mockbin/irecovery tests/mockbin/pzb

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 ($2)"; fails=$((fails+1)); fi }

export MOCKBIN_LOG=/tmp/mockbin_calls.log
: > "$MOCKBIN_LOG"

# hermetic: back up real user data the mock run would touch, restore on exit
TEST_CHAIN="bootchain/n841ap---ramdisk"
BK=".test_backup.$$"
restore_backup() {
    if [ -d "$TEST_CHAIN$BK" ]; then
        rm -rf "$TEST_CHAIN"
        mv "$TEST_CHAIN$BK" "$TEST_CHAIN"
    else
        rm -rf "$TEST_CHAIN"
    fi
    if [ -d "work$BK" ]; then
        rm -rf work
        mv "work$BK" work
    else
        rm -rf work
    fi
}
trap restore_backup EXIT
[ -d "$TEST_CHAIN" ] && mv "$TEST_CHAIN" "$TEST_CHAIN$BK"
[ -d work ] && mv work "work$BK"

# URL 模式 + 全参数 + 非 TTY：不得出现交互提示，且要走到 pzb 下载并生成 boot_order.json
out=$(SPIRO_OSCHECK=tests/mockbin bash ./makebootfiles.sh "http://example.invalid/fw.ipsw" firmwarekeys_14.4.2_18D70_n841.json --type ramdisk --bootargs neither </dev/null 2>&1)
rc=$?

if printf '%s' "$out" | grep -q "Are you going to be dualbooting"; then
    echo "FAIL: interactive prompt appeared in non-interactive mode"; fails=$((fails+1))
else
    echo "ok: no interactive prompt"
fi
grep -q "MOCKPBZ -g BuildManifest.plist" "$MOCKBIN_LOG" && echo "ok: reached pzb stage" || { echo "FAIL: never reached pzb"; fails=$((fails+1)); }
if [ -f "$TEST_CHAIN/boot_order.json" ] && Darwin/jq -e . "$TEST_CHAIN/boot_order.json" >/dev/null 2>&1; then
    echo "ok: boot_order.json generated and valid"
    Darwin/jq -e '[.sequence[].send_order] == ([.sequence[].send_order] | sort)' "$TEST_CHAIN/boot_order.json" >/dev/null \
        && echo "ok: send_order sequential" || { echo "FAIL: send_order not sequential"; fails=$((fails+1)); }
    Darwin/jq -e '.sequence[] | select(.irecv_command=="ramdisk")' "$TEST_CHAIN/boot_order.json" >/dev/null \
        && echo "ok: ramdisk step present for --type ramdisk" || { echo "FAIL: ramdisk step missing"; fails=$((fails+1)); }
else
    echo "FAIL: boot_order.json not generated/invalid"; fails=$((fails+1))
fi

# 缺 --type 且非 TTY：必须明确报错而不是卡住
out2=$(SPIRO_OSCHECK=tests/mockbin bash ./makebootfiles.sh "http://example.invalid/fw.ipsw" firmwarekeys_14.4.2_18D70_n841.json </dev/null 2>&1)
if printf '%s' "$out2" | grep -q "missing --type"; then
    echo "ok: missing --type reported"
else
    echo "FAIL: missing --type not reported"; fails=$((fails+1))
fi

if [ "$fails" -gt 0 ]; then echo "test_makeboot_args: $fails FAILURES"; exit 1; fi
echo "test_makeboot_args: all pass"
