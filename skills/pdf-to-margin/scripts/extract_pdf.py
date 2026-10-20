#!/usr/bin/env python3
"""Extract all PDF pages locally with Poppler, retaining source-page indices."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def extract(pdf, out):
    pdf = pdf.expanduser().resolve(strict=True)
    if not pdf.is_file():
        raise ValueError("Input must be a PDF file")
    for tool in ("pdfinfo", "pdftotext"):
        if not shutil.which(tool):
            raise ValueError(f"Missing {tool}; install Poppler locally (macOS: brew install poppler)")
    info = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, text=True, check=True)
    match = re.search(r"^Pages:\s+(\d+)\s*$", info.stdout, re.MULTILINE)
    if not match or int(match[1]) < 1:
        raise ValueError("Could not determine PDF page count")
    count = int(match[1])
    with tempfile.TemporaryDirectory(prefix="margin-pdf-") as temporary:
        raw = Path(temporary) / "text.txt"
        subprocess.run(["pdftotext", "-layout", "-enc", "UTF-8", str(pdf), str(raw)], check=True, capture_output=True, text=True)
        texts = raw.read_text(encoding="utf-8").split("\f")
    if len(texts) == count + 1 and not texts[-1].strip():
        texts.pop()
    if len(texts) != count:
        raise ValueError(f"Page boundary mismatch: expected {count}, extracted {len(texts)}. Do not infer page references.")
    pages = [{"pdf_page": i + 1, "text": text.strip()} for i, text in enumerate(texts)]
    with pdf.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    review = [p["pdf_page"] for p in pages if len(re.sub(r"\s", "", p["text"])) < 40]
    manifest = {
        "source_filename": pdf.name, "sha256": digest, "pdf_pages": count,
        "extraction": "Poppler pdftotext -layout, UTF-8; no OCR",
        "review_pages": review,
        "page_characters": [{"pdf_page": p["pdf_page"], "characters": len(p["text"])} for p in pages],
        "warnings": (["Low-text pages need visual review; they may be scanned, illustrated, or blank."] if review else [])
    }
    out = out.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    outputs = (out / "pages.json", out / "manifest.json", out / "paginated.txt")
    if any(p.exists() for p in outputs):
        raise ValueError("Extraction outputs already exist; choose a new working directory")
    outputs[0].write_text(json.dumps(pages, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    outputs[1].write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    outputs[2].write_text("\n\n".join(f"=== PDF PAGE {p['pdf_page']} ===\n{p['text']}" for p in pages) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--out", type=Path, required=True, help="New private extraction directory")
    args = parser.parse_args()
    try:
        manifest = extract(args.pdf, args.out)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        print(f"Extraction failed: {detail}", file=sys.stderr)
        return 1
    print(f"Extracted {manifest['pdf_pages']} pages to {args.out}; SHA-256 {manifest['sha256']}")
    if manifest["review_pages"]:
        print("Visually review PDF pages: " + ", ".join(map(str, manifest["review_pages"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
