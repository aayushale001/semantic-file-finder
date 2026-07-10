from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER_DIR = REPO_ROOT / "helper"
sys.path.insert(0, str(HELPER_DIR))

import main  # noqa: E402
import scanner  # noqa: E402


class ScannerContainmentTests(unittest.TestCase):
    def test_scan_folder_skips_file_symlinks_that_can_escape_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            root = base / "selected"
            root.mkdir()
            outside = base / "outside_secret.txt"
            outside.write_text("outside secret", encoding="utf-8")
            inside = root / "normal.txt"
            inside.write_text("normal content", encoding="utf-8")
            os.symlink(outside, root / "looks_inside.txt")

            files = scanner.scan_folder(str(root))
            names = {f.file_name for f in files}
            paths = {Path(f.file_path).resolve() for f in files}

            self.assertIn("normal.txt", names)
            self.assertNotIn("looks_inside.txt", names)
            self.assertNotIn(outside.resolve(), paths)


class IndexBudgetTests(unittest.TestCase):
    def _patch_vector_store(self):
        return (
            mock.patch.object(main.config, "ensure_dirs"),
            mock.patch.object(main.vector_store, "check_index_compatibility"),
            mock.patch.object(main.vector_store, "ensure_index_metadata"),
            mock.patch.object(main.vector_store, "delete_file"),
            mock.patch.object(main.vector_store, "add_chunks"),
        )

    def test_oversized_text_file_is_skipped_before_extracting_or_embedding(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            large = Path(tmp) / "large.txt"
            large.write_text("x" * 64, encoding="utf-8")

            patches = self._patch_vector_store()
            with (
                patches[0],
                patches[1],
                patches[2],
                patches[3] as delete_file,
                patches[4] as add_chunks,
                mock.patch.object(main.config, "MAX_TEXT_FILE_BYTES", 10),
                mock.patch.object(main, "extract_file") as extract_file,
                mock.patch.object(main.embeddings, "embed_batch") as embed_batch,
            ):
                summary = main.run_index(tmp, force=True)

            self.assertEqual(summary["indexed_files"], 0)
            self.assertEqual(summary["skipped_files"], 1)
            self.assertTrue(any(err.startswith("budget:large.txt:") for err in summary["errors"]))
            extract_file.assert_not_called()
            embed_batch.assert_not_called()
            delete_file.assert_not_called()
            add_chunks.assert_not_called()

    def test_small_text_file_still_indexes_normally(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            small = Path(tmp) / "small.txt"
            small.write_text("hello launch day", encoding="utf-8")

            def fake_embed(texts, task_type=None):
                return [[0.0, 1.0, 0.0] for _ in texts]

            patches = self._patch_vector_store()
            with (
                patches[0],
                patches[1],
                patches[2],
                patches[3] as delete_file,
                patches[4] as add_chunks,
                mock.patch.object(main.config, "MAX_TEXT_FILE_BYTES", 1024),
                mock.patch.object(main.config, "MAX_EXTRACTED_CHARS_PER_FILE", 1024),
                mock.patch.object(main.config, "MAX_CHUNKS_PER_FILE", 10),
                mock.patch.object(main.embeddings, "embed_batch", side_effect=fake_embed),
            ):
                summary = main.run_index(tmp, force=True)

            self.assertEqual(summary["indexed_files"], 1)
            self.assertEqual(summary["skipped_files"], 0)
            self.assertEqual(summary["indexed_chunks"], 1)
            self.assertEqual(summary["errors"], [])
            delete_file.assert_called_once()
            add_chunks.assert_called_once()


if __name__ == "__main__":
    unittest.main()
