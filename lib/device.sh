#!/bin/bash
# lib/device.sh - device query/detection helpers.
# Adapted from research/unlockcd/scripts/start.sh (proven units).
# Requires env: IRECOVERY (path), JQ (path), IBOOT_MAPPING (json path).
# Consumers should set JQ to an absolute path (e.g. "$SPIRO_ROOT/Darwin/jq") when not running from the repo root.

query_device() {
    local out rc
    out="$("$IRECOVERY" -q 2>&1)" && rc=0 || rc=$?
    printf '%s\n' "$out"
    return "$rc"
}

get_field() {
    # get_field <query_text> <key> — split on the FIRST ':' or '=' only
    printf '%s\n' "$1" | awk -v k="$2" '{line=$0; i=index(line,":"); if(i==0) i=index(line,"="); if(i==0) next; key=substr(line,1,i-1); val=substr(line,i+1); if(toupper(key)==toupper(k)){sub(/^[ \t]+/,"",val); sub(/[ \t\r]+$/,"",val); print val; exit}}'
}

normalize_hex() {
    local h="${1:-}"
    h="${h#0x}"; h="${h#0X}"
    printf '%s' "$h" | tr '[:lower:]' '[:upper:]'
}

is_pwned_dfu() {
    query_device 2>/dev/null | grep -qi 'PWND:'
}

detect_iboot_version() {
    local v
    v="$(printf '%s\n' "$1" | grep -Eo 'iBoot-[0-9A-Za-z_.~:-]+' | head -n 1)"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

map_iboot_to_ios() {
    [ -n "$1" ] || return 1
    local v
    v="$("$JQ" -r --arg v "$1" '.mappings[] | select(.iboot_version==$v) | .ios_version' "$IBOOT_MAPPING" 2>/dev/null | head -n 1)"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

map_product_to_model() {
    # map_product_to_model <PRODUCT> <MODEL(hw)> <BDID> — prints bundle model name, rc 1 if unknown
    local prod="$1" hw_model="$2" bdid_val="$3"
    case "$prod" in
        iPhone11,2) printf '%s\n' iPhoneXS; return 0;;
        iPhone11,4) printf '%s\n' iPhoneXSMax; return 0;;
        iPhone11,6) printf '%s\n' iPhoneXSMaxGlobal; return 0;;
        iPhone11,8) printf '%s\n' iPhoneXR; return 0;;
        iPhone12,1) printf '%s\n' iPhone11; return 0;;
        iPhone12,3) printf '%s\n' iPhone11Pro; return 0;;
        iPhone12,5) printf '%s\n' iPhone11ProMax; return 0;;
        iPhone12,8) printf '%s\n' iPhoneSE2; return 0;;
        iPad11,6|iPad11,7) printf '%s\n' iPad8; return 0;;
        iPad12,1|iPad12,2) printf '%s\n' iPad9; return 0;;
        iPad11,3|iPad11,4) printf '%s\n' iPadAir3; return 0;;
        iPad11,1|iPad11,2) printf '%s\n' iPadmini5; return 0;;
        iPad8,*) printf '%s\n' iPad8; return 0;;
    esac
    local hw_lc
    hw_lc="$(printf '%s' "$hw_model" | tr '[:upper:]' '[:lower:]')"
    case "$hw_lc" in
        d321ap) printf '%s\n' iPhoneXS; return 0;;
        d331ap) printf '%s\n' iPhoneXSMax; return 0;;
        d331pap) printf '%s\n' iPhoneXSMaxGlobal; return 0;;
        n841ap) printf '%s\n' iPhoneXR; return 0;;
        n104ap) printf '%s\n' iPhone11; return 0;;
        d421ap) printf '%s\n' iPhone11Pro; return 0;;
        d431ap) printf '%s\n' iPhone11ProMax; return 0;;
        d79ap) printf '%s\n' iPhoneSE2; return 0;;
        j171aap|j172aap) printf '%s\n' iPad8; return 0;;
        j181ap|j182ap) printf '%s\n' iPad9; return 0;;
        j210ap|j211ap|j217ap|j218ap) printf '%s\n' iPadAir3; return 0;;
    esac
    case "$(normalize_hex "$bdid_val")" in
        0E) printf '%s\n' iPhoneXS; return 0;;
        0A) printf '%s\n' iPhoneXSMax; return 0;;
        1A) printf '%s\n' iPhoneXSMaxGlobal; return 0;;
    esac
    return 1
}
