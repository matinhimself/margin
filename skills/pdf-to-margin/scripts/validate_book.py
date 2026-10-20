#!/usr/bin/env python3
"""Validate import-ready Margin JSON without writing to the app or database."""
import argparse
import json
import math
from pathlib import Path
import re
import sys


def validate(books):
    if not isinstance(books, list) or not books:
        raise ValueError("Expected a nonempty JSON array of books")
    ids = set()
    reports = []
    required = {"id", "title", "author", "subtitle", "category", "color", "minutes", "synopsis", "sections"}
    for index, book in enumerate(books, 1):
        prefix = f"Book {index}"
        if not isinstance(book, dict):
            raise ValueError(f"{prefix}: expected an object")
        if required - book.keys() or book.keys() - required - {"updatedAt", "chapters", "source"}:
            raise ValueError(f"{prefix}: missing fields {sorted(required - book.keys())}; unknown fields {sorted(book.keys() - required - {'updatedAt', 'chapters', 'source'})}")
        for field, maximum in {"id": 80, "title": 300, "author": 300, "subtitle": 500, "category": 100, "synopsis": 20000}.items():
            value = book[field]
            if not isinstance(value, str) or len(value.encode("utf-8")) > maximum:
                raise ValueError(f"{prefix}: {field} must be a string of at most {maximum} UTF-8 bytes")
            if field in {"id", "title", "author"} and not value.strip():
                raise ValueError(f"{prefix}: {field} is required")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", book["id"]):
            raise ValueError(f"{prefix}: invalid ID")
        if book["id"] in ids:
            raise ValueError(f"{prefix}: duplicate ID {book['id']}")
        ids.add(book["id"])
        if not isinstance(book["color"], str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", book["color"]):
            raise ValueError(f"{prefix}: color must be #RRGGBB")
        if type(book["minutes"]) is not int or not 1 <= book["minutes"] <= 999:
            raise ValueError(f"{prefix}: minutes must be an integer from 1 to 999")
        if "updatedAt" in book and not isinstance(book["updatedAt"], str):
            raise ValueError(f"{prefix}: updatedAt must be a string, or omitted")
        sections = book["sections"]
        if not isinstance(sections, list) or not 1 <= len(sections) <= 100:
            raise ValueError(f"{prefix}: expected 1–100 sections")
        chapters = book.get("chapters", [])
        if chapters is None:
            chapters = []
        if not isinstance(chapters, list) or len(chapters) > 1000:
            raise ValueError(f"{prefix}: expected at most 1000 full-book chapters")
        source = book.get("source")
        if source is not None and (not isinstance(source, dict) or set(source) != {"filename", "sha256"} or not isinstance(source["filename"], str) or not isinstance(source["sha256"], str) or not re.fullmatch(r"[a-fA-F0-9]{64}", source["sha256"])):
            raise ValueError(f"{prefix}: invalid read-only source metadata")
        reading = [book["synopsis"]]
        for number, section in enumerate(sections + chapters, 1):
            if not isinstance(section, dict) or not {"title", "body"}.issubset(section) or set(section) - {"title", "body", "sourcePage"}:
                raise ValueError(f"{prefix}, section {number}: expected title and body, and optional sourcePage")
            page = section.get("sourcePage")
            if page is not None and (type(page) is not int or not 1 <= page <= 100000):
                raise ValueError(f"{prefix}, section {number}: sourcePage must be a one-based PDF page")
            for field, maximum in {"title": 300, "body": 100000}.items():
                value = section[field]
                if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > maximum:
                    raise ValueError(f"{prefix}, section {number}: {field} must be nonempty and at most {maximum} UTF-8 bytes")
                if number <= len(sections):
                    reading.append(value)
        if len(json.dumps(book, ensure_ascii=False).encode("utf-8")) > 2 * 1024 * 1024:
            raise ValueError(f"{prefix}: book exceeds the 2 MiB HTTP payload limit")
        words = len(" ".join(reading).split())
        reports.append(f"{book['id']}: {len(sections)} sections, ~{words} whitespace-delimited words, estimated {max(1, math.ceil(words / 200))} min at 200 wpm; declared {book['minutes']} min")
    return reports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_file", type=Path)
    args = parser.parse_args()
    try:
        reports = validate(json.loads(args.json_file.read_text(encoding="utf-8")))
    except (ValueError, OSError) as error:
        print(f"Invalid: {error}", file=sys.stderr)
        return 1
    print("Valid Margin import JSON. Grounding and source coverage still require editorial review.")
    print("\n".join(reports))
    return 0


if __name__ == "__main__":
    sys.exit(main())
