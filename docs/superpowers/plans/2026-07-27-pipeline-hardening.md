# Spironolactone 流程加固（Track A）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改动任何已验证底层行为的前提下，把 spironolactone 的构建/引导/挂载流程加固为数据驱动、全超时、可校验的工程管线。

**Architecture:** 新增 `lib/common.sh`（日志/超时/安全闸）与 `lib/device.sh`（设备检测）两个共享库；`spiro.sh` 改为 `boot_order.json` 数据驱动执行器并保留 legacy 回退；`makebootfiles.sh` 非交互化并在构建时生成 JSON；设备端新增 A12 安全挂载助手，host 端新增校验器。所有改动用 bash 断言脚本测试（无设备、离线可跑），真机冒烟由用户执行。

**Tech Stack:** bash/zsh 脚本、jq（`Darwin/jq`）、irecovery、apfs.util（设备端）、SSH/dropbear 隧道。

**Spec:** `docs/superpowers/specs/2026-07-27-pipeline-hardening-design.md`

**约束（来自 spec 与研究结论，违反即返工）：**
- 设备端脚本**禁止出现任何 seputil/gigalocker 调用**（A12 SEPOS 双初始化 panic）
- Data 卷默认拒绝挂载，仅 `--try-data` 显式尝试且必须带超时
- legacy 回退路径的组件发送顺序必须与现 `spiro.sh` 完全一致：usbliter8(sleep 4) → SEP(rsepfirmware，可选) → devicetree → ramdisk(中间 sleep 2) → trustcache → AOP → ANE → AVE → ISP → GFX → SIO → kernelcache(bootx)
- 所有脚本支持 `SPIRO_OSCHECK` 环境变量覆盖 `$(uname)`（测试注入 mock 用）
- 只在本地 commit，**禁止 push**

---

### Task 1: 测试基建 + `lib/common.sh`

**Files:**
- Create: `lib/common.sh`
- Create: `tests/run_tests.sh`
- Create: `tests/test_common.sh`

- [ ] **Step 1: 写失败测试 `tests/test_common.sh`**

```bash
#!/bin/bash
# tests/test_common.sh - lib/common.sh unit tests (no device needed)
set -u
cd "$(dirname "$0")/.."
. lib/common.sh

fails=0
check() { # check <desc> <expected_rc> <actual_rc>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want rc=$2 got rc=$3)"; fails=$((fails+1)); fi
}

# scan_dangerous_bootargs
scan_dangerous_bootargs "rd=md0 -v"; check "clean boot-args allowed" 0 $?
scan_dangerous_bootargs "rd=md0 nand-enable-reformat=1"; check "nand-enable-reformat rejected" 1 $?
scan_dangerous_bootargs "oblit-inprogress=1"; check "oblit rejected" 1 $?
scan_dangerous_bootargs "wdt=0"; check "wdt=0 rejected" 1 $?
scan_dangerous_bootargs "wdt=-1"; check "wdt=-1 allowed" 0 $?

# run_timeout
run_timeout 5 true; check "run_timeout true" 0 $?
run_timeout 1 sleep 5; check "run_timeout kills sleep 5 after 1s" 124 $?
run_timeout 5 false; check "run_timeout propagates rc" 1 $?

# is_img4_or_im4p
mkdir -p tests/tmp
printf '0IMG4payload' > tests/tmp/fake.img4   # ASN.1 SEQ byte + IMG4 magic
printf 'not an image' > tests/tmp/notimg.bin
is_img4_or_im4p tests/tmp/fake.img4; check "IMG4 magic detected" 0 $?
is_img4_or_im4p tests/tmp/notimg.bin; check "non-IMG4 rejected" 1 $?
rm -rf tests/tmp

# die / log / warn exist and die exits nonzero
( die "boom" ) 2>/dev/null; check "die exits nonzero" 1 $?

if [ "$fails" -gt 0 ]; then echo "test_common: $fails FAILURES"; exit 1; fi
echo "test_common: all pass"
```

- [ ] **Step 2: 写测试运行器 `tests/run_tests.sh`**

```bash
#!/bin/bash
# tests/run_tests.sh - run all test_*.sh, report summary
set -u
cd "$(dirname "$0")/.."
pass=0; fail=0
for t in tests/test_*.sh; do
    echo "=== $t ==="
    if bash "$t"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAILED: $t"; fi
done
echo "=============================="
echo "suites passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 3: 运行测试确认失败**

Run: `bash tests/run_tests.sh`
Expected: FAIL — `lib/common.sh: No such file or directory`

- [ ] **Step 4: 实现 `lib/common.sh`**

```bash
#!/bin/bash
# lib/common.sh - shared helpers for Spironolactone scripts.
# Sourced by spiro.sh / makebootfiles.sh / scripts/validate_mounts.sh.

log()  { printf '\033[1;36m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[-] %s\033[0m\n' "$*" >&2; exit 1; }

LOG_FILE=""
setup_log() {
    # setup_log <name> — create work/logs/<name>_<timestamp>.log; run_timeout output lands there
    local name="$1" ts
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p work/logs
    LOG_FILE="work/logs/${name}_${ts}.log"
    : > "$LOG_FILE"
}

run_timeout() {
    # run_timeout <seconds> <cmd...> — macOS has no GNU timeout; bg + poll + kill.
    # rc 124 on timeout, otherwise the command's own rc.
    local secs="$1"; shift
    if [ -n "$LOG_FILE" ]; then
        "$@" >>"$LOG_FILE" 2>&1 &
    else
        "$@" &
    fi
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$secs" ]; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1; i=$((i+1))
    done
    wait "$pid"
}

scan_dangerous_bootargs() {
    # scan_dangerous_bootargs <string> — rc 1 if a dangerous flag is present
    case "$1" in
        *nand-enable-reformat*|*oblit*|*wdt=0*) return 1 ;;
    esac
    return 0
}

is_img4_or_im4p() {
    # is_img4_or_im4p <file> — rc 0 if first 32 bytes contain IMG4/IM4P magic
    xxd -p -l 32 "$1" 2>/dev/null | tr -d '\n' | grep -qiE '494d3450|494d4734'
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `bash tests/run_tests.sh`
Expected: `test_common: all pass`，summary `suites passed: 1, failed: 0`

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh tests/run_tests.sh tests/test_common.sh
git commit -m "feat: add lib/common.sh (logging, run_timeout, boot-args gate, img4 check) + test infra"
```

---

### Task 2: `lib/device.sh` + `resources/iboot_mapping.json`

**Files:**
- Create: `lib/device.sh`
- Create: `resources/iboot_mapping.json`（复制自 `research/unlockcd/app/iboot_mapping.json`，557 条映射）
- Create: `tests/test_device_lib.sh`

- [ ] **Step 1: 写失败测试 `tests/test_device_lib.sh`**

```bash
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
check_eq "map_product_to_model iPhone11,8" "iPhoneXR" "$(map_product_to_model iPhone11,8 n841ap 0e)"
check_eq "map_product_to_model by hw" "iPhoneXR" "$(map_product_to_model "" n841ap "")"
check_eq "map_product_to_model unknown rc1" "" "$(map_product_to_model Foo1,1 zzz zz)"

if [ "$fails" -gt 0 ]; then echo "test_device_lib: $fails FAILURES"; exit 1; fi
echo "test_device_lib: all pass"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/run_tests.sh`
Expected: FAIL — `lib/device.sh: No such file or directory`（test_common 仍应通过）

- [ ] **Step 3: 复制映射表**

```bash
cp research/unlockcd/app/iboot_mapping.json resources/iboot_mapping.json
```

- [ ] **Step 4: 实现 `lib/device.sh`**

```bash
#!/bin/bash
# lib/device.sh - device query/detection helpers.
# Adapted from research/unlockcd/scripts/start.sh (proven units).
# Requires env: IRECOVERY (path), JQ (path), IBOOT_MAPPING (json path).

query_device() {
    local out rc
    out="$("$IRECOVERY" -q 2>&1)" && rc=0 || rc=$?
    printf '%s\n' "$out"
    return "$rc"
}

get_field() {
    # get_field <query_text> <key>
    printf '%s\n' "$1" | awk -F'[:=]' -v k="$2" 'toupper($1)==toupper(k){sub(/^[ \t]+/,"",$2); sub(/[ \t\r]+$/, "", $2); print $2; exit}'
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
    printf '%s\n' "$1" | grep -Eo 'iBoot-[0-9A-Za-z_.~:-]+' | head -n 1 || true
}

map_iboot_to_ios() {
    [ -n "$1" ] || return 1
    "$JQ" -r --arg v "$1" '.mappings[] | select(.iboot_version==$v) | .ios_version' "$IBOOT_MAPPING" 2>/dev/null | head -n 1
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
```

- [ ] **Step 5: 运行测试确认通过**

Run: `bash tests/run_tests.sh`
Expected: `test_common: all pass`、`test_device_lib: all pass`

- [ ] **Step 6: Commit**

```bash
git add lib/device.sh resources/iboot_mapping.json tests/test_device_lib.sh
git commit -m "feat: add lib/device.sh device detection + iboot->ios mapping table"
```

---

### Task 3: `makebootfiles.sh` — `SPIRO_OSCHECK` 钩子 + `bm_path` 重构 + 设备库替换

**Files:**
- Modify: `makebootfiles.sh`（全文多处，逐行见下）
- Create: `tests/test_bm_path.sh`

- [ ] **Step 1: 写失败测试 `tests/test_bm_path.sh`**

用真实 manifest（`research/unlockcd/bootchain/iPhoneXR_18.3/BuildManifest.plist`）验证 `bm_path` 与旧管线输出逐字节一致：

```bash
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

# new helper (sourced from makebootfiles.sh via extract; define here until Task 3 lands)
if ! type bm_path >/dev/null 2>&1; then
    bm_path() { /usr/bin/plutil -extract "BuildIdentities.$2.Manifest.$3.Info.Path" xml1 -o - "$1" | grep '<string>' | cut -d\> -f2 | cut -d\< -f1 | head -1; }
fi

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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_bm_path.sh`
Expected: FAIL × 3（legacy plutil pattern 仍在、bm_path 未定义、ad-hoc greps 仍在）；等价性检查用内置定义应通过

- [ ] **Step 3: 修改 `makebootfiles.sh` 头部（钩子 + 库 + `set -u` 防护）**

把第 1–14 行（`#export ipswurl` 到 `cpid=...`）替换为：

```bash
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
```

并把后续 `boardconfig=`/`replace=`/`deviceid=` 三处赋值（URL 分支与版本分支各一组，共 6 行）统一替换为在 `Q_TEXT` 上调用（删除两组重复赋值，在 `if [[ "$option1" ...` 之前放一次）：

```bash
boardconfig="$(get_field "$Q_TEXT" MODEL)"
replace="$boardconfig"
deviceid="$(get_field "$Q_TEXT" PRODUCT)"
```

版本分支里 `curl ... | "$oscheck"/jq` 的 3 处保持不变（`"$oscheck"/jq` 已可用）。`buildid`/`version` 在 URL 分支未赋值，`set -u` 下需要在分支后补默认值：

```bash
buildid="${buildid:-}"
version="${version:-}"
```

- [ ] **Step 4: 替换全部 legacy plutil 管线为 `bm_path`（逐行，旧 → 新）**

下载段（cwd=work，原 52、71–77、79–83 行）：

```bash
# 旧(52): ../"$oscheck"/pzb -g "$(/usr/bin/plutil -extract "BuildIdentities".0."Manifest"."AOP"."Info"."Path" xml1 -o - BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | head -1)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist 0 AOP)" "$ipswurl"
# 71-77（bmindex）：AOP/ANE/AVE/GFX/ISP/SIO/SEP 七个，统一为：
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" AOP)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" ANE)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" AVE)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" GFX)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" ISP)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" SIO)" "$ipswurl"
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist "$bmindex" SEP)" "$ipswurl"
# 79-80（ramdisk 分支）：
../"$oscheck"/pzb -g "$(bm_path BuildManifest.plist 0 RestoreRamDisk)" "$ipswurl"
../"$oscheck"/pzb -g Firmware/"$(bm_path BuildManifest.plist 0 RestoreRamDisk)".trustcache "$ipswurl"
# 83（非 ramdisk 分支）：
../"$oscheck"/pzb -g Firmware/"$(bm_path BuildManifest.plist 0 OS)".trustcache "$ipswurl"
```

ramdisk dmg 处理段（cwd=root，原 125、131 行）：

```bash
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist 0 RestoreRamDisk)" -o work/ramdisk.dmg
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist 0 RestoreRamDisk)".trustcache -o work/trustcache.bin
```

打包段（原 162、165–171 行，注意每行的 `cut -d'/'` 参数保持原样）：

```bash
# 162:
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist 0 OS)".trustcache -o bootchain/$filedir/trustcache.img4 -T rtsc -M "$IM4MPath"
# 165-171（165-169、171 用 cut -d'/' -f3-；170 SIO 原来是 -f2-，保持不变）：
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" AOP | cut -d'/' -f3-)" -o bootchain/$filedir/AOP.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" ANE | cut -d'/' -f3-)" -o bootchain/$filedir/ANE.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" AVE | cut -d'/' -f3-)" -o bootchain/$filedir/AVE.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" ISP | cut -d'/' -f3-)" -o bootchain/$filedir/ISP.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" GFX | cut -d'/' -f3-)" -o bootchain/$filedir/GFX.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" SIO | cut -d'/' -f2-)" -o bootchain/$filedir/SIO.img4 -M "$IM4MPath"
"$oscheck"/img4 -i work/"$(bm_path work/BuildManifest.plist "$bmindex" SEP | cut -d'/' -f3-)" -o bootchain/$filedir/sep-firmware.img4 -M "$IM4MPath"
```

- [ ] **Step 5: 运行测试确认通过 + 语法检查**

Run: `bash tests/test_bm_path.sh && bash -n makebootfiles.sh && zsh -n makebootfiles.sh`
Expected: `test_bm_path: all pass`，两个语法检查无输出

- [ ] **Step 6: Commit**

```bash
git add makebootfiles.sh tests/test_bm_path.sh
git commit -m "refactor: makebootfiles.sh bm_path helper + lib/device.sh + SPIRO_OSCHECK hook"
```

---

### Task 4: `makebootfiles.sh` — 非交互参数化 + 生成 `boot_order.json`

**Files:**
- Modify: `makebootfiles.sh`（read 提示段 46–49、115、147；文件末尾）
- Create: `tests/mockbin/irecovery`、`tests/mockbin/pzb`（mock 可执行文件）
- Create: `tests/test_makeboot_args.sh`

- [ ] **Step 1: 写 mock 与失败测试**

`tests/mockbin/irecovery`：

```bash
#!/bin/bash
# mock irecovery: answers -q with a fixture, ignores everything else
if [ "${1:-}" = "-q" ]; then
    cat <<'EOF'
MODE: DFU
CPID: 0x8020
BDID: 0x0e
ECID: 0x1111111111111111
PRODUCT: iPhone11,8
MODEL: n841ap
PWND: usbliter8
EOF
    exit 0
fi
exit 0
```

`tests/mockbin/pzb`：

```bash
#!/bin/bash
# mock pzb: log the call, create the requested file (basename) so the script can proceed
echo "MOCKPBZ $*" >> "${MOCKBIN_LOG:-/tmp/mockbin_calls.log}"
[ -n "${2:-}" ] && mkdir -p "$(dirname "$2")" 2>/dev/null && : > "$2" 2>/dev/null
exit 0
```

`tests/test_makeboot_args.sh`：

```bash
#!/bin/bash
# tests/test_makeboot_args.sh - non-interactive arg parsing + boot_order.json generation
set -u
cd "$(dirname "$0")/.."
chmod +x tests/mockbin/irecovery tests/mockbin/pzb

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 ($2)"; fails=$((fails+1)); fi }

export MOCKBIN_LOG=/tmp/mockbin_calls.log
: > "$MOCKBIN_LOG"
rm -rf bootchain/n841ap--ramdisk

# URL 模式 + 全参数 + 非 TTY：不得出现交互提示，且要走到 pzb 下载并生成 boot_order.json
out=$(SPIRO_OSCHECK=tests/mockbin bash ./makebootfiles.sh "http://example.invalid/fw.ipsw" firmwarekeys_14.4.2_18D70_n841.json --type ramdisk --bootargs neither </dev/null 2>&1)
rc=$?

if printf '%s' "$out" | grep -q "Are you going to be dualbooting"; then
    echo "FAIL: interactive prompt appeared in non-interactive mode"; fails=$((fails+1))
else
    echo "ok: no interactive prompt"
fi
grep -q "MOCKPBZ -g BuildManifest.plist" "$MOCKBIN_LOG" && echo "ok: reached pzb stage" || { echo "FAIL: never reached pzb"; fails=$((fails+1)); }
if [ -f bootchain/n841ap--ramdisk/boot_order.json ] && Darwin/jq -e . bootchain/n841ap--ramdisk/boot_order.json >/dev/null 2>&1; then
    echo "ok: boot_order.json generated and valid"
    Darwin/jq -e '[.sequence[].send_order] == ([.sequence[].send_order] | sort)' bootchain/n841ap--ramdisk/boot_order.json >/dev/null \
        && echo "ok: send_order sequential" || { echo "FAIL: send_order not sequential"; fails=$((fails+1)); }
    Darwin/jq -e '.sequence[] | select(.irecv_command=="ramdisk")' bootchain/n841ap--ramdisk/boot_order.json >/dev/null \
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

rm -rf bootchain/n841ap--ramdisk work
if [ "$fails" -gt 0 ]; then echo "test_makeboot_args: $fails FAILURES"; exit 1; fi
echo "test_makeboot_args: all pass"
```

注意：测试依赖 makebootfiles 在 mock 环境下能"带病"跑完（无 `set -e`，hdiutil/img4 等失败不中断）。mock 还需补 `img4`、`iBoot64patcher_cryptic`、`kairos`、`gtar`、`trustcache`、`jq`（软链 `../../Darwin/jq`）、`usbliter8_boot`，每个都是 `: ; exit 0` 形式（jq 除外）。

`tests/mockbin/img4`（其余同构，替换文件名即可；jq 用 `ln -s ../../Darwin/jq tests/mockbin/jq`）：

```bash
#!/bin/bash
echo "MOCK $(basename "$0") $*" >> "${MOCKBIN_LOG:-/tmp/mockbin_calls.log}"
# honor -o <out> so later steps find files
while [ "$#" -gt 0 ]; do [ "$1" = "-o" ] && { : > "$2" 2>/dev/null; break; }; shift; done
exit 0
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_makeboot_args.sh`
Expected: FAIL — 出现交互提示文本 / 无 "missing --type" 报错 / 无 boot_order.json

- [ ] **Step 3: 参数解析（插到 `fwkeyjson=$option2` 校验之后、`mkdir work` 之前）**

```bash
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
```

- [ ] **Step 4: 替换三处 `read` 提示**

原 46–49 行（`mkdir work; cd work` 之后的两个 read）替换为（注意保持在 `cd work` 之前完成取值，原有 `mkdir work; cd work` 顺序不变）：

```bash
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
```

原 115 行 dualboot 盘符：

```bash
    if [ -z "$DUALBOOT_DISK" ]; then
        if [ -t 0 ]; then
            read -p "What is the disk0s1s number of your second iOS partition, such as disk0s1s8:" DUALBOOT_DISK
        else
            die "missing --dualboot-disk and stdin is not a TTY"
        fi
    fi
    dualbootdisk="$DUALBOOT_DISK"
```

原 147 行 IM4M 路径（非 ramdisk 分支）：

```bash
    if [ -z "$IM4M_ARG" ]; then
        if [ -t 0 ]; then
            read -p "Please drag or type a path to your IM4M/APTicket.der file: " IM4M_ARG
        else
            die "missing --im4m and stdin is not a TTY"
        fi
    fi
    IM4MPath="$IM4M_ARG"
```

- [ ] **Step 5: 文件末尾（`echo 'To boot, run...'` 之前）生成 `boot_order.json`**

```bash
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
```

- [ ] **Step 6: 运行全部测试确认通过**

Run: `bash tests/run_tests.sh`
Expected: 三个套件全 pass（test_common / test_device_lib / test_bm_path / test_makeboot_args）

- [ ] **Step 7: Commit**

```bash
git add makebootfiles.sh tests/test_makeboot_args.sh tests/mockbin/
git commit -m "feat: non-interactive makebootfiles.sh (--type/--bootargs/--dualboot-disk/--im4m) + boot_order.json generation"
```

---

### Task 5: `spiro.sh` — JSON 执行器 + 超时 + pre-flight + `--dry-run` + 安全闸 + legacy 回退

**Files:**
- Modify: `spiro.sh`（整体重写，完整内容见下）
- Create: `tests/test_spiro.sh`
- Create: `tests/fixtures/bc-danger/boot_order.json`

- [ ] **Step 1: 写失败测试 `tests/test_spiro.sh`**

```bash
#!/bin/bash
# tests/test_spiro.sh - spiro.sh executor tests (offline, dry-run only)
set -u
cd "$(dirname "$0")/.."

fails=0
note_fail() { echo "FAIL: $1"; fails=$((fails+1)); }

CHAIN="n841ap-14.4.2-18D70-ramdisk"
JSON="bootchain/$CHAIN/boot_order.json"

# 1) JSON path vs legacy fallback: dry-run sequences must be identical
if [ -f "$JSON" ]; then
    out_json=$(bash ./spiro.sh boot "$CHAIN" --dry-run 2>/dev/null | grep '^DRYRUN:')
    mv "$JSON" "/tmp/boot_order_backup.json"
    out_legacy=$(bash ./spiro.sh boot "$CHAIN" --dry-run 2>/dev/null | grep '^DRYRUN:')
    mv "/tmp/boot_order_backup.json" "$JSON"
    if [ "$out_json" = "$out_legacy" ] && [ -n "$out_json" ]; then
        echo "ok: dry-run JSON == legacy"
    else
        note_fail "dry-run JSON != legacy"
        diff <(printf '%s\n' "$out_json") <(printf '%s\n' "$out_legacy") | head -10
    fi
else
    echo "SKIP: $JSON missing (created in Task 6)"
fi

# 2) dangerous boot-args gate fires even in dry-run
out=$(bash ./spiro.sh boot tests/fixtures/bc-danger --dry-run 2>&1)
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "refusing dangerous boot-args" \
    && echo "ok: dangerous boot-args refused" || note_fail "danger gate (rc=$rc): $out"

# 3) dangerous gate overridable
out=$(ALLOW_DANGEROUS_BOOTARGS=1 bash ./spiro.sh boot tests/fixtures/bc-danger --dry-run 2>&1)
rc=$?
[ "$rc" -eq 0 ] && echo "ok: ALLOW_DANGEROUS_BOOTARGS=1 override" || note_fail "danger override (rc=$rc)"

# 4) missing bootchain dir reported
out=$(bash ./spiro.sh boot no-such-chain --dry-run 2>&1)
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not found" \
    && echo "ok: missing bootchain reported" || note_fail "missing bootchain (rc=$rc)"

if [ "$fails" -gt 0 ]; then echo "test_spiro: $fails FAILURES"; exit 1; fi
echo "test_spiro: all pass"
```

`tests/fixtures/bc-danger/boot_order.json`：

```json
{
  "version": 1,
  "sequence": [
    {"action": "command", "command": "setenv boot-args rd=md0 nand-enable-reformat=1", "send_order": 0}
  ]
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_spiro.sh`
Expected: FAIL — danger gate 不存在（命令被直接打印/执行）、override 不存在；（dry-run diff 项因 Task 6 的 JSON 未建而 SKIP）

- [ ] **Step 3: 整体重写 `spiro.sh`（完整内容）**

```bash
#!/bin/bash
set -u
oscheck="${SPIRO_OSCHECK:-$(uname)}"
option="${1:-}"
bootchain="${2:-}"
dry_run=0
[ "${3:-}" = "--dry-run" ] && dry_run=1

BUILD=$(grep "BUILD" verinfo | cut -d':' -f2)
VERSION=$(grep "VERSION" verinfo | cut -d':' -f2)
BRANCH=$(git branch --show-current 2>/dev/null || true)

IRECOVERY="$oscheck"/irecovery
JQ="$oscheck"/jq
IBOOT_MAPPING="resources/iboot_mapping.json"
. lib/common.sh
. lib/device.sh

echo "Welcome to Spironolactone v$VERSION (Build: $BUILD-$BRANCH)!"

[ "$option" = boot ] || die 'To boot, run the script as "./spiro.sh boot <chain> [--dry-run]"'
[ -n "$bootchain" ] || die 'To boot, you need to provide a bootchain name with "./spiro.sh boot"'
if [ -d "$bootchain" ]; then BC_DIR="$bootchain"; else BC_DIR="bootchain/$bootchain"; fi
[ -d "$BC_DIR" ] || die "bootchain dir not found: $BC_DIR"

setup_log spiro
if [ "$dry_run" != 1 ]; then
    is_pwned_dfu || die "no pwned DFU device (irecovery -q should show PWND:). Attach the RP2350 and enter DFU first."
fi

send_file() { # send_file <path> <timeout>
    local f="$1" t="$2"
    [ -f "$f" ] || die "missing file: $f"
    if [ "$dry_run" = 1 ]; then printf 'DRYRUN: %s -f %s\n' "$IRECOVERY" "$f"; return 0; fi
    run_timeout "$t" "$IRECOVERY" -f "$f" || die "send failed/timeout (${t}s): $f (log: $LOG_FILE)"
}

send_cmd() { # send_cmd <command> <timeout>
    local c="$1" t="$2"
    case "$c" in
        "setenv boot-args "*)
            if ! scan_dangerous_bootargs "$c" && [ "${ALLOW_DANGEROUS_BOOTARGS:-0}" != "1" ]; then
                die "refusing dangerous boot-args: $c (set ALLOW_DANGEROUS_BOOTARGS=1 to override)"
            fi ;;
    esac
    log "CMD: $c"
    if [ "$dry_run" = 1 ]; then printf 'DRYRUN: %s -c %s\n' "$IRECOVERY" "$c"; return 0; fi
    run_timeout "$t" "$IRECOVERY" -c "$c" || die "command failed/timeout (${t}s): $c (log: $LOG_FILE)"
}

maybe_sleep() { # maybe_sleep <secs> — 0 skips; prints in dry-run
    [ "${1:-0}" != "0" ] || return 0
    if [ "$dry_run" = 1 ]; then printf 'DRYRUN: sleep %s\n' "$1"; return 0; fi
    sleep "$1"
}

big_timeout() { # big_timeout <filename>
    case "$1" in
        ramdisk.img4|kernelcache.img4) printf '%s' "${SPIRO_IRECV_TIMEOUT:-90}" ;;
        *) printf '%s' "${SPIRO_IRECV_TIMEOUT:-15}" ;;
    esac
}

boot_usbliter8() { # boot_usbliter8 <path> <sleep_after>
    local f="$1"
    [ -f "$f" ] || die "missing file: $f"
    log "Loading iBoot!"
    if [ "$dry_run" = 1 ]; then
        printf 'DRYRUN: %s %s\n' "$oscheck/usbliter8_boot" "$f"
    else
        run_timeout 60 "$oscheck"/usbliter8_boot "$f" || die "usbliter8_boot failed/timeout (log: $LOG_FILE)"
    fi
    maybe_sleep "${2:-0}"
}

boot_via_json() {
    local json="$BC_DIR/boot_order.json"
    "$JQ" -e . "$json" >/dev/null 2>&1 || die "invalid JSON: $json"
    local action filename cmd slp
    while IFS=$'\t' read -r action filename cmd slp; do
        case "$action" in
            usbliter8_boot)
                boot_usbliter8 "$BC_DIR/$filename" "$slp" ;;
            command)
                send_cmd "$cmd" 15 ;;
            component)
                [ -f "$BC_DIR/$filename" ] || die "missing file: $BC_DIR/$filename"
                is_img4_or_im4p "$BC_DIR/$filename" || die "not an IMG4/IM4P: $BC_DIR/$filename"
                send_file "$BC_DIR/$filename" "$(big_timeout "$filename")"
                maybe_sleep "$slp"
                send_cmd "$cmd" 15 ;;
            *) die "unknown action in $json: $action" ;;
        esac
    done < <("$JQ" -r '.sequence | sort_by(.send_order)[] | [.action, (.filename // ""), (.irecv_command // .command // ""), (.sleep_after // 0)] | @tsv' "$json")
}

boot_legacy() {
    warn "no boot_order.json in $BC_DIR; using legacy built-in sequence (see docs/superpowers/specs/2026-07-27-pipeline-hardening-design.md)"
    boot_usbliter8 "$BC_DIR/iBoot.patched.bin" 4
    if [ -e "$BC_DIR"/sep-firmware.img4 ]; then
        log "Loading SEP"
        send_file "$BC_DIR/sep-firmware.img4" 15
        send_cmd "rsepfirmware" 15
    fi
    log "Loading Devicetree!"
    send_file "$BC_DIR/devicetree.img4" 15
    send_cmd "devicetree" 15
    if [[ "$BC_DIR" == *ramdisk* ]]; then
        log "Loading Ramdisk!"
        send_file "$BC_DIR/ramdisk.img4" "$(big_timeout ramdisk.img4)"
        maybe_sleep 2
        send_cmd "ramdisk" 15
    fi
    log "Loading trustcache!"
    send_file "$BC_DIR/trustcache.img4" 15
    send_cmd "firmware" 15
    for c in AOP ANE AVE ISP GFX SIO; do
        log "Loading $c!"
        send_file "$BC_DIR/$c.img4" 15
        send_cmd "firmware" 15
    done
    log "Loading and Booting Kernel!"
    send_file "$BC_DIR/kernelcache.img4" "$(big_timeout kernelcache.img4)"
    send_cmd "bootx" 15
    if [[ "$BC_DIR" == *ramdisk* ]] && [ "$dry_run" != 1 ]; then
        echo 'In a few seconds, you can SSH via ./ssh.sh'
    fi
}

log "bootchain: $BC_DIR"
maybe_sleep 3
if [ -f "$BC_DIR/boot_order.json" ]; then
    log "using $BC_DIR/boot_order.json"
    boot_via_json
else
    boot_legacy
fi
log "done: boot sequence sent (log: $LOG_FILE)"
```

- [ ] **Step 4: 语法检查 + 运行测试**

Run: `bash -n spiro.sh && bash tests/test_spiro.sh`
Expected: 语法无输出；danger gate / override / missing-chain 三项 pass（diff 项 SKIP）

- [ ] **Step 5: Commit**

```bash
git add spiro.sh tests/test_spiro.sh tests/fixtures/
git commit -m "feat: spiro.sh boot_order.json executor with timeouts, preflight, dry-run, boot-args gate + legacy fallback"
```

---

### Task 6: 两个既有 bootchain 的 `boot_order.json` + dry-run 回归

**Files:**
- Create: `bootchain/n841ap-14.4.2-18D70-ramdisk/boot_order.json`
- Create: `bootchain/n841ap---ramdisk/boot_order.json`
- Modify: `tests/test_spiro.sh`（去掉 SKIP 分支，两条链都测 diff）

- [ ] **Step 1: 写 `bootchain/n841ap-14.4.2-18D70-ramdisk/boot_order.json`（含 SEP，顺序 = legacy）**

```json
{
  "version": 1,
  "sequence": [
    {"action": "usbliter8_boot", "filename": "iBoot.patched.bin", "send_order": 0, "sleep_after": 4},
    {"action": "component", "name": "RestoreSEP", "filename": "sep-firmware.img4", "irecv_command": "rsepfirmware", "send_order": 1},
    {"action": "component", "name": "DeviceTree", "filename": "devicetree.img4", "irecv_command": "devicetree", "send_order": 2},
    {"action": "component", "name": "RestoreRamDisk", "filename": "ramdisk.img4", "irecv_command": "ramdisk", "send_order": 3, "sleep_after": 2},
    {"action": "component", "name": "RestoreTrustCache", "filename": "trustcache.img4", "irecv_command": "firmware", "send_order": 4},
    {"action": "component", "name": "AOP", "filename": "AOP.img4", "irecv_command": "firmware", "send_order": 5},
    {"action": "component", "name": "ANE", "filename": "ANE.img4", "irecv_command": "firmware", "send_order": 6},
    {"action": "component", "name": "AVE", "filename": "AVE.img4", "irecv_command": "firmware", "send_order": 7},
    {"action": "component", "name": "ISP", "filename": "ISP.img4", "irecv_command": "firmware", "send_order": 8},
    {"action": "component", "name": "GFX", "filename": "GFX.img4", "irecv_command": "firmware", "send_order": 9},
    {"action": "component", "name": "SIO", "filename": "SIO.img4", "irecv_command": "firmware", "send_order": 10},
    {"action": "component", "name": "RestoreKernelCache", "filename": "kernelcache.img4", "irecv_command": "bootx", "send_order": 11}
  ]
}
```

- [ ] **Step 2: 写 `bootchain/n841ap---ramdisk/boot_order.json`（14.0b5 链无 SEP 文件，省略 RestoreSEP 行，其余相同，send_order 顺移为 0–10）**

- [ ] **Step 3: 更新 `tests/test_spiro.sh` 第 1 项：对两条链分别做 JSON vs legacy 的 dry-run diff（循环 `for CHAIN in n841ap-14.4.2-18D70-ramdisk n841ap---ramdisk`），删除 SKIP 分支**

- [ ] **Step 4: 运行回归**

Run: `bash tests/test_spiro.sh`
Expected: 两条链 `dry-run JSON == legacy` 全 pass

- [ ] **Step 5: Commit**

```bash
git add bootchain/*/boot_order.json tests/test_spiro.sh
git commit -m "feat: boot_order.json for existing 14.4.2 and 14.0b5 chains + dry-run regression"
```

---

### Task 7: `resources/mount_helpers.sh`（设备端 A12 安全挂载助手）

**Files:**
- Create: `resources/mount_helpers.sh`
- Create: `tests/test_mount_helpers_static.sh`

- [ ] **Step 1: 写失败静态测试 `tests/test_mount_helpers_static.sh`**

```bash
#!/bin/bash
# tests/test_mount_helpers_static.sh - static safety checks for the on-device helper
set -u
cd "$(dirname "$0")/.."
F="resources/mount_helpers.sh"

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi }

[ -f "$F" ]; check "exists" 0 $?
sh -n "$F" 2>/dev/null; check "sh syntax" 0 $?

grep -q 'seputil' "$F" && check "MUST NOT call seputil (A12 panic)" 1 0 || check "no seputil" 0 0
grep -q 'gigalocker' "$F" && check "MUST NOT call gigalocker" 1 0 || check "no gigalocker" 0 0
grep -q -- '--try-data' "$F"; check "has --try-data opt-in" 0 $?
grep -q 'nand-enable-reformat' "$F"; check "refuses dangerous boot-args" 0 $?
grep -q 'run_bg_timeout' "$F"; check "all mounts timeout-guarded" 0 $?
grep -q 'apfs.util' "$F"; check "label probing via apfs.util" 0 $?
grep -q 'oblit-inprogress' "$F"; check "oblit nvram guard" 0 $?

if [ "$fails" -gt 0 ]; then echo "test_mount_helpers_static: $fails FAILURES"; exit 1; fi
echo "test_mount_helpers_static: all pass"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_mount_helpers_static.sh`
Expected: FAIL — 文件不存在

- [ ] **Step 3: 实现 `resources/mount_helpers.sh`（完整内容）**

```sh
#!/bin/sh
# mount_helpers.sh - A12-safe mount helper for Spironolactone SSH ramdisks.
# Runs ON DEVICE over SSH (push with ./ssh.sh push-helpers).
# HARD RULE: never call seputil/gigalocker on A12 ramdisks (double SEPOS init -> panic,
# see RESEARCH_A12_MNT2.md). Data is refused by default (BPR blocks it in DFU context).
set +e
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/System/Library/Filesystems/apfs.fs
APFS_UTIL=/System/Library/Filesystems/apfs.fs/apfs.util
MOUNT_APFS=/System/Library/Filesystems/apfs.fs/mount_apfs
[ -x "$MOUNT_APFS" ] || MOUNT_APFS=/sbin/mount_apfs

TRY_DATA=0
[ "${1:-}" = "--try-data" ] && TRY_DATA=1

log(){ echo "[spiro-mount] $*"; }

mounted_on(){ (/sbin/mount 2>/dev/null || /bin/mount 2>/dev/null) | awk -v m="$1" '$3==m{print $1; exit}'; }
label_of(){ "$APFS_UTIL" -p "$1" 2>/dev/null | sed -n '1p'; }

run_bg_timeout(){
    _sec="$1"; shift
    "$@" &
    _pid=$!; _i=0
    while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_i" -ge "$_sec" ]; then
            log "timeout ${_sec}s: $*"
            kill -9 "$_pid" 2>/dev/null
            wait "$_pid" 2>/dev/null
            return 124
        fi
        sleep 1; _i=$((_i+1))
    done
    wait "$_pid"
    return $?
}

cleanup_oblit(){
    /usr/sbin/nvram -d oblit-inprogress >/dev/null 2>&1
    /usr/sbin/nvram -d obliteration >/dev/null 2>&1
    /usr/sbin/nvram auto-boot=true >/dev/null 2>&1
}

ba=$(/usr/sbin/nvram -p 2>/dev/null | /usr/bin/grep '^boot-args')
case "$ba" in
    *nand-enable-reformat=1*)
        log "refuse: boot-args contain nand-enable-reformat=1: $ba"
        exit 76
        ;;
esac

cleanup_oblit
for d in /mnt1 /mnt2 /mnt6 /mnt7; do /bin/mkdir -p "$d" 2>/dev/null; done

SYS=""; PREBOOT=""; XART=""; DATA=""
for prefix in /dev/disk0s1s /dev/disk1s; do
    for i in 1 2 3 4 5 6 7 8 9; do
        dev="${prefix}${i}"
        [ -e "$dev" ] || continue
        lab=$(label_of "$dev")
        [ -n "$lab" ] && log "$dev label=$lab"
        case "$lab" in
            System)  [ -z "$SYS" ] && SYS="$dev" ;;
            Preboot) [ -z "$PREBOOT" ] && PREBOOT="$dev" ;;
            xART)    [ -z "$XART" ] && XART="$dev" ;;
            Data)    [ -z "$DATA" ] && DATA="$dev" ;;
        esac
    done
done
[ -z "$SYS" ] && [ -e /dev/disk0s1s1 ] && SYS=/dev/disk0s1s1
[ -z "$DATA" ] && [ -e /dev/disk0s1s2 ] && DATA=/dev/disk0s1s2
log "resolved sys=${SYS:-N/A} preboot=${PREBOOT:-N/A} xart=${XART:-N/A} data=${DATA:-N/A}"

mount_one(){
    dev="$1"; mp="$2"
    [ -n "$dev" ] || { log "skip $mp: no device"; return 1; }
    cur=$(mounted_on "$mp")
    if [ -n "$cur" ]; then
        log "skip $mp: already mounted as $cur"
        return 0
    fi
    log "mount $dev -> $mp (20s timeout)"
    run_bg_timeout 20 "$MOUNT_APFS" "$dev" "$mp"
    rc=$?
    [ $rc -eq 0 ] || log "mount failed rc=$rc: $dev -> $mp"
    return $rc
}

mount_one "$SYS" /mnt1
mount_one "$PREBOOT" /mnt6
mount_one "$XART" /mnt7

if [ "$TRY_DATA" = "1" ]; then
    log "WARNING: Data mount on A12 DFU hangs by SEP BPR (RESEARCH_A12_MNT2.md); trying with 20s guard"
    mount_one "$DATA" /mnt2
    if [ -d /mnt2/mobile ] && [ -d /mnt2/root ] && [ -d /mnt2/containers ]; then
        log "/mnt2 ready (unexpected success - please report the exact configuration!)"
    else
        log "/mnt2 not ready (expected on A12)"
    fi
else
    log "skip Data (known A12 BPR hang); pass --try-data to attempt with guard"
fi

cleanup_oblit
exit 0
```

- [ ] **Step 4: 运行静态测试确认通过**

Run: `bash tests/test_mount_helpers_static.sh`
Expected: `test_mount_helpers_static: all pass`

- [ ] **Step 5: Commit**

```bash
git add resources/mount_helpers.sh tests/test_mount_helpers_static.sh
git commit -m "feat: A12-safe on-device mount helper (label probing, timeouts, data refused by default)"
```

---

### Task 8: `scripts/validate_mounts.sh` + `ssh.sh push-helpers`

**Files:**
- Create: `scripts/validate_mounts.sh`
- Modify: `ssh.sh`（整体重写，完整内容见下）
- Create: `tests/test_validate_ssh.sh`

- [ ] **Step 1: 写失败测试 `tests/test_validate_ssh.sh`**

```bash
#!/bin/bash
# tests/test_validate_ssh.sh - static checks for validate_mounts.sh and ssh.sh
set -u
cd "$(dirname "$0")/.."

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi }

bash -n scripts/validate_mounts.sh 2>/dev/null; check "validate_mounts.sh syntax" 0 $?
bash -n ssh.sh 2>/dev/null; check "ssh.sh syntax" 0 $?
grep -q 'push-helpers' ssh.sh; check "ssh.sh has push-helpers" 0 $?
grep -q 'mount_helpers.sh' ssh.sh; check "push-helpers pushes mount_helpers.sh" 0 $?
grep -q '/mnt1' scripts/validate_mounts.sh; check "validator checks /mnt1" 0 $?
grep -q '/mnt6' scripts/validate_mounts.sh; check "validator checks /mnt6" 0 $?
grep -q '/mnt7' scripts/validate_mounts.sh; check "validator checks /mnt7" 0 $?
grep -qE 'READY|WARNINGS|FAIL' scripts/validate_mounts.sh; check "validator 3-level verdict" 0 $?
grep -q 'seputil' scripts/validate_mounts.sh && check "validator MUST NOT call seputil" 1 0 || check "validator no seputil" 0 0

if [ "$fails" -gt 0 ]; then echo "test_validate_ssh: $fails FAILURES"; exit 1; fi
echo "test_validate_ssh: all pass"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_validate_ssh.sh`
Expected: FAIL — 文件不存在 / push-helpers 不存在

- [ ] **Step 3: 实现 `scripts/validate_mounts.sh`（完整内容）**

```bash
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
```

- [ ] **Step 4: 整体重写 `ssh.sh`（完整内容；保持原有调用习惯兼容）**

```bash
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
        "$oscheck"/sshpass -p 'alpine' ssh -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -p2222 root@localhost "${1:-}"
        ;;
esac
```

- [ ] **Step 5: 运行测试确认通过**

Run: `bash tests/test_validate_ssh.sh`
Expected: `test_validate_ssh: all pass`

- [ ] **Step 6: Commit**

```bash
git add scripts/validate_mounts.sh ssh.sh tests/test_validate_ssh.sh
git commit -m "feat: mount validator + ssh.sh push-helpers subcommand"
```

---

### Task 9: README 更新 + 全量回归 + 收尾

**Files:**
- Modify: `README.md`（Usage 段）
- Modify: `tests/run_tests.sh`（如有新套件遗漏则无需改，自动 glob）

- [ ] **Step 1: README `# Usage` 段（原 23–28 行第 1–5 条）替换为**

```markdown
1. Get the key json file: Head to https://theapplewiki.com/wiki/Firmware and head to your iOS version page for your device type (iPhone or iPad), then head to the specific device section (i.e. iPhone XR or iPad Air (3rd generation)), and then find your iOS version you want to make a ramdisk of, then click on the "iDeviceX,X" page, then download the keys json.
2. run `https://github.com/Orangera1n/spironolactone.git` and `cd spironolactone`.
3. To make a bootchain, run `./makebootfiles.sh (iOS version here) (location of firmware key json here)`. Non-interactive flags: `--type ramdisk|dualboot|downgrade --bootargs verbose|serial|neither [--dualboot-disk disk0s1sN] [--im4m path]` (env `SPIRO_TYPE`/`SPIRO_BOOTARGS`/`SPIRO_DUALBOOT_DISK`/`SPIRO_IM4M` also work). Each bootchain now ships a `boot_order.json` describing the exact boot sequence.
4. To boot a chain, run the command makebootfiles.sh tells you to (`./spiro.sh boot <chain>`). Add `--dry-run` to print the sequence without a device; dangerous boot-args are refused unless `ALLOW_DANGEROUS_BOOTARGS=1`.
5. To ssh, run `./ssh.sh`. Push the on-device mount helper with `./ssh.sh push-helpers`, then `./ssh.sh 'sh /var/root/mount_helpers.sh'` mounts System/Preboot/xART (Data is refused by default on A12; `--try-data` attempts it with a 20s guard). Validate mounts from the host with `./scripts/validate_mounts.sh`.
```

- [ ] **Step 2: 全量回归**

Run: `bash tests/run_tests.sh && bash -n spiro.sh makebootfiles.sh ssh.sh scripts/validate_mounts.sh`
Expected: 全部套件 pass，语法检查无输出

- [ ] **Step 3: 真机冒烟清单（用户执行，写入 commit message 备注）**

```bash
./spiro.sh boot n841ap-14.4.2-18D70-ramdisk --dry-run   # 离线序列检查
./spiro.sh boot n841ap-14.4.2-18D70-ramdisk            # 真机引导
./ssh.sh push-helpers
./ssh.sh 'sh /var/root/mount_helpers.sh'               # 期望 /mnt1 /mnt6 /mnt7 挂载，Data 拒绝
./scripts/validate_mounts.sh                           # 期望 RESULT: READY（或 WARNINGS）
./ssh.sh 'sh /var/root/mount_helpers.sh --try-data'    # 期望 20s 内被 kill，设备不 panic，SSH 不断线
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README usage for non-interactive build, boot_order.json, mount helpers, validator"
```

---

## Self-Review 记录

- **Spec 覆盖**：§2 boot_order.json→Task 5/6；§3 非交互化→Task 4；§4 设备库→Task 2/3；§5 挂载助手+校验器→Task 7/8；§6 日志/错误处理→Task 1（lib/common.sh）+ 各任务内；§7 验证→Task 5/6 dry-run 回归 + Task 9 真机清单。无遗漏。
- **顺序不变性**：legacy 与 JSON 的 dry-run diff 由 Task 5/6 测试强制（含 sleep 位置：ramdisk 的 sleep 2 在 -f 与 -c 之间；usbliter8 的 sleep 4 在其后；开头 sleep 3 两路径共有）。
- **类型/命名一致性**：`run_timeout`/`scan_dangerous_bootargs`/`is_img4_or_im4p`/`bm_path`/`query_device`/`get_field` 全文一致；`SPIRO_OSCHECK` 在 4 个脚本中同一语义。
- **禁令**：`seputil`/`gigalocker` 只出现在测试的反向断言中，设备端脚本不含。
