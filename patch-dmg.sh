#!/bin/bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo ./patch-dmg.sh INPUT.dmg OUTPUT.dmg
  sudo ./patch-dmg.sh INPUT.pkg OUTPUT.pkg
  sudo ./patch-dmg.sh --in-place INPUT.dmg|INPUT.pkg

Rebuild the ScanSnap Manager 7.2.70 WW installer with the OCR repair in its
payload. INPUT must contain a PFU Developer ID-signed, vanilla flat installer
package, or be a disk image containing that package at its root. The input is not modified
in the normal two-path form; OUTPUT must not already exist. --in-place makes
an atomic replacement only after creating INPUT.original as a non-overwriting
backup. It requires a regular file and a filesystem supporting hard links.
Legacy directory/bundle packages and different package layouts are rejected.

Root is required to preserve payload ownership. Several gigabytes of free
space are needed both in the temporary directory and beside the output. If a
valid sudo timestamp already exists, this script re-executes itself under sudo,
so a plain invocation works within that window. The vendor's distribution,
choices, resources and installer scripts are retained,
including its checks: the distribution refuses to install over an already
installed 7.2.70 WW Manager. Use the installed-app repair mode in that case.
The rebuilt package and image are unsigned and notarized. The modified app
and OCR helper are locally signed, not vendor-signed or notarized; macOS may
require an explicit approval to open the installer. No security settings are
changed by this script. Only process installer files from a trusted source.

This repository ships code only, never vendor installers. Obtain the matching
PFU package from your ScanSnap download or from
https://origin.pfultd.com/downloads/IMAGE/driver/ss/inst/ix1500/m-software/
(archived at https://web.archive.org/ once the vendor moves it).
EOF
}

die() { printf 'patch-dmg: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
# Re-exec under sudo when a timestamp is already valid, so both invocation
# styles work. Without a primed timestamp the run continues unprivileged and
# stops at the ownership gate after reporting any real input problems.
if [[ $(id -u) != 0 ]] && /usr/bin/sudo -n /usr/bin/true 2>/dev/null; then
    exec /usr/bin/sudo -n -- "$0" "$@"
fi
in_place=0
if [[ ${1:-} == --in-place ]]; then
    [[ $# == 2 ]] || { usage >&2; exit 2; }
    in_place=1
    input=$2
    output=$2
else
    [[ $# == 2 ]] || { usage >&2; exit 2; }
    input=$1
    output=$2
fi
[[ -f "$input" && ! -L "$input" ]] || die "input must be a regular, non-symlink file (legacy bundle packages are unsupported): $input"
input_dir=$(cd "$(dirname "$input")" && pwd -P) || die 'cannot resolve input directory'
input="$input_dir/$(basename "$input")"
output_dir=$(cd "$(dirname "$output")" && pwd -P) || die 'output directory must already exist'
output="$output_dir/$(basename "$output")"
case "$input" in /Applications/ScanSnap|/Applications/ScanSnap/*) die 'refusing to alter or use a file inside the installed ScanSnap directory' ;; esac
case "$output" in /Applications/ScanSnap|/Applications/ScanSnap/*) die 'refusing to write inside the installed ScanSnap directory' ;; esac
case "$input" in
    *.[dD][mM][gG]) kind=dmg ;;
    *.[pP][kK][gG]) kind=pkg ;;
    *) die 'input must have a .dmg or .pkg extension' ;;
esac
if (( ! in_place )); then
    case "$kind:$output" in
        dmg:*.[dD][mM][gG]|pkg:*.[pP][kK][gG]) ;;
        *) die "output must have the same .$kind extension as the input" ;;
    esac
    [[ ! -e "$output" && ! -L "$output" ]] || die "output already exists: $output"
else
    [[ ! -e "$input.original" && ! -L "$input.original" ]] || die "backup already exists: $input.original"
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P) || die 'cannot resolve script directory'
[[ -x "$script_dir/patch-app.sh" ]] || die 'patch-app.sh is missing or not executable'
input_identity=$(stat -f '%d:%i:%z:%m' "$input") || die 'cannot stat input'
input_owner=$(stat -f '%u:%g' "$input") || die 'cannot read input ownership'
work=$(mktemp -d "${TMPDIR:-/tmp}/scansnap-ocr-pkg.XXXXXXXX") || die 'cannot create temporary working directory'
publish_dir=''
mounted=0
source_device=''
detach_source() {
    (( mounted )) || return 0
    if [[ -n $source_device ]] && /usr/bin/hdiutil info | grep -Fq "$source_device"; then
        hdiutil detach "$source_device" >/dev/null || return 1
    fi
    mounted=0
}
cleanup() {
    local status=$?
    trap - EXIT
    if ! detach_source; then
        printf 'patch-dmg: could not detach temporary mount %s; detach it manually\n' "${source_device:-$work/mount}" >&2
        status=1
    fi
    if (( ! mounted )); then rm -rf "$work" || status=1; fi
    if [[ -n "$publish_dir" ]]; then rm -rf "$publish_dir" || status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
publish_dir=$(mktemp -d "$output_dir/.scansnap-ocr-output.XXXXXXXX") || die 'cannot create temporary output directory on destination filesystem'

if [[ $kind == dmg ]]; then
    mkdir "$work/mount" || die 'cannot create mount point'
    attachment=$(hdiutil attach -readonly -nobrowse -mountpoint "$work/mount" "$input") ||
        die 'cannot attach source image read-only'
    mounted=1
    source_device=$(printf '%s\n' "$attachment" | awk '/^\/dev\/disk/ {print $1; exit}')
    [[ -n $source_device ]] || die 'cannot identify the attached source image device'
    source_pkg="$work/mount/ScanSnap Manager.pkg"
    [[ -f "$source_pkg" && ! -L "$source_pkg" ]] || die 'image must contain a flat ScanSnap Manager.pkg at its root'
    ditto "$work/mount" "$work/image" || die 'cannot copy image contents to the staging directory'
else
    source_pkg=$input
fi

signature=$(LC_ALL=C /usr/sbin/pkgutil --check-signature "$source_pkg") || die 'cannot verify installer signature'
printf '%s\n' "$signature" | grep -Fq 'Status: signed by a developer certificate issued by Apple for distribution' || die 'installer is not signed by a trusted Developer ID certificate'
printf '%s\n' "$signature" | grep -Fq 'Developer ID Installer: PFU LIMITED (XW4U7W2E9L)' || die 'installer is not signed by PFU LIMITED'

pkgutil --expand "$source_pkg" "$work/expanded" || die 'cannot expand input: only flat installer packages are supported'
expanded="$work/expanded"
if [[ -f "$expanded/Distribution" ]]; then
    component="$expanded/ScansnapManager.pkg"
    [[ -d "$component" && ! -L "$component" ]] || die 'unsupported distribution: missing ScansnapManager.pkg component'
else
    component=$expanded
fi
[[ -f "$component/PackageInfo" && -f "$component/Bom" && -f "$component/Payload" && -d "$component/Scripts" ]] || die 'unsupported component: expected PackageInfo, Bom, Payload, and Scripts'
count=$(find "$expanded" -name PackageInfo -type f -print0 | tr -cd '\0' | wc -c | tr -d ' ') || die 'cannot inspect component packages'
[[ $count == 1 ]] || die 'unsupported distribution: expected exactly one component package'
info="$component/PackageInfo"
identifier=$(/usr/bin/xmllint --xpath 'string(/pkg-info/@identifier)' "$info") || die 'cannot parse component PackageInfo'
version=$(/usr/bin/xmllint --xpath 'string(/pkg-info/@version)' "$info") || die 'cannot read component version'
location=$(/usr/bin/xmllint --xpath 'string(/pkg-info/@install-location)' "$info") || die 'cannot read component install location'
[[ $identifier == jp.co.pfu.ScanSnap.V72L70WW && $version == 7.2.70 && $location == /Applications ]] || die "unsupported component identity, version or install location: $identifier $version $location"
[[ -f "$component/Scripts/preinstall" && -f "$component/Scripts/postinstall" ]] || die 'unsupported component: vendor preinstall/postinstall scripts are missing'
# The supported package's payload is root:admin except for the payload root.
# Reject a variant with different ownership rather than normalizing it silently.
lsbom -p ug "$component/Bom" | awk 'NR > 1 && $0 != "0\t80" { bad=1 } END { exit bad }' || die 'unsupported component: unexpected payload ownership in BOM'

# Expand just the selected component. Rebuild its payload and BOM together with
# pkgbuild; flatten-full alone would leave the original, now stale BOM in place.
[[ $(id -u) == 0 ]] || die 'run this command with sudo so payload ownership is preserved'
pkgutil --flatten "$component" "$work/component.pkg" || die 'cannot flatten component for payload extraction'
pkgutil --expand-full "$work/component.pkg" "$work/full-component" || die 'cannot extract component payload'
payload="$work/full-component/Payload"
app="$payload/ScanSnap/ScanSnap Manager.app"
[[ -d "$app" && ! -L "$app" ]] || die 'unsupported payload: ScanSnap Manager.app is missing'
[[ $(stat -f '%u:%g' "$app") == 0:80 ]] || die 'payload extraction did not preserve the expected root:admin ownership'
"$script_dir/patch-app.sh" stage "$app" || die 'patch-app.sh could not patch the staged Manager app'
chown -hR 0:80 "$app" || die 'cannot set vendor payload ownership on staged Manager app'
# The BOM's root entry maps to /Applications. Make it match that directory's
# ownership so installing cannot rewrite it; the vendor's own entry was built
# with its packaging user's numeric IDs.
chown 0:80 "$payload" || die 'cannot set payload root ownership'

pkgbuild --root "$payload" --ownership preserve --filter '^$' \
    --identifier "$identifier" --version "$version" --install-location "$location" \
    --compression legacy "$work/rebuilt-component.pkg" || die 'cannot rebuild component payload and BOM'
pkgutil --expand "$work/rebuilt-component.pkg" "$work/rebuilt" || die 'cannot expand rebuilt component'
[[ -f "$work/rebuilt/Bom" && -f "$work/rebuilt/Payload" ]] || die 'rebuilt component is missing its BOM or payload'
# pkgbuild writes the invoker's ownership if the chown above did not apply;
# catch that before an installer can deposit user-owned files in /Applications.
lsbom -p ug "$work/rebuilt/Bom" | awk 'NR > 1 && $0 != "0\t80" { bad=1 } END { exit bad }' ||
    die 'rebuilt payload does not have root:admin ownership; run with sudo'
[[ $(grep -c '^[[:space:]]*<payload[[:space:]]' "$info") == 1 && $(grep -c '^[[:space:]]*<payload[[:space:]]' "$work/rebuilt/PackageInfo") == 1 ]] || die 'unsupported PackageInfo payload metadata layout'
payload_info=$(grep '^[[:space:]]*<payload[[:space:]]' "$work/rebuilt/PackageInfo") || die 'cannot read rebuilt payload metadata'
awk -v replacement="$payload_info" '/^[[:space:]]*<payload[[:space:]]/ { print replacement; next } { print }' "$info" > "$work/PackageInfo" || die 'cannot update component payload metadata'
cp -p "$work/PackageInfo" "$info" || die 'cannot replace component PackageInfo'
if [[ -f "$expanded/Distribution" ]]; then
    install_kb=$(sed -n 's/.*installKBytes="\([0-9][0-9]*\)".*/\1/p' <<<"$payload_info")
    [[ -n $install_kb ]] || die 'rebuilt PackageInfo has no installKBytes value'
    component_ref="#$(basename "$component")"
    awk -v kb="$install_kb" -v ref="$component_ref" '
        index($0, ref) > 0 && /installKBytes="[0-9]+"/ {
            sub(/installKBytes="[0-9]+"/, "installKBytes=\"" kb "\"")
            changed++
        }
        { print }
        END { exit changed == 1 ? 0 : 1 }
    ' "$expanded/Distribution" > "$work/Distribution" ||
        die 'unsupported Distribution: expected one payload size reference'
    cp -p "$work/Distribution" "$expanded/Distribution" || die 'cannot update Distribution payload size'
fi
cp -p "$work/rebuilt/Bom" "$component/Bom" || die 'cannot replace component BOM'
cp -p "$work/rebuilt/Payload" "$component/Payload" || die 'cannot replace component payload'

if [[ $kind == dmg ]]; then
    pkgutil --flatten "$expanded" "$work/new.pkg" || die 'cannot rebuild installer distribution'
    cp -p "$work/new.pkg" "$work/image/ScanSnap Manager.pkg" || die 'cannot replace staged image package'
    detach_source || die 'cannot detach source image'
    candidate="$publish_dir/output.dmg"
    hdiutil create -quiet -format UDZO -srcfolder "$work/image" "$candidate" || die 'cannot create patched disk image'
else
    candidate="$publish_dir/output.pkg"
    pkgutil --flatten "$expanded" "$candidate" || die 'cannot rebuild installer package'
fi
chown "$input_owner" "$candidate" || die 'cannot set output ownership'
[[ $(stat -f '%d:%i:%z:%m' "$input") == "$input_identity" ]] || die 'input changed during processing; refusing to publish'
if (( in_place )); then
    /bin/link "$input" "$input.original" || die "cannot create non-overwriting backup: $input.original"
    [[ $(stat -f '%d:%i:%z:%m' "$input") == "$input_identity" && $(stat -f '%d:%i:%z:%m' "$input.original") == "$input_identity" ]] || die "input changed during backup; original backup retained at $input.original"
    mv -f "$candidate" "$input" || die "atomic replacement failed; original backup retained at $input.original"
    printf 'Patched installer: %s\nOriginal backup: %s\n' "$input" "$input.original"
else
    /bin/link "$candidate" "$output" || die "cannot publish output without overwriting an existing file: $output"
    printf 'Patched installer: %s\n' "$output"
fi
printf '%s\n' 'The installer is unsigned and unnotarized; the modified app is locally signed, not vendor-signed or notarized.'
printf '%s\n' 'The original installer checks and scripts still apply, including the same-version installation refusal.'
