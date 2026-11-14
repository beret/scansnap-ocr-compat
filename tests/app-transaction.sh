#!/bin/bash
set -euo pipefail

# This test uses an isolated copy even if the original Manager is running.
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
stock=${1:-/Applications/ScanSnap/ScanSnap Manager.app}
[[ -d $stock ]] || { printf 'Stock app not found: %s\n' "$stock" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/scansnap-ocr-transaction.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/ps" <<'EOF'
#!/bin/bash
/bin/ps "$@" | /usr/bin/awk '$0 != "ScanSnap Manage" && $0 != "ScanSnap Manager"'
EOF
chmod 755 "$work/bin/ps"
export PATH="$work/bin:$PATH"
app="$work/ScanSnap Manager.app"
/bin/cp -cR "$stock" "$app"

"$repo/scansnap-ocr" app install "$app"
[[ -d "$app.vendor-backup/Original.app" ]]
[[ -f "$app/Contents/Helpers/ScanSnapParentCompat.dylib" ]]
if "$repo/scansnap-ocr" app install "$app" > "$work/reinstall.log" 2>&1; then
    printf 'A second install unexpectedly succeeded\n' >&2
    exit 1
fi
# A damaged copy is still recoverable when its vendor backup is valid.
codesign --remove-signature "$app/Contents/MacOS/ScanSnap Manager"
"$repo/scansnap-ocr" app restore "$app" > "$work/recover.log" 2>&1
/usr/bin/codesign --verify --deep --strict --test-requirement '=anchor apple generic and certificate leaf[subject.OU] = "XW4U7W2E9L" and identifier "jp.co.pfu.ScanSnap.V10L10"' "$app"
[[ -d "$app.vendor-backup/Original.app" ]]
[[ ! -e "$app/Contents/Helpers/ScanSnapParentCompat.dylib" ]]
compgen -G "$app.pre-restore.*/Replaced.app" >/dev/null
printf 'Isolated install, duplicate refusal and stock restore passed.\n'
