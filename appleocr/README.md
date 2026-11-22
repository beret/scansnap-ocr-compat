# Apple Vision OCR with OCRmyPDF

Alternative repair path: leave ScanSnap Manager untouched and add the text layer
afterwards with Apple's Vision framework through OCRmyPDF. The OCR engine is the
packaged plugin [mkyt/OCRmyPDF-AppleOCR](https://github.com/mkyt/OCRmyPDF-AppleOCR)
(`ocrmypdf-appleocr` on PyPI), not code maintained here.

## Install

```sh
./appleocr/setup.sh
```

This creates `$HOME/.local/share/ocrmypdf-appleocr/venv` (override with
`OCR_VENV`) and installs pinned `ocrmypdf==17.14.2` and
`ocrmypdf-appleocr==0.4.2`. Override `OCRMYPDF_VERSION` / `PLUGIN_VERSION` to
test other releases.

Host links created alongside (see `~/repos/infra/hosts/nova/README.md`):

```sh
~/.local/bin/ocr-scan            -> repo appleocr/ocr-scan.sh
~/.local/bin/ocrmypdf-appleocr   -> venv/bin/ocrmypdf
```

## Use

```sh
ocr-scan FILE.pdf               # writes FILE.appleocr.pdf, input untouched
ocr-scan -r FILE.pdf            # replaces FILE.pdf, keeps FILE.pre-appleocr.pdf
ocr-scan -l deu FILE.pdf        # language code passed to OCRmyPDF (default eng)
ocr-scan -n FILE.pdf            # dry run
```

Files that already contain text are skipped unless `--force` is given. The skip
test uses `pdftotext` from poppler.

## What is guaranteed

- `--output-type pdf --optimize 0`: no PDF/A conversion, no Ghostscript pass, no
  image optimizer, so the scanned images are not re-encoded.
- `appleocr/verify.py` runs after every OCR pass and compares each page image
  XObject's raw compressed stream, dimensions, filter and colour space between
  input and output. Any difference aborts the replacement.
- With `--replace`, the new file is moved in only after verification passes.

Measured on a 6-page iX500 scan with no text layer (2026-11-22):

| Check | Result |
| --- | --- |
| Image XObjects | 6 → 6, every raw stream byte-identical (JPEG 263,144 B; Flate 102,216 / 67,458 / 106,315 / 382,324 / 302,652 B) |
| Extractable text | 0 → 6,652 non-whitespace bytes |
| Runtime | 9.1 s for 6 pages, 6 workers |

## Limits

- This adds a text layer only. It cannot improve scan quality, and it runs after
  the file is saved, so nothing invokes it automatically yet; the post-save hook
  is deliberately out of scope.
- Vision picks its own recognition model. `-l` maps the usual Tesseract codes
  (`eng`, `deu`, `fra`, ...) to Vision languages; unmapped codes fall through to
  Vision's default language.
- Scripts target macOS's `/bin/bash` 3.2: array expansions are guarded and the
  script path is resolved with `readlink`, because this host has no
  `/usr/bin/realpath`.
