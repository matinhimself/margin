from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import repair_narrations


class RepairNarrationsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.database = Path(self.folder.name) / "library.sqlite"
        self.audio = b"original audio"
        self.old_hash = hashlib.sha256(self.audio).hexdigest()
        self.book = {"id": "test", "updatedAt": "old", "sections": [
            {"body": "Hello", "narration": {"sha256": self.old_hash, "bodySHA256": "body", "words": [{"text": "Hello", "start": 0, "end": 2}]}}
            for _ in range(2)
        ]}
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("CREATE TABLE books(id TEXT PRIMARY KEY,document TEXT,updated_at TEXT)")
            connection.execute("CREATE TABLE narrations(book_id TEXT,section_index INTEGER,sha256 TEXT,audio BLOB)")
            connection.execute("INSERT INTO books VALUES(?,?,?)", ("test", json.dumps(self.book), "old"))
            connection.executemany("INSERT INTO narrations VALUES(?,?,?,?)", [("test", index, self.old_hash, self.audio) for index in range(2)])

    def read(self):
        with closing(sqlite3.connect(self.database)) as connection:
            book = json.loads(connection.execute("SELECT document FROM books").fetchone()[0])
            audio = connection.execute("SELECT sha256,audio FROM narrations ORDER BY section_index").fetchall()
            return book, audio

    def test_dry_run_never_changes_database_or_creates_backup(self):
        with patch.object(repair_narrations, "normalize_mp3", return_value=b"normalized"):
            result = repair_narrations.repair_narrations(self.database)
        self.assertEqual(result, {"applied": False, "sections": 2, "books": ["test"]})
        self.assertEqual(self.read(), (self.book, [(self.old_hash, self.audio)] * 2))
        self.assertEqual(list(self.database.parent.glob("*.narration-backup-*")), [])

    def test_apply_updates_cache_keys_preserves_alignment_and_backs_up_original(self):
        with patch.object(repair_narrations, "normalize_mp3", return_value=b"normalized"):
            result = repair_narrations.repair_narrations(self.database, apply=True)
        self.assertTrue(result["applied"])
        new_hash = hashlib.sha256(b"normalized").hexdigest()
        book, audio = self.read()
        self.assertEqual(audio, [(new_hash, b"normalized")] * 2)
        self.assertNotEqual(book["updatedAt"], "old")
        for index, section in enumerate(book["sections"]):
            original = self.book["sections"][index]
            self.assertEqual(section["body"], original["body"])
            self.assertEqual(section["narration"], dict(original["narration"], sha256=new_hash))
        backup = Path(result["backup"])
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        with closing(sqlite3.connect(backup)) as connection:
            self.assertEqual(json.loads(connection.execute("SELECT document FROM books").fetchone()[0]), self.book)

    def test_concurrent_metadata_change_rolls_back_all_sections(self):
        self.book["sections"][1]["narration"]["sha256"] = "changed"
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE books SET document=?", (json.dumps(self.book),))
        with patch.object(repair_narrations, "normalize_mp3", return_value=b"normalized"):
            with self.assertRaisesRegex(ValueError, "Narration changed"):
                repair_narrations.repair_narrations(self.database, apply=True)
        self.assertEqual(self.read(), (self.book, [(self.old_hash, self.audio)] * 2))

    def test_book_filter_and_already_normalized_audio_are_noops(self):
        with patch.object(repair_narrations, "normalize_mp3", return_value=self.audio) as normalize:
            result = repair_narrations.repair_narrations(self.database, apply=True, book_ids=["other"])
            normalize.assert_not_called()
            self.assertEqual(result["sections"], 0)
            result = repair_narrations.repair_narrations(self.database, apply=True)
            self.assertEqual(result["sections"], 0)
            self.assertFalse(result["applied"])

    def test_checksum_mismatch_fails_without_writing(self):
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE narrations SET audio=? WHERE section_index=1", (b"corrupt",))
        with patch.object(repair_narrations, "normalize_mp3", return_value=b"normalized"):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                repair_narrations.repair_narrations(self.database, apply=True)
        self.assertEqual(self.read()[0], self.book)
        self.assertEqual(list(self.database.parent.glob("*.narration-backup-*")), [])
