#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: patch-app.sh stage APP
       patch-app.sh install APP
       patch-app.sh restore APP
       patch-app.sh --help

stage patches a disposable, unpacked ScanSnap Manager 7.2.70 app in place.
It must not be used on an installed app. A failed stage can leave that copy
partially modified. Paths containing ':' are unsupported by dyld.

install makes and patches a sibling copy, then replaces APP. It retains the
original signed app permanently at APP.vendor-backup/Original.app and
refuses to overwrite any existing backup. restore copies that backup back,
retains the backup, and saves the displaced app at
APP.pre-restore.XXXXXXXX/Replaced.app. Both modes refuse while any ScanSnap
Manager is running. They need write access to APP and its parent directory.

The patch is ad-hoc signed; it does not change SIP, privacy settings or profiles.
install leaves the patched bundle owned by the invoking user; the vendor copy
kept in the backup is unchanged. Use the installer path if vendor root:admin
ownership must be preserved.
EOF
}

die() { printf 'patch-app: %s\n' "$*" >&2; exit 1; }

if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi
[[ $# -eq 2 ]] || { usage >&2; exit 2; }
mode=$1
case "$mode" in stage|install|restore) ;; *) usage >&2; exit 2;; esac

script_dir=$(cd "$(dirname "$0")" && pwd -P)
input=$2
[[ -n $input ]] || die 'APP must not be empty'
case "$input" in /*) ;; *) input="$PWD/$input";; esac
while [[ $input != / && $input == */ ]]; do input=${input%/}; done
name=$(basename "$input")
[[ $name != . && $name != .. && $name != / ]] || die 'APP must name an app bundle'
parent=$(cd "$(dirname "$input")" && pwd -P) || die "cannot access app parent: $input"
app="$parent/$name"
[[ $app != *:* ]] || die 'app paths containing a colon are unsupported by dyld'
[[ ! -L $app ]] || die "app must not be a symlink: $app"
[[ -d $app ]] || die "app not found: $app"

backup="$app.vendor-backup"
tmp=''
build_tmp=''
rollback_from=''
rollback_to=''
empty_backup=''
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ -n $rollback_from && ( -e $rollback_from || -L $rollback_from ) ]]; then
        if [[ ! -e $rollback_to && ! -L $rollback_to ]]; then
            if ! mv "$rollback_from" "$rollback_to"; then
                printf 'patch-app: rollback failed; original remains at %s\n' "$rollback_from" >&2
                status=1
            fi
        else
            printf 'patch-app: rollback destination occupied; original remains at %s\n' "$rollback_from" >&2
            status=1
        fi
    fi
    if [[ -n $empty_backup && -d $empty_backup && ! -L $empty_backup ]]; then
        rmdir "$empty_backup" 2>/dev/null || :
    fi
    if [[ -n $build_tmp && -d $build_tmp && ! -L $build_tmp ]]; then rm -rf "$build_tmp"; fi
    if [[ -n $tmp && -d $tmp && ! -L $tmp ]]; then rm -rf "$tmp"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_directory() {
    [[ ! -L $1 && -d $1 ]] || die "expected a non-symlink directory: $1"
}
require_file() {
    [[ ! -L $1 && -f $1 ]] || die "expected a non-symlink file: $1"
}
check_paths() {
    local target=$1 p
    require_directory "$target"
    for p in Contents Contents/Helpers Contents/MacOS Contents/Helpers/OCRClientProcess.app \
             Contents/Helpers/OCRClientProcess.app/Contents \
             Contents/Helpers/OCRClientProcess.app/Contents/MacOS; do
        require_directory "$target/$p"
    done
    for p in Contents/Info.plist Contents/MacOS/'ScanSnap Manager' \
             Contents/Helpers/OCRClientProcess.app/Contents/Info.plist \
             Contents/Helpers/OCRClientProcess.app/Contents/MacOS/OCRClientProcess; do
        require_file "$target/$p"
    done
    # The helper is copied and re-signed; do not follow links anywhere within it.
    if [[ -n $(find "$target/Contents/Helpers/OCRClientProcess.app" -type l -print -quit) ]]; then
        die 'the OCR helper contains a symlink'
    fi
}
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
check_metadata() {
    local target=$1 info="$1/Contents/Info.plist" helper_info="$1/Contents/Helpers/OCRClientProcess.app/Contents/Info.plist"
    check_paths "$target"
    [[ $(plist_value "$info" CFBundleIdentifier) == jp.co.pfu.ScanSnap.V10L10 &&
       $(plist_value "$info" CFBundleShortVersionString) == 7.2.70 &&
       $(plist_value "$info" CFBundleVersion) == 1001 &&
       $(plist_value "$info" CFBundleExecutable) == 'ScanSnap Manager' ]] || die 'unsupported Manager identity or version'
    [[ $(plist_value "$helper_info" CFBundleIdentifier) == jp.co.pfu.SSClientProcess &&
       $(plist_value "$helper_info" CFBundleExecutable) == OCRClientProcess ]] || die 'unsupported OCR helper identity'
}
check_stock() {
    local target=$1 helper="$1/Contents/Helpers/OCRClientProcess.app" hash
    check_metadata "$target"
    [[ ! -e "$target/Contents/Helpers/OCRClientProcessReal.app" && ! -L "$target/Contents/Helpers/OCRClientProcessReal.app" &&
       ! -e "$target/Contents/Helpers/ScanSnapParentCompat.dylib" && ! -L "$target/Contents/Helpers/ScanSnapParentCompat.dylib" ]] || die 'app is already patched or contains conflicting patch files'
    hash=$(shasum -a 256 < "$helper/Contents/MacOS/OCRClientProcess")
    [[ ${hash%% *} == eb9beedfa706b472bdbaf574d5ded43d1a7bb970d78ea6fcc023df8db261976b ]] || die 'unsupported OCR helper SHA-256'
    codesign --verify --deep --strict --test-requirement '=anchor apple generic and certificate leaf[subject.OU] = "XW4U7W2E9L" and identifier "jp.co.pfu.ScanSnap.V10L10"' "$target" || die 'Manager is not a valid PFU-signed app'
    codesign --verify --deep --strict --test-requirement '=anchor apple generic and certificate leaf[subject.OU] = "XW4U7W2E9L" and identifier "jp.co.pfu.SSClientProcess"' "$helper" || die 'OCR helper is not validly PFU-signed'
}
check_not_running() {
    local processes
    processes=$(ps -axo ucomm=) || die 'cannot inspect running processes'
    if printf '%s\n' "$processes" | awk '$0 == "ScanSnap Manage" || $0 == "ScanSnap Manager" { found=1 } END { exit !found }'; then
        die 'ScanSnap Manager is running; quit it before install or restore'
    fi
}

stage_app() {
    local target=$1 helper="$1/Contents/Helpers/OCRClientProcess.app"
    local real="$1/Contents/Helpers/OCRClientProcessReal.app" dylib="$1/Contents/Helpers/ScanSnapParentCompat.dylib"
    local work
    check_stock "$target"
    work=$(mktemp -d "${TMPDIR:-/tmp}/scansnap-ocr-build.XXXXXXXX") || die 'cannot create build directory'
    # The build directory belongs to this invocation and is always removed by cleanup.
    build_tmp=$work
    codesign -d --entitlements :- "$target" > "$work/manager.plist" 2>/dev/null || die 'cannot read Manager entitlements'
    codesign -d --entitlements :- "$helper" > "$work/helper.plist" 2>/dev/null || die 'cannot read OCR helper entitlements'
    plutil -lint "$work/manager.plist" "$work/helper.plist" >/dev/null || die 'invalid vendor entitlements'
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.allow-dyld-environment-variables' "$work/helper.plist" >/dev/null 2>&1; then
        die 'OCR helper already has the dyld environment entitlement'
    fi
    cp "$work/helper.plist" "$work/worker.plist"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.allow-dyld-environment-variables bool true' "$work/worker.plist"
    xcrun clang -Wno-deprecated-declarations -arch x86_64 -dynamiclib -framework Carbon "$script_dir/src/parent-compat.c" -o "$work/ScanSnapParentCompat.dylib"
    xcrun clang -arch x86_64 "$script_dir/src/launcher.c" -o "$work/OCRClientProcess"
    codesign --force --sign - "$work/ScanSnapParentCompat.dylib"
    ditto "$helper" "$real"
    install -m 755 "$work/ScanSnapParentCompat.dylib" "$dylib"
    install -m 755 "$work/OCRClientProcess" "$helper/Contents/MacOS/OCRClientProcess"
    codesign --force --sign - --options runtime --entitlements "$work/worker.plist" "$real"
    codesign --force --sign - --options runtime --entitlements "$work/helper.plist" "$helper"
    codesign --force --sign - --options runtime --entitlements "$work/manager.plist" "$target"
    codesign --verify --deep --strict "$real" || die 'signed OCR worker verification failed'
    codesign --verify --deep --strict "$helper" || die 'signed OCR launcher verification failed'
    codesign --verify --deep --strict "$target" || die 'signed Manager verification failed'
    rm -rf "$work"
    build_tmp=''
}

case "$mode" in
stage)
    [[ $app != '/Applications/ScanSnap/ScanSnap Manager.app' ]] || die 'stage requires a disposable copy, not the installed Manager'
    stage_app "$app"
    printf 'Patched disposable app: %s\n' "$app"
    ;;
install)
    check_not_running
    check_stock "$app"
    [[ ! -e $backup && ! -L $backup ]] || die "backup already exists; refusing to overwrite: $backup"
    staging=$(mktemp -d "$parent/.scansnap-ocr-install.XXXXXXXX") || die 'cannot create staging directory beside app'
    tmp=$staging
    ditto "$app" "$staging/Manager.app"
    stage_app "$staging/Manager.app"
    check_not_running
    mkdir "$backup" || die "cannot create exclusive backup directory: $backup"
    empty_backup=$backup
    rollback_from="$backup/Original.app"
    rollback_to=$app
    mv "$app" "$backup/Original.app" || die 'cannot move original to backup'
    mv "$staging/Manager.app" "$app" || die 'cannot install patched app'
    rollback_from=''
    empty_backup=''
    printf 'Installed patched app: %s\nVendor backup: %s/Original.app\n' "$app" "$backup"
    ;;
restore)
    check_not_running
    [[ ! -L $backup && -d $backup ]] || die "vendor backup directory not found: $backup"
    check_stock "$backup/Original.app"
    check_metadata "$app"
    require_directory "$app/Contents/Helpers/OCRClientProcessReal.app"
    require_file "$app/Contents/Helpers/ScanSnapParentCompat.dylib"
    if ! codesign --verify --deep --strict "$app"; then
        printf 'patch-app: current app signature is invalid; preserving it before restoring the verified backup\n' >&2
    fi
    staging=$(mktemp -d "$parent/.scansnap-ocr-restore.XXXXXXXX") || die 'cannot create staging directory beside app'
    tmp=$staging
    ditto "$backup/Original.app" "$staging/Manager.app"
    check_stock "$staging/Manager.app"
    check_not_running
    saved=$(mktemp -d "$app.pre-restore.XXXXXXXX") || die 'cannot reserve a directory for the displaced app'
    empty_backup=$saved
    rollback_from="$saved/Replaced.app"
    rollback_to=$app
    mv "$app" "$saved/Replaced.app" || die 'cannot preserve current app'
    mv "$staging/Manager.app" "$app" || die 'cannot restore original app'
    rollback_from=''
    empty_backup=''
    printf 'Restored signed app: %s\nVendor backup retained: %s/Original.app\nPrevious app saved: %s/Replaced.app\n' "$app" "$backup" "$saved"
    ;;
esac
