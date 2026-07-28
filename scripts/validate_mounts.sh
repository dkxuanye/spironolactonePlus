#!/bin/bash
# scripts/validate_mounts.sh - host-side validator for ramdisk mounts.
# Talks to the device over the SSH tunnel (run ./ssh.sh once first, or it starts iproxy itself).
set -u
oscheck="${SPIRO_OSCHECK:-$(uname)}"

SSH=("$oscheck"/sshpass -p alpine ssh -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p 2222 root@localhost)

fail=0; warn=0
ok(){  printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
bad(){ printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }
wrn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; warn=$((warn+1)); }

remote(){ "${SSH[@]}" "$1" 2>/dev/null; }

check_path() { # check_path <test-flag> <path> <label> <fail|warn>
    if remote "test $1 '$2' && echo yes" | grep -q yes; then
        ok "$3: $2"
    elif [ "${4:-fail}" = warn ]; then
        wrn "$3 missing: $2"
    else
        bad "$3 missing: $2"
    fi
}

echo "=== Spironolactone mount validator ==="
if ! remote "echo ssh_ok" | grep -q ssh_ok; then
    bad "SSH not reachable (boot the ramdisk and run ./ssh.sh first)"
    echo "RESULT: FAIL"
    exit 1
fi
ok "SSH reachable"

check_path -d /mnt1/usr/standalone/firmware "System(/mnt1)" fail
if remote "test -e /mnt6/active && echo yes" | grep -q yes; then
    ok "Preboot(/mnt6): active present"
elif remote "ls /mnt6 2>/dev/null | grep -E '^[0-9A-Fa-f]{40,}' | head -1" | grep -q .; then
    wrn "Preboot(/mnt6): no active file, but hash dir present"
else
    bad "Preboot(/mnt6): neither active nor hash dir"
fi
if remote "ls /mnt7 2>/dev/null | head -1" | grep -q .; then
    ok "xART(/mnt7): non-empty"
else
    wrn "xART(/mnt7): empty or not mounted"
fi

echo "=============================="
if [ "$fail" -gt 0 ]; then
    echo "RESULT: FAIL ($fail failures, $warn warnings)"
    exit 1
elif [ "$warn" -gt 0 ]; then
    echo "RESULT: WARNINGS ($warn)"
    exit 0
else
    echo "RESULT: READY"
    exit 0
fi
