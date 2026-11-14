import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("pipeline", Path(__file__).with_name("pipeline.py"))
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg is required")
class NarrationMP3Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        root = Path(cls.folder.name)
        cls.audio = b""
        for index, duration in enumerate((.4, .8)):
            path = root / (str(index) + ".mp3")
            pipeline.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=24000:duration=" + str(duration), str(path)])
            cls.audio += path.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def test_concatenated_mp3_gets_full_duration_without_changing_decoded_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "original.mp3"
            original.write_bytes(self.audio)
            normalized = pipeline.normalize_mp3(root, self.audio)
            result = json.loads(pipeline.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(root / "audio.mp3")]).stdout)
            duration = float(result["format"]["duration"])
            self.assertGreater(duration, 1.2)
            self.assertLess(duration, 1.5)
            decoded = lambda path: pipeline.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "hash", "-hash", "sha256", "-"]).stdout
            self.assertEqual(decoded(original), decoded(root / "audio.mp3"))
            self.assertEqual(normalized, pipeline.normalize_mp3(root, normalized))
            self.assertFalse((root / "audio-source.mp3").exists())
            if shutil.which("afinfo"):
                import re
                original_duration = float(re.search(r"estimated duration:\s*([\d.]+)", pipeline.run(["afinfo", str(original)]).stdout.decode()).group(1))
                apple_duration = float(re.search(r"estimated duration:\s*([\d.]+)", pipeline.run(["afinfo", str(root / "audio.mp3")]).stdout.decode()).group(1))
                self.assertLess(original_duration, 1)
                self.assertAlmostEqual(apple_duration, duration, delta=.05)

    def test_completed_checkpoint_is_repaired_without_provider_or_alignment_calls(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(pipeline, "api", side_effect=AssertionError("Unexpected synthesis")):
            root = Path(folder)
            data = {"provider": "openrouter", "text": "Hello world"}
            pipeline.save(root / "narration-input.json", data)
            digest = pipeline.hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
            checkpoint = root / ("audio-" + digest + ".mp3")
            checkpoint.write_bytes(self.audio)
            alignment = {"provider": "openrouter", "model": "kokoro", "voice": "af_heart", "words": [{"text": "Hello", "start": 0, "end": .3, "offset": 0, "length": 5}]}
            pipeline.save(root / ("timing-" + digest + ".json"), alignment)
            pipeline.narrate(root)
            self.assertNotEqual(checkpoint.read_bytes(), self.audio)
            self.assertEqual(checkpoint.read_bytes(), (root / "audio.mp3").read_bytes())
            self.assertEqual(json.loads((root / "alignment.json").read_text()), alignment)

    def test_openrouter_normalizes_audio_before_word_alignment_and_caches_it(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"OPENROUTER_API_KEY": "test"}):
            root = Path(folder)
            pipeline.save(root / "narration-input.json", {"provider": "openrouter", "text": "Hello world"})
            def transcribe(path, **kwargs):
                self.assertNotEqual(Path(path).read_bytes(), self.audio)
                words = [SimpleNamespace(word="Hello", start=0, end=.3), SimpleNamespace(word="world", start=.4, end=1.1)]
                return iter([SimpleNamespace(words=words)]), None
            model = SimpleNamespace(transcribe=transcribe)
            module = SimpleNamespace(WhisperModel=lambda *args, **kwargs: model)
            with patch.dict(sys.modules, {"faster_whisper": module}), patch.object(pipeline, "api", return_value=self.audio) as api:
                pipeline.narrate(root)
            api.assert_called_once()
            self.assertEqual(next(root.glob("audio-*.mp3")).read_bytes(), (root / "audio.mp3").read_bytes())
            self.assertEqual(len(json.loads((root / "alignment.json").read_text())["words"]), 2)

    def test_elevenlabs_audio_is_normalized_without_changing_provider_timings(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"ELEVENLABS_API_KEY": "test"}):
            root = Path(folder)
            pipeline.save(root / "narration-input.json", {"provider": "elevenlabs", "text": "Hi"})
            response = {"audio_base64": pipeline.base64.b64encode(self.audio).decode(), "alignment": {
                "characters": ["H", "i"], "character_start_times_seconds": [.1, .2], "character_end_times_seconds": [.2, .3]}}
            with patch.object(pipeline, "api", return_value=json.dumps(response).encode()):
                pipeline.narrate(root)
            self.assertNotEqual((root / "audio.mp3").read_bytes(), self.audio)
            self.assertEqual(json.loads((root / "alignment.json").read_text())["words"], [
                {"text": "Hi", "start": .1, "end": .3, "offset": 0, "length": 2}])


class PipelineTests(unittest.TestCase):
    def test_mp3_finalization_failure_is_actionable_and_removes_temporary_input(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(pipeline, "run", side_effect=subprocess.CalledProcessError(1, "ffmpeg", stderr=b"private text")):
            root = Path(folder)
            with self.assertRaisesRegex(ValueError, "MP3 timing could not be finalized") as failure:
                pipeline.normalize_mp3(root, b"invalid audio")
            self.assertNotIn("private text", str(failure.exception))
            self.assertFalse((root / "audio-source.mp3").exists())

    def test_summary_length_changes_prompt_and_provenance(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            pipeline.save(root / "extraction.json", {"pages": [{"page": 1, "text": "Source text. " * 30}], "ocrPages": [], "sparsePages": [], "sha256": "source-hash"})
            prompts = {}
            def fake_codex(root, name, prompt, schema):
                prompts[name] = prompt
                if name.startswith("notes"):
                    return {"title": "Source", "author": "Author", "language": "en", "notes": [{"page": 1, "idea": "Idea"}]}
                return {"title": "Source", "author": "Author", "language": "en", "subtitle": "", "category": "General", "synopsis": "Independent summary.", "sections": [{"title": "Idea", "body": "Summary body.", "sourcePage": 1}]}
            with patch.object(pipeline, "codex", side_effect=fake_codex):
                pipeline.summarize(root)
                self.assertIn("10-minute summary", prompts["summary"])
                pipeline.save(root / "summary-options.json", {"minutes": 30})
                pipeline.summarize(root)
            self.assertIn("30-minute summary", prompts["summary"])
            self.assertIn("5,200–6,500 words", prompts["summary"])
            self.assertEqual(json.loads((root / "result.json").read_text())["provenance"]["targetMinutes"], 30)

    def test_chunk_relative_note_references_use_original_source_indices(self):
        pages = [{"page": 13}, {"page": 14}, {"page": 15}]
        notes = [{"page": 1, "idea": "A"}, {"page": 3, "idea": "B"}]
        self.assertEqual([n["page"] for n in pipeline.normalize_note_pages(notes, pages)], [13, 15])
        absolute = [{"page": 13, "idea": "A"}]
        self.assertEqual(pipeline.normalize_note_pages(absolute, pages), absolute)
        with self.assertRaisesRegex(ValueError, "outside this chunk"):
            pipeline.normalize_note_pages([{"page": 99, "idea": "A"}], pages)

    def test_epub_spine_extracts_readable_chapters_without_pdf_links(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with zipfile.ZipFile(root / "source.epub", "w") as archive:
                archive.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>')
                archive.writestr("OEBPS/content.opf", '<package><metadata><title>Example book</title><creator>Test Author</creator></metadata><manifest><item id="a" href="first.xhtml" media-type="application/xhtml+xml"/><item id="b" href="second.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="b"/><itemref idref="a"/></spine></package>')
                archive.writestr("OEBPS/first.xhtml", "<html><body><h1>First</h1><p>First chapter text. " + "A sentence. " * 30 + "</p></body></html>")
                archive.writestr("OEBPS/second.xhtml", "<html><body><h1>Second</h1><script>ignore me</script><p>Second chapter text. " + "A sentence. " * 30 + "</p></body></html>")
            pipeline.extract(root)
            extraction = json.loads((root / "extraction.json").read_text())
            self.assertEqual(extraction["kind"], "epub")
            self.assertEqual([p["title"] for p in extraction["pages"]], ["Second", "First"])
            self.assertNotIn("ignore me", extraction["pages"][0]["text"])
            def fake_codex(root, name, prompt, schema):
                if name.startswith("notes"):
                    return {"title": "Example book", "author": "Test Author", "language": "en", "notes": [{"page": 1, "idea": "Example"}]}
                return {"title": "Example book", "author": "Test Author", "language": "en", "subtitle": "", "category": "General", "synopsis": "Independent summary.", "sections": [{"title": "Idea", "body": "Summary text.", "sourcePage": 1}]}
            with patch.object(pipeline, "codex", side_effect=fake_codex): pipeline.summarize(root)
            book = json.loads((root / "result.json").read_text())["book"]
            self.assertNotIn("sourcePage", book["sections"][0])
            self.assertNotIn("sourcePage", book["chapters"][0])

    def test_codex_receives_schema_and_no_narration_credentials(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def fake_run(args, **kwargs):
                self.assertIn("read-only", args)
                self.assertIn("shell_tool", args)
                self.assertIn("--ignore-user-config", args)
                self.assertNotIn("ELEVENLABS_API_KEY", kwargs["env"])
                self.assertNotIn("OPENROUTER_API_KEY", kwargs["env"])
                self.assertNotIn("LIBRARY_TOKEN", kwargs["env"])
                Path(args[args.index("-o")+1]).write_text('{"notes": []}')
            with patch.dict(os.environ, {"ELEVENLABS_API_KEY": "test-eleven", "OPENROUTER_API_KEY": "test-router", "LIBRARY_TOKEN": "test-library"}), patch.object(pipeline, "run", side_effect=fake_run) as run:
                self.assertEqual(pipeline.codex(root, "notes", "untrusted PDF text", pipeline.NOTES_SCHEMA), {"notes": []})
                pipeline.codex(root, "notes", "untrusted PDF text", pipeline.NOTES_SCHEMA)
                self.assertEqual(run.call_count, 1, "completed chunk should be reused")

    def test_utf16_word_offsets_preserve_non_ascii_text(self):
        text = "🧠 Here’s an idea."
        match = list(pipeline.re.finditer(r"\S+", text))[1]
        word = pipeline.word(text, match, .1, .5)
        self.assertEqual(word["offset"], 3)
        self.assertEqual(word["length"], 6)
        self.assertEqual(word["text"], "Here’s")

    def test_missing_provider_key_fails_before_network_generation(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {}, clear=True):
            root = Path(folder)
            (root / "narration-input.json").write_text(json.dumps({"provider": "openrouter", "text": "A test"}))
            with self.assertRaisesRegex(ValueError, "not configured"):
                pipeline.narrate(root)

    def test_summary_covers_every_page_and_preserves_original_text(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            pages = [{"page": 1, "text": "First page. " * 2000}, {"page": 2, "text": "Last page. " * 2000}]
            pipeline.save(root / "extraction.json", {"pages": pages, "ocrPages": [], "sparsePages": [], "sha256": "source-hash"})
            seen = []
            def fake_codex(root, name, prompt, schema):
                seen.append(name)
                if name.startswith("notes"):
                    page = 1 if name == "notes-000" else 2
                    return {"title": "Test source", "author": "Test author", "language": "en", "notes": [{"page": page, "idea": "An original idea"}]}
                return {"title": "Test source", "author": "Test author", "language": "en", "subtitle": "Test", "category": "General", "synopsis": "Independent summary.", "sections": [{"title": "The idea", "body": "An original short summary.", "sourcePage": 2}]}
            with patch.object(pipeline, "codex", side_effect=fake_codex):
                pipeline.summarize(root)
            result = json.loads((root / "result.json").read_text())
            self.assertEqual(seen, ["notes-000", "notes-001", "summary"])
            self.assertEqual([c["body"] for c in result["book"]["chapters"]], [p["text"] for p in pages])
            self.assertEqual(result["provenance"]["coverage"], [{"startPage": 1, "endPage": 1}, {"startPage": 2, "endPage": 2}])


if __name__ == "__main__":
    unittest.main()
