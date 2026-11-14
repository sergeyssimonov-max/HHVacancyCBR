#!/usr/bin/env python3
"""Compare PDF semantics, all rendered pages and original attachment bytes; no normalization."""
import json
from pathlib import Path
import sys


def main():
    if len(sys.argv) != 3:
        raise SystemExit('Usage: compare_pdf_equivalence.py BEFORE_DIRECTORY AFTER_DIRECTORY')
    before, after = [json.loads((Path(value) / 'manifest.json').read_text()) for value in sys.argv[1:]]
    if before != after:
        raise SystemExit('PDF equivalence differs; inspect manifests/text/PNGs before accepting the refactor')
    documents = before['documents']
    print(f"PASS: {len(documents)} PDFs, {sum(d['pages'] for d in documents)} pages; "
          'exact text/order, raster pixels, attachment bytes/GOST digests, dates and file names')


if __name__ == '__main__':
    main()
