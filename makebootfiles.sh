#!/bin/bash
set -u
oscheck="${SPIRO_OSCHECK:-$(uname)}"
BRANCH=$(git branch --show-current 2>/dev/null || true)
BUILD=$(grep "BUILD" verinfo | cut -d':' -f2)
VERSION=$(grep "VERSION" verinfo | cut -d':' -f2)

IRECOVERY="$oscheck"/irecovery
JQ="$oscheck"/jq
IBOOT_MAPPING="resources/iboot_mapping.json"
. lib/common.sh
. lib/device.sh

bm_path() {
    # bm_path <manifest> <buildidentity_index> <component> — print Manifest.<component>.Info.Path
    /usr/bin/plutil -extract "BuildIdentities.$2.Manifest.$3.Info.Path" xml1 -o - "$1" | grep '<string>' | cut -d\> -f2 | cut -d\< -f1 | head -1
}

echo "Welcome to Spironolactone v"$VERSION" (Build: "$BUILD-$BRANCH")!"

Q_TEXT="$(query_device || true)"
cpid="$(get_field "$Q_TEXT" CPID)"
export option1="${1:-}"
export option2="${2:-}"
boardconfig="$(get_field "$Q_TEXT" MODEL)"
replace="$boardconfig"
deviceid="$(get_field "$Q_TEXT" PRODUCT)"
if [[ "$option1" == http* ]]; then
    ipswurl="$option1"
    echo $ipswurl
elif [[ "$option1" =~ ^[0-9.]+$ ]]; then
    ipswurl=$(curl -sL "https://api.ipsw.me/v4/device/$deviceid?type=ipsw" | "$oscheck"/jq '.firmwares | .[] | select(.version=="'$1'")' | "$oscheck"/jq -s '.[0] | .url' --raw-output)
    buildid=$(curl -sL "https://api.ipsw.me/v4/device/$deviceid?type=ipsw" | "$oscheck"/jq '.firmwares | .[] | select(.version=="'$1'")' | "$oscheck"/jq -s '.[0] | .buildid' --raw-output)
    version=$(curl -sL "https://api.ipsw.me/v4/device/$deviceid?type=ipsw" | "$oscheck"/jq '.firmwares | .[] | select(.version=="'$1'")' | "$oscheck"/jq -s '.[0] | .version' --raw-output)

    echo $ipswurl
else
    echo "Please specify a version or an IPSW URL! (not supported yet)"
fi
ipswurl="${ipswurl:-}"
buildid="${buildid:-}"
version="${version:-}"
fwkeyjson=$option2
if [[ -z $fwkeyjson ]]; then
    echo "Please define the fwkey json!"
    exit
fi
if [[ -z $ipswurl ]]; then
    echo "Please define the version first!"
    exit
fi
# --- non-interactive options (flags override env; prompts only on TTY) ---
TYPE="${SPIRO_TYPE:-}"
BOOTARGOPT="${SPIRO_BOOTARGS:-}"
DUALBOOT_DISK="${SPIRO_DUALBOOT_DISK:-}"
IM4M_ARG="${SPIRO_IM4M:-}"
if [ "$#" -gt 2 ]; then
    shift 2
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --type) TYPE="${2:?--type needs value}"; shift 2;;
            --bootargs) BOOTARGOPT="${2:?--bootargs needs value}"; shift 2;;
            --dualboot-disk) DUALBOOT_DISK="${2:?--dualboot-disk needs value}"; shift 2;;
            --im4m) IM4M_ARG="${2:?--im4m needs value}"; shift 2;;
            -h|--help)
                echo "usage: $0 <version|ipsw-url> <fwkey.json> [--type ramdisk|dualboot|downgrade] [--bootargs verbose|serial|neither] [--dualboot-disk disk0s1sN] [--im4m path]"
                exit 0;;
            *) die "unknown option: $1";;
        esac
    done
fi
mkdir work
cd work
if [ -z "$TYPE" ]; then
    if [ -t 0 ]; then
        read -p "Are you going to be dualbooting, tether downgrading, or making a ramdisk: 
Type 'dualboot', 'downgrade' or 'ramdisk':" TYPE
    else
        die "missing --type (ramdisk|dualboot|downgrade) and stdin is not a TTY"
    fi
fi
USEROPTION="$TYPE"

if [ -z "$BOOTARGOPT" ]; then
    if [ -t 0 ]; then
        read -p "Do you want serial boot, verbose boot, or neither
Type 'verbose', 'serial' or 'neither':" BOOTARGOPT
    else
        die "missing --bootargs (verbose|serial|neither) and stdin is not a TTY"
    fi
fi
BOOTARGOPTION="$BOOTARGOPT"
../"$oscheck"/pzb -g BuildManifest.plist "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist 0 AOP)" "$ipswurl"
# 按 DeviceClass 精确匹配本机 boardconfig 对应的 BuildIdentity，
# 不要靠 aop 文件名猜 index（beta 清单的身份顺序和正式版不一样，
# 例如 14.0b5 里 n841ap 是 index 3 而不是 2）
bmindex=0
for i in 0 1 2 3; do
    dc=$(/usr/bin/plutil -extract "BuildIdentities".$i."Info"."DeviceClass" raw -o - BuildManifest.plist 2>/dev/null)
    if [ "$dc" = "$boardconfig" ]; then
        bmindex=$i
        break
    fi
done
#echo "$bmindex"
if [[ "$boardconfig" == n104ap ]]; then
    ../"$oscheck"/pzb -g Firmware/dfu/iBEC.n104.RELEASE.im4p "$ipswurl"
else
    ../"$oscheck"/pzb -g "$(awk "/""${replace}""/{x=1}x&&/iBEC[.]/{print;exit}" BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "$ipswurl"
fi
../"$oscheck"/pzb -g "$(awk "/""${replace}""/{x=1}x&&/DeviceTree[.]/{print;exit}" BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" AOP)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" ANE)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" AVE)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" GFX)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" ISP)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" SIO)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" SEP)" "$ipswurl"
if [[ "$USEROPTION" == ramdisk ]]; then
    ../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist 0 RestoreRamDisk)" "$ipswurl"
    ../"$oscheck"/pzb -g Firmware/"$(bm_path BuildManifest.plist 0 RestoreRamDisk)".trustcache "$ipswurl"
    ../"$oscheck"/pzb -g "$(awk "/""${replace}""/{x=1}x&&/kernelcache.release/{print;exit}" BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "$ipswurl"
else
    ../"$oscheck"/pzb -g Firmware/"$(bm_path BuildManifest.plist 0 OS)".trustcache "$ipswurl"
    ../"$oscheck"/pzb -g "$(awk "/""${replace}""/{x=1}x&&/kernelcache.release/{print;exit}" BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "$ipswurl"
fi
cd ..
iv=$(cat $fwkeyjson |  jq -r 'first(.. | objects | select(has("iv")) | .iv)' | tr -d '"[]\n')
key=$(cat $fwkeyjson | jq -r 'first(.. | objects | select(has("key")) | .key)' | tr -d '"[]\n')
iv=${iv:2}
key=${key:2}
ivkey=$iv$key
if [[ "$boardconfig" == n104ap ]]; then
    "$oscheck"/img4 -i work/iBEC.n104.RELEASE.im4p -o work/iBoot.bin -k "$ivkey"
else
    "$oscheck"/img4 -i work/"$(awk "/""${replace}""/{x=1}x&&/iBEC[.]/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | sed 's/Firmware[/]dfu[/]//')" -o work/iBoot.bin  -k "$ivkey"
fi
"$oscheck"/iBoot64patcher_cryptic work/iBoot.bin work/iBoot.prepatched
if [[ "$USEROPTION" == ramdisk ]]; then
    if [[ "$BOOTARGOPTION" == verbose ]]; then
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "-v debug=0x2014e rd=md0 wdt=-1"
    elif [[ "$BOOTARGOPTION" == serial ]]; then
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "serial=3 debug=0x2014e rd=md0 wdt=-1"
    else
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "rd=md0 wdt=-1"
    fi
elif [[ "$USEROPTION" == downgrade ]]; then
    if [[ "$BOOTARGOPTION" == verbose ]]; then
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "-v debug=0x2014e wdt=-1"
    elif [[ "$BOOTARGOPTION" == serial ]]; then
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "serial=3 debug=0x2014e wdt=-1"
    else
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "wdt=-1"
    fi
else
    if [ -z "$DUALBOOT_DISK" ]; then
        if [ -t 0 ]; then
            read -p "What is the disk0s1s number of your second iOS partition, such as disk0s1s8:" DUALBOOT_DISK
        else
            die "missing --dualboot-disk and stdin is not a TTY"
        fi
    fi
    dualbootdisk="$DUALBOOT_DISK"
    if [[ "$BOOTARGOPTION" == verbose ]]; then
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "rd="$dualbootdisk" -v debug=0x2014e wdt=-1"
    elif [[ "$BOOTARGOPTION" == serial ]]; then
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "rd="$dualbootdisk" serial=3 debug=0x2014e wdt=-1"
    else
        "$oscheck"/kairos work/iBoot.prepatched work/iBoot.patched -b "rd="$dualbootdisk" wdt=-1"
    fi
fi
if [[ "$USEROPTION" == ramdisk ]]; then
    "$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist 0 RestoreRamDisk)" -o work/ramdisk.dmg
    hdiutil resize -size 210MB work/ramdisk.dmg
    hdiutil attach -mountpoint /tmp/SpironolactoneRD work/ramdisk.dmg -owners off
    "$oscheck"/gtar -x --no-overwrite-dir -f resources/ssh.tar.gz -C /tmp/SpironolactoneRD/
    hdiutil detach -force /tmp/SpironolactoneRD
    hdiutil resize -sectors min work/ramdisk.dmg
    "$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist 0 RestoreRamDisk)".trustcache -o work/trustcache.bin
    mkdir work/sshtar
    $oscheck/gtar -x --no-overwrite-dir -f resources/ssh.tar.gz -C work/sshtar
    $oscheck/trustcache append work/trustcache.bin $(cat resources/sshtarlist.txt)
else
:
fi
filedir="$boardconfig-$version-$buildid-$USEROPTION"
mkdir -p bootchain/"$filedir"
if [[ "$USEROPTION" == ramdisk ]]; then
   if [[ $cpid == 0x8020 ]]; then
    IM4MPath="resources/IM4M_0x8020"
    else
    IM4MPath="resources/IM4M_0x8030"
    fi
else
    if [ -z "$IM4M_ARG" ]; then
        if [ -t 0 ]; then
            read -p "Please drag or type a path to your IM4M/APTicket.der file: " IM4M_ARG
        else
            die "missing --im4m and stdin is not a TTY"
        fi
    fi
    IM4MPath="$IM4M_ARG"
fi
if [[ "$USEROPTION" == dualboot ]]; then
    $oscheck/img4 -i work/DeviceTree.$boardconfig.im4p -o work/devicetree.bin
    $oscheck/devicetree-parse work/devicetree.bin > work/devicetree.json
    sed -i '' 's/{"name": "vol.fs_role", "length": 4, "flags": 0, "disp": 1, "value": 64 },/{"name": "vol.fs_role", "length": 4, "flags": 0, "disp": 1, "value": 0 },/g' work/devicetree.json
    $oscheck/devicetree-repack work/devicetree.json work/devicetree.patched
    $oscheck/img4 -i work/devicetree.patched -o bootchain/$filedir/devicetree.img4 -A -T rdtr -M "$IM4MPath"
else
    $oscheck/img4 -i work/DeviceTree.$boardconfig.im4p -o bootchain/$filedir/devicetree.img4 -T rdtr -M "$IM4MPath"
fi
if [[ "$USEROPTION" == ramdisk ]]; then
    $oscheck/img4 -i work/trustcache.bin -o bootchain/$filedir/trustcache.img4 -A -T rtsc -M "$IM4MPath"
    $oscheck/img4 -i work/ramdisk.dmg -o bootchain/$filedir/ramdisk.img4 -A -T rdsk -M "$IM4MPath"
else
        $oscheck/img4 -i work/"$(bm_path work/BuildManifest.plist 0 OS)".trustcache -o bootchain/$filedir/trustcache.img4 -T rtsc -M "$IM4MPath"
fi
$oscheck/img4 -i work/"$(awk "/""${replace}""/{x=1}x&&/kernelcache.release/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" bootchain/$filedir/kernelcache.img4 -T rkrn -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" AOP | cut -d'/' -f3-)" -o bootchain/$filedir/AOP.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" ANE | cut -d'/' -f3-)" -o bootchain/$filedir/ANE.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" AVE | cut -d'/' -f3-)" -o bootchain/$filedir/AVE.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" ISP | cut -d'/' -f3-)" -o bootchain/$filedir/ISP.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" GFX | cut -d'/' -f3-)" -o bootchain/$filedir/GFX.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" SIO | cut -d'/' -f2-)" -o bootchain/$filedir/SIO.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" SEP | cut -d'/' -f3-)" -o bootchain/$filedir/sep-firmware.img4 -M "$IM4MPath"


cp work/iBoot.patched bootchain/$filedir/iBoot.patched.bin

# --- emit boot_order.json (single source of truth for ./spiro.sh boot) ---
{
    items=()
    items+=('{"action":"usbliter8_boot","filename":"iBoot.patched.bin","sleep_after":4}')
    if [ -f bootchain/"$filedir"/sep-firmware.img4 ]; then
        items+=('{"action":"component","name":"RestoreSEP","filename":"sep-firmware.img4","irecv_command":"rsepfirmware"}')
    fi
    items+=('{"action":"component","name":"DeviceTree","filename":"devicetree.img4","irecv_command":"devicetree"}')
    if [[ "$USEROPTION" == ramdisk ]]; then
        items+=('{"action":"component","name":"RestoreRamDisk","filename":"ramdisk.img4","irecv_command":"ramdisk","sleep_after":2}')
    fi
    items+=('{"action":"component","name":"RestoreTrustCache","filename":"trustcache.img4","irecv_command":"firmware"}')
    for c in AOP ANE AVE ISP GFX SIO; do
        items+=("{\"action\":\"component\",\"name\":\"$c\",\"filename\":\"$c.img4\",\"irecv_command\":\"firmware\"}")
    done
    items+=('{"action":"component","name":"RestoreKernelCache","filename":"kernelcache.img4","irecv_command":"bootx"}')
    printf '%s\n' "${items[@]}" | "$oscheck"/jq -s 'to_entries | map(.value + {send_order: .key}) | {version: 1, sequence: .}' > bootchain/"$filedir"/boot_order.json
}
echo "boot_order.json written to bootchain/$filedir/"

echo 'To boot, run ./spiro.sh boot '"$filedir"
