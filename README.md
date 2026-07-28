# Spironolactone
This is a tool meant for booting dualboots, ssh ramdisks, and tether downgrades for now. Currently, it only supports generating ssh ramdisks and booting them.

Expansion in functionality (i.e. installing dualboots, jailbreaks, downgrades, etc) willl come at a later date. 

We also have a discord server at https://discord.gg/tXBqy3FRUP for updates and discussion

I will annunce updates over at https://x.com/_orangera1n and on the afformentioned discord

# Important information
1. This tool is in VERY early stages of development, meaning that various functionailites might not be implemented or are otherwise buggy.
2. Due to the status of iBoot patches, only iOS 12.0-14.4.2 are supported for A12, and iOS 13.0-13.7 are for A13. 
Do *not* ask for an ETA for new features or version support
# Prerequsites
1. A computer running macOS (Linux is not implemented yet, but is likely easy to implement, Windows is *very* unlikely to happen)
2. A usbliter8 compatible devices (A12, A13)
- Note that A12X/Z is not implemented due to lack of offsets, and S4/S5 will likely not be implemented due to tooling reasons and lack of demand.
- Note that A14+ is extremely unlikely to come in the future.
3. Common sense
4. An rp2350-based development board, I recommend the Waveshare RP2350A USB Mini

# Usage
0. Flash the RP2350 board with the uf2 files available at https://github.com/prdgmshift/usbliter8/releases/tag/1.0
1. Get the key json file: Head to https://theapplewiki.com/wiki/Firmware and head to your iOS version page for your device type (iPhone or iPad), then head to the specific device section (i.e. iPhone XR or iPad Air (3rd generation)), and then find your iOS version you want to make a ramdisk of, then click on the "iDeviceX,X" page, then download the keys json.
2. run `https://github.com/Orangera1n/spironolactone.git` and `cd spironolactone`.
3. To make a bootchain, run `./makebootfiles.sh (iOS version here) (location of firmware key json here)`. Non-interactive flags: `--type ramdisk|dualboot|downgrade --bootargs verbose|serial|neither [--dualboot-disk disk0s1sN] [--im4m path]` (env `SPIRO_TYPE`/`SPIRO_BOOTARGS`/`SPIRO_DUALBOOT_DISK`/`SPIRO_IM4M` also work). Each bootchain now ships a `boot_order.json` describing the exact boot sequence.
4. To boot a chain, run the command makebootfiles.sh tells you to (`./spiro.sh boot <chain>`). Add `--dry-run` to print the sequence without a device; dangerous boot-args are refused unless `ALLOW_DANGEROUS_BOOTARGS=1`.
5. To ssh, run `./ssh.sh`. Push the on-device mount helper with `./ssh.sh push-helpers`, then `./ssh.sh 'sh /var/root/mount_helpers.sh'` mounts System/Preboot/xART (Data is refused by default on A12; `--try-data` attempts it with a 20s guard). Validate mounts from the host with `./scripts/validate_mounts.sh`.
6. To run the offline test suite (no device needed), run `bash tests/run_tests.sh`.
# Credits
- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) for libirecovery and iproxy
- [Duy Tran](https://github.com/AldazActivator) for devicetree-parse
- [Nathan](https://github.com/verygenericname) for [sshtars](https://github.com/verygenericname/sshtars/) and [SSHRD_Script](https://github.com/verygenericname/), which is going to be helpful for understanding how this works
- [Paradigm Shift](https://github.com/prdgmshift) for [usbliter8 Explot](https://github.com/prdgmshift/usbliter8) used in the tool
- [tihmstar](https://github.com/tihmstar) for pzb/original iBoot64Patcher, and img4tool
- [xerub](https://github.com/xerub) for img4lib and restored_external in the ramdisk
- [Cryptic](https://github.com/Cryptiiiic) for iBoot64Patcher fork
- [opa334](https://github.com/opa334) for TrollStore
- [OpenAI](https://chat.openai.com/chat) (yes we do apologize, but it's not sploified code) for converting [kerneldiff](https://github.com/mcg29/kerneldiff) into [C](https://github.com/verygenericname/kerneldiff_C)
- [AldazActivation](https://github.com/AldazActivator) (apologises again for using something from an icloud bypass dev, but it does work and isn't malicous) for usbliter8_boot
