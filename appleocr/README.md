# Apple Vision OCR engine for ScanSnap PDFs

This directory installs an OCR engine that leaves ScanSnap Manager untouched:
the packaged plugin [mkyt/OCRmyPDF-AppleOCR](https://github.com/mkyt/OCRmyPDF-AppleOCR)
(`ocrmypdf-appleocr` on PyPI) driving Apple's Vision framework through
OCRmyPDF. No plugin source is maintained here.

Scheduling is not part of this repository. On this workstation the engine is
driven by `~/repos/infra/bin/ocr-watch.sh`, which watches the `SP Whatever`
profile folder and documents its filters, output type and logging in
`~/repos/infra/hosts/nova/README.md`.

## Install

```sh
./appleocr/setup.sh
```

This creates `$HOME/.local/share/ocrmypdf-appleocr/venv` (override with
`OCR_VENV`) and installs pinned `ocrmypdf==17.14.2` and
`ocrmypdf-appleocr==0.4.2`. Override `OCRMYPDF_VERSION` / `PLUGIN_VERSION` to
test other releases. The venv's `ocrmypdf` is invoked by absolute path.

## Invocation

`ocrmypdf-appleocr --ocr-engine appleocr -l eng in.pdf out.pdf` adds the text
layer. Output type and optimization are left at OCRmyPDF's defaults, which keep
the original page images; passing `--output-type pdf --optimize 0` pins the scan
streams byte for byte instead, at the cost of skipping PDF/A.

Measured with the defaults on 2026-11-22, six-page iX500 scan without a text
layer: PDF/A-2b output, 6,652 non-whitespace bytes of text, 9.1 s with 6 workers;
Flate image streams unchanged and the JPEG page rearranged losslessly.

## Limits

- Adds a text layer only. It cannot improve scan quality and runs after the file
  is saved.
- Vision chooses its own model. `-l` maps the usual Tesseract codes (`eng`,
  `deu`, `fra`, ...) to Vision languages; unmapped codes fall back to Vision's
  default.
