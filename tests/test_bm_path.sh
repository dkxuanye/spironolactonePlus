#!/bin/bash
# tests/test_bm_path.sh - bm_path helper equals legacy plutil pipeline, byte for byte
set -u
cd "$(dirname "$0")/.."
BM="research/unlockcd/bootchain/iPhoneXR_18.3/BuildManifest.plist"
[ -f "$BM" ] || { echo "SKIP: fixture manifest missing: $BM"; exit 0; }

fails=0
check_eq() {
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want [$2] got [$3])"; fails=$((fails+1)); fi
}

# legacy pipeline (verbatim copy of the pattern used in makebootfiles.sh)
legacy() { # legacy <manifest> <index> <component>
    /usr/bin/plutil -extract "BuildIdentities"."$2"."Manifest"."$3"."Info"."Path" xml1 -o - "$1" | grep '<string>' | cut -d\> -f2 | cut -d\< -f1 | head -1
}

# exercise the REAL bm_path extracted from makebootfiles.sh
eval "$(sed -n '/^bm_path()/,/^}/p' makebootfiles.sh)"
type bm_path >/dev/null 2>&1 || { echo "FAIL: could not extract bm_path from makebootfiles.sh"; exit 1; }

for comp in AOP ANE AVE GFX ISP SIO SEP RestoreRamDisk OS; do
    check_eq "bm_path idx0 $comp" "$(legacy "$BM" 0 "$comp")" "$(bm_path "$BM" 0 "$comp")"
    check_eq "bm_path idx1 $comp" "$(legacy "$BM" 1 "$comp")" "$(bm_path "$BM" 1 "$comp")"
done

# makebootfiles.sh must define bm_path and must not contain the legacy plutil pattern anymore
if grep -q 'plutil -extract "BuildIdentities".\$bmindex' makebootfiles.sh; then
    echo "FAIL: makebootfiles.sh still uses legacy plutil pattern"; fails=$((fails+1))
else
    echo "ok: makebootfiles.sh uses bm_path"
fi
grep -q '^bm_path()' makebootfiles.sh && echo "ok: bm_path defined" || { echo "FAIL: bm_path not defined in makebootfiles.sh"; fails=$((fails+1)); }

# device lib is used instead of ad-hoc irecovery greps
if grep -q 'irecovery -q | grep' makebootfiles.sh; then
    echo "FAIL: makebootfiles.sh still uses ad-hoc irecovery greps"; fails=$((fails+1))
else
    echo "ok: makebootfiles.sh uses lib/device.sh"
fi

if [ "$fails" -gt 0 ]; then echo "test_bm_path: $fails FAILURES"; exit 1; fi
echo "test_bm_path: all pass"
