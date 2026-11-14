#!/usr/bin/env python3
"""Losslessly finalize stored narration MP3 headers; dry-run unless --apply is supplied."""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile

from pipeline import normalize_mp3


def repair_narrations(database, apply=False, book_ids=()):
    database = Path(database).resolve()
    connection = sqlite3.connect(database.as_uri() + ("?mode=rw" if apply else "?mode=ro"), uri=True, timeout=30)
    changes = []
    try:
        rows = connection.execute("SELECT book_id,section_index,sha256,audio FROM narrations ORDER BY book_id,section_index").fetchall()
        with tempfile.TemporaryDirectory(prefix="margin-narration-") as folder:
            for book_id, index, old_hash, audio in rows:
                if book_ids and book_id not in book_ids:
                    continue
                if hashlib.sha256(audio).hexdigest() != old_hash:
                    raise ValueError("Stored narration checksum mismatch; no repairs applied.")
                normalized = normalize_mp3(Path(folder), audio)
                new_hash = hashlib.sha256(normalized).hexdigest()
                if new_hash != old_hash:
                    changes.append((book_id, index, old_hash, new_hash, normalized))
        report = {"applied": False, "sections": len(changes), "books": sorted({change[0] for change in changes})}
        if not apply or not changes:
            return report
        backup = database.with_name(database.name + ".narration-backup-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
        descriptor = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(descriptor)
        with closing(sqlite3.connect(backup)) as snapshot:
            connection.backup(snapshot)
        timestamp = datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
        connection.execute("BEGIN IMMEDIATE")
        for book_id, index, old_hash, new_hash, audio in changes:
            row = connection.execute("SELECT document FROM books WHERE id=?", (book_id,)).fetchone()
            if row is None:
                raise ValueError("Book changed during repair; no repairs applied.")
            book = json.loads(row[0])
            sections = book.get("sections", [])
            if index >= len(sections) or (sections[index].get("narration") or {}).get("sha256") != old_hash:
                raise ValueError("Narration changed during repair; no repairs applied.")
            result = connection.execute("UPDATE narrations SET sha256=?,audio=? WHERE book_id=? AND section_index=? AND sha256=?",
                                        (new_hash, audio, book_id, index, old_hash))
            if result.rowcount != 1:
                raise ValueError("Narration changed during repair; no repairs applied.")
            sections[index]["narration"]["sha256"] = new_hash
            book["updatedAt"] = timestamp
            connection.execute("UPDATE books SET document=?,updated_at=? WHERE id=?", (json.dumps(book, ensure_ascii=False), timestamp, book_id))
        connection.commit()
        return dict(report, applied=True, backup=str(backup))
    finally:
        connection.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--book", action="append", default=[], dest="book_ids")
    arguments = parser.parse_args()
    os.umask(0o077)
    print(json.dumps(repair_narrations(arguments.database, arguments.apply, arguments.book_ids)))
