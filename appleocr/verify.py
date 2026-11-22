#!/usr/bin/env python3
"""Check that an OCR pass added text without touching any scanned image.

Compares every image XObject reachable from the page resource dictionaries of
the input and output PDFs: raw (compressed) stream bytes, dimensions, colour
space and filters must match exactly. Exits nonzero if the output lost an
image, re-encoded one, or carries no extractable text.

    verify.py INPUT.pdf OUTPUT.pdf
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import pikepdf


def images(path: Path) -> list[dict]:
    found = []
    with pikepdf.open(path) as pdf:
        for number, page in enumerate(pdf.pages, start=1):
            resources = page.get('/Resources', None)
            if resources is None:
                continue
            xobjects = resources.get('/XObject', None)
            if xobjects is None:
                continue
            for name in xobjects.keys():
                obj = xobjects[name]
                if not isinstance(obj, pikepdf.Stream):
                    continue
                if str(obj.get('/Subtype', '')) != '/Image':
                    continue
                raw = bytes(obj.read_raw_bytes())
                found.append({
                    'page': number,
                    'name': str(name),
                    'width': int(obj.get('/Width', 0)),
                    'height': int(obj.get('/Height', 0)),
                    'filter': str(obj.get('/Filter', '')),
                    'colorspace': str(obj.get('/ColorSpace', '')),
                    'length': len(raw),
                    'sha256': hashlib.sha256(raw).hexdigest(),
                })
    return found


def text_bytes(path: Path) -> int:
    try:
        import subprocess
        proc = subprocess.run(
            ['pdftotext', str(path), '-'], capture_output=True, check=False
        )
        if proc.returncode != 0:
            return -1
        return len(b''.join(proc.stdout.split()))
    except FileNotFoundError:
        return -1


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source, result = Path(argv[1]), Path(argv[2])
    before, after = images(source), images(result)

    failures = 0
    if len(before) != len(after):
        print(f'image count changed: {len(before)} -> {len(after)}')
        failures += 1
    for old, new in zip(before, after):
        same = all(
            old[key] == new[key]
            for key in ('width', 'height', 'filter', 'colorspace', 'length', 'sha256')
        )
        print(
            f"page {old['page']:>3} {old['name']:<8} "
            f"{old['width']}x{old['height']} {old['filter']:<18} "
            f"{old['length']:>9} bytes  identical={same}"
        )
        failures += 0 if same else 1

    new_text = text_bytes(result)
    old_text = text_bytes(source)
    if new_text <= 0:
        print(f'no extractable text in output (pdftotext returned {new_text})')
        failures += 1
    else:
        print(f'extractable text: {old_text} -> {new_text} non-whitespace bytes')

    if failures:
        print(f'FAIL: {failures} check(s) failed')
        return 1
    print('PASS: every scanned image stream is byte-identical and text is present')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
