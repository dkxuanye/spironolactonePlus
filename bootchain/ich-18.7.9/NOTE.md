# ich-18.7.9 (spiro.sh alt boot path)

- Symlinks into ~/Desktop/ICH_A12_plus_Ramdisk/bootchain/n841ap-18.7.9-22H355-ramdisk/.
- If the ICH repo moves, recreate: `ln -sf <new-ich-chain>/<file> bootchain/ich-18.7.9/<file>` for the 12 files.
- The ICH `boot.sh` primary path polls up to 45s for Recovery mode after iBoot; our executor only has `sleep_after: 4`. If the spiro boot dies right after iBoot, that race is why — use `--boot ich` (the supported primary path).
- boot_order.json is tracked (git add -f); symlinks are intentionally untracked.
