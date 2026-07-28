#!/bin/bash
# ssh.sh - SSH into the ramdisk. Usage:
#   ./ssh.sh                 interactive shell
#   ./ssh.sh 'remote cmd'    run one command
#   ./ssh.sh push-helpers    push resources/mount_helpers.sh to the device
set -u
oscheck="${SPIRO_OSCHECK:-$(uname)}"

start_proxy() {
    if ! lsof -nP -iTCP:2222 -sTCP:LISTEN >/dev/null 2>&1; then
        "$oscheck"/iproxy 2222 22 &>/dev/null &
        sleep 1
    fi
}

case "${1:-}" in
    push-helpers)
        start_proxy
        "$oscheck"/sshpass -p alpine scp -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -P 2222 \
            resources/mount_helpers.sh root@localhost:/var/root/mount_helpers.sh || { echo "scp failed"; exit 1; }
        "$oscheck"/sshpass -p alpine ssh -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -p 2222 root@localhost \
            "chmod +x /var/root/mount_helpers.sh && echo pushed: /var/root/mount_helpers.sh" || exit 1
        echo "usage: ./ssh.sh 'sh /var/root/mount_helpers.sh [--try-data]'"
        ;;
    *)
        start_proxy
        if [ $# -gt 0 ]; then
            "$oscheck"/sshpass -p 'alpine' ssh -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -p2222 root@localhost "$1"
        else
            "$oscheck"/sshpass -p 'alpine' ssh -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -p2222 root@localhost
        fi
        ;;
esac
