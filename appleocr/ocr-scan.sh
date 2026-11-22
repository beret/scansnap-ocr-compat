#!/bin/bash
# Add a searchable text layer to scanned PDFs with Apple's Vision OCR engine.
#
# By default the result is written next to the input as NAME.appleocr.pdf and
# the input is left alone. --replace swaps the files only after verify.py has
# proven that every scanned image stream is byte-identical.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ocr-scan.sh [options] FILE.pdf [FILE.pdf ...]

Options:
  -r, --replace        replace each input with the OCR result (keeps NAME.pre-appleocr.pdf)
  -l, --language CODE  OCR language for OCRmyPDF, default eng (repeatable)
  -f, --force          re-OCR files that already contain text
  -n, --dry-run        report what would happen and exit
  -h, --help           show this help

Environment:
  OCR_VENV           venv created by setup.sh (default ~/venvs/ocrmypdf-appleocr)
  OCR_JOBS           worker count passed to ocrmypdf
  OCR_KEEP_WORKDIR   set to keep intermediate files
EOF
}

replace=0
force=0
dry_run=0
languages=()
files=()

while (($#)); do
    case $1 in
        -r|--replace) replace=1 ;;
        -f|--force) force=1 ;;
        -n|--dry-run) dry_run=1 ;;
        -l|--language) languages+=("$2"); shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; files+=("$@"); break ;;
        -*) printf 'ocr-scan: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *) files+=("$1") ;;
    esac
    shift
done

((${#files[@]})) || { usage >&2; exit 2; }

venv=${OCR_VENV:-$HOME/.local/share/ocrmypdf-appleocr/venv}
ocrmypdf=$venv/bin/ocrmypdf
[[ -x $ocrmypdf ]] || { printf 'ocr-scan: %s missing, run appleocr/setup.sh first\n' "$ocrmypdf" >&2; exit 1; }

script_path=$0
while [[ -L $script_path ]]; do
    link_target=$(/usr/bin/readlink "$script_path")
    case $link_target in
        /*) script_path=$link_target ;;
        *) script_path=$(dirname "$script_path")/$link_target ;;
    esac
done
script_dir=$(cd "$(dirname "$script_path")" && pwd -P)
verify=$script_dir/verify.py

language_args=()
for code in ${languages[@]+"${languages[@]}"}; do language_args+=(-l "$code"); done
((${#language_args[@]})) || language_args=(-l eng)

jobs_args=()
[[ -n ${OCR_JOBS:-} ]] && jobs_args=(--jobs "$OCR_JOBS")

status=0
workdir=''
cleanup() {
    local code=$?
    trap - EXIT
    [[ -n $workdir && -z ${OCR_KEEP_WORKDIR:-} ]] && rm -rf "$workdir"
    exit "$code"
}
trap cleanup EXIT

for input in ${files[@]+"${files[@]}"}; do
    if [[ ! -f $input ]]; then
        printf 'ocr-scan: %s is not a file\n' "$input" >&2
        status=1
        continue
    fi
    case $input in
        *.pdf|*.PDF) ;;
        *) printf 'ocr-scan: %s is not a PDF\n' "$input" >&2; status=1; continue ;;
    esac

    dir=$(cd "$(dirname "$input")" && pwd -P)
    base=$(basename "$input")
    stem=${base%.*}
    output=$dir/$stem.appleocr.pdf
    backup=$dir/$stem.pre-appleocr.pdf

    existing=$(pdftotext "$input" - 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')
    if ((existing > 0)) && ((!force)); then
        printf '%s: already has %s bytes of text, skipping (use --force to redo)\n' "$base" "$existing"
        continue
    fi

    if ((dry_run)); then
        if ((replace)); then
            printf '%s: would OCR and replace, keeping %s\n' "$base" "$(basename "$backup")"
        else
            printf '%s: would OCR into %s\n' "$base" "$(basename "$output")"
        fi
        continue
    fi

    if ((!replace)) && [[ -e $output ]]; then
        printf 'ocr-scan: refusing to overwrite %s\n' "$output" >&2
        status=1
        continue
    fi

    workdir=$(mktemp -d "${TMPDIR:-/tmp}/ocr-scan.XXXXXXXX")
    candidate=$workdir/result.pdf

    printf '%s: running Apple Vision OCR\n' "$base"
    if ! "$ocrmypdf" --output-type pdf --optimize 0 --ocr-engine appleocr \
            "${language_args[@]}" ${jobs_args[@]+"${jobs_args[@]}"} "$input" "$candidate"; then
        printf 'ocr-scan: ocrmypdf failed for %s\n' "$input" >&2
        status=1
        rm -rf "$workdir"; workdir=''
        continue
    fi

    if ! "$venv/bin/python" "$verify" "$input" "$candidate"; then
        printf 'ocr-scan: verification failed for %s, input untouched\n' "$input" >&2
        status=1
        rm -rf "$workdir"; workdir=''
        continue
    fi

    if ((replace)); then
        [[ -e $backup ]] && { printf 'ocr-scan: backup %s exists, refusing\n' "$backup" >&2; status=1; rm -rf "$workdir"; workdir=''; continue; }
        cp -p "$input" "$backup"
        mv "$candidate" "$output"
        mv "$output" "$input"
        printf '%s: replaced (backup %s)\n' "$base" "$(basename "$backup")"
    else
        mv "$candidate" "$output"
        printf '%s: wrote %s\n' "$base" "$(basename "$output")"
    fi
    rm -rf "$workdir"
    workdir=''
done

exit "$status"
