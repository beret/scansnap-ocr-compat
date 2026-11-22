#!/bin/bash
# Install OCRmyPDF plus the Apple Vision OCR engine plugin into a dedicated venv.
#
# The plugin is the packaged project https://github.com/mkyt/OCRmyPDF-AppleOCR,
# not a local reimplementation. Pinned versions keep the verified behaviour.
set -euo pipefail

VENV=${OCR_VENV:-$HOME/.local/share/ocrmypdf-appleocr/venv}
PYTHON=${OCR_PYTHON:-/opt/homebrew/bin/python3.15}
OCRMYPDF_VERSION=${OCRMYPDF_VERSION:-17.14.2}
PLUGIN_VERSION=${PLUGIN_VERSION:-0.4.2}

if [[ ! -x $VENV/bin/python ]]; then
    printf 'creating venv at %s\n' "$VENV"
    "$PYTHON" -m venv "$VENV"
fi

"$VENV/bin/python" -m pip --quiet install --upgrade pip
"$VENV/bin/python" -m pip --quiet install \
    "ocrmypdf==$OCRMYPDF_VERSION" \
    "ocrmypdf-appleocr==$PLUGIN_VERSION"

printf 'ocrmypdf: %s\n' "$("$VENV/bin/ocrmypdf" --version)"
printf 'engine:   %s\n' "$("$VENV/bin/python" -c 'from ocrmypdf_appleocr import AppleOCREngine; print(AppleOcrEngine.version())' 2>/dev/null || echo 'appleocr installed')"
printf '\nrun scans with: %s/appleocr/ocr-scan.sh FILE.pdf ...\n' "$(cd "$(dirname "$0")/.." && pwd)"
