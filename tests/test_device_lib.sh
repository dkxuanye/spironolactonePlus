#!/bin/bash
# tests/test_device_lib.sh - lib/device.sh unit tests (no device needed)
set -u
cd "$(dirname "$0")/.."
IRECOVERY=/bin/false JQ="Darwin/jq" IBOOT_MAPPING="resources/iboot_mapping.json"
export IRECOVERY JQ IBOOT_MAPPING
. lib/device.sh

fails=0
check_eq() { # check_eq <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want [$2] got [$3])"; fails=$((fails+1)); fi
}

Q='MODE: DFU
CPID: 0x8020
BDID: 0x0e
ECID: 0x123ABCD
PRODUCT: iPhone11,8
MODEL: n841ap
NAME: iPhone XR
IBOOT: iBoot-6723.0.48~25
PWND: usbliter8'

check_eq "get_field CPID" "0x8020" "$(get_field "$Q" CPID)"
check_eq "get_field PRODUCT" "iPhone11,8" "$(get_field "$Q" PRODUCT)"
check_eq "get_field MODEL" "n841ap" "$(get_field "$Q" MODEL)"
check_eq "get_field missing" "" "$(get_field "$Q" SRNM)"
check_eq "normalize_hex 0x123abcd" "123ABCD" "$(normalize_hex 0x123abcd)"
check_eq "normalize_hex 0X12" "12" "$(normalize_hex 0X12)"
check_eq "detect_iboot_version" "iBoot-6723.0.48~25" "$(detect_iboot_version "$Q")"
check_eq "map_iboot_to_ios 14.0" "14.0" "$(map_iboot_to_ios "iBoot-6723.0.48~25")"
check_eq "map_iboot_to_ios unknown empty" "" "$(map_iboot_to_ios "iBoot-9999.9.9~9")"
map_iboot_to_ios "iBoot-9999.9.9~9" >/dev/null 2>&1
[ $? -ne 0 ] && echo "ok: map_iboot_to_ios unknown rc nonzero" || { echo "FAIL: map_iboot_to_ios unknown rc"; fails=$((fails+1)); }
check_eq "map_product_to_model iPhone11,8" "iPhoneXR" "$(map_product_to_model iPhone11,8 n841ap 0e)"
check_eq "map_product_to_model by hw" "iPhoneXR" "$(map_product_to_model "" n841ap "")"
check_eq "map_product_to_model unknown rc1" "" "$(map_product_to_model Foo1,1 zzz zz)"

if [ "$fails" -gt 0 ]; then echo "test_device_lib: $fails FAILURES"; exit 1; fi
echo "test_device_lib: all pass"
