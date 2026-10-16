import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from qcam_batch_automator import (
    AutomationError, EXPORT_SETTINGS, QooCamAutomator, adopt_existing_outputs, discover_jobs,
    is_completed, job_report, parse_args, scan_recordings, write_manifest,
)


class BatchInputsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "project" / "camera"
        self.source.mkdir(parents=True)
        self.video = self.source / "Q360_20260902_180032_000002.MP4"
        self.video.write_bytes(b"original")
        self.output = self.source

    def test_recursive_overlapping_inputs_are_deduplicated(self):
        jobs = discover_jobs([self.root, self.source])
        self.assertEqual(jobs, [(self.source, self.output)])

    def test_imports_all_original_mp4_as_separate_items(self):
        renamed = self.source / 'Cooking original.MP4'
        renamed.write_bytes(b'original renamed')
        second = self.source / 'Q360_20260902_180032_000001.MP4'
        second.write_bytes(b'another original segment')
        for name in ('Cooking original_Output.mp4', 'Cooking original_Output(1).mp4',
                     'Cooking original_proxy.mp4', 'Cooking original_reframe.mp4'):
            (self.source / name).write_bytes(b'generated')
        groups = scan_recordings(self.source)
        self.assertEqual({g.representative.name for g in groups},
                         {self.video.name, renamed.name, second.name})
        self.assertTrue(all(len(g.files) == 1 for g in groups))

    def test_discovers_folder_with_only_renamed_original(self):
        other = self.root / 'renamed'
        other.mkdir()
        (other / 'Cooking original.mp4').write_bytes(b'original')
        self.assertIn((other, other),
                      discover_jobs([self.root]))

    def test_direct_mode_ignores_kdoutput_and_nested_videos(self):
        kdoutput = self.source / 'KDOutput'
        kdoutput.mkdir()
        (kdoutput / 'Already rendered.mp4').write_bytes(b'rendered')
        nested = self.source / 'nested'
        nested.mkdir()
        (nested / 'Other original.mp4').write_bytes(b'other')
        self.assertEqual(discover_jobs([self.source], recursive=False),
                         [(self.source, self.source)])
        with self.assertRaises(AutomationError):
            discover_jobs([self.source], kdoutput, recursive=False)
        recursive_sources = [source for source, _ in discover_jobs([self.source])]
        self.assertNotIn(kdoutput, recursive_sources)
        self.assertIn(nested, recursive_sources)

    def test_separate_destinations_for_identical_names(self):
        other = self.root / "another"
        other.mkdir()
        (other / self.video.name).write_bytes(b"original")
        jobs = discover_jobs([self.root])
        self.assertEqual(len(jobs), 2)
        self.assertEqual(len({output for _, output in jobs}), 2)
        with self.assertRaises(AutomationError):
            discover_jobs([self.root], self.root / "shared")

    def test_existing_unverified_is_not_overwritten(self):
        group = scan_recordings(self.source)[0]
        (self.output / group.expected_output_name).write_bytes(b"incomplete")
        self.assertEqual(job_report(self.source, self.output)["groups"][0]["state"],
                         "existing_unverified")
        with self.assertRaises(AutomationError):
            QooCamAutomator(self.source, self.output, lambda _: None, threading.Event())

    def test_completed_requires_same_settings_and_file_size(self):
        group = scan_recordings(self.source)[0]
        result = self.output / group.expected_output_name
        result.write_bytes(b"0" * 1_000_001)
        record = {"sources": group.signature(), "output": result.name,
                  "output_size": result.stat().st_size, "settings": dict(EXPORT_SETTINGS)}
        manifest = {"completed": {group.key: record}}
        write_manifest(self.output, manifest)
        self.assertTrue(is_completed(group, self.output, manifest))
        self.assertEqual(job_report(self.source, self.output)["groups"][0]["state"], "completed")
        record["settings"]["mode"] = "180 3D Reverse"
        self.assertFalse(is_completed(group, self.output, manifest))
        record["settings"] = dict(EXPORT_SETTINGS)
        result.write_bytes(b"truncated")
        self.assertFalse(is_completed(group, self.output, manifest))

    def test_changed_verified_output_is_archivable_not_unverified_conflict(self):
        group = scan_recordings(self.source)[0]
        result = self.output / group.expected_output_name
        result.write_bytes(b"0" * 1_000_001)
        manifest = {"completed": {group.key: {
            "sources": group.signature(), "output": result.name,
            "output_size": result.stat().st_size, "settings": dict(EXPORT_SETTINGS),
        }}}
        write_manifest(self.output, manifest)
        self.video.write_bytes(b"changed original")
        automator = QooCamAutomator(
            self.source, self.output, lambda _: None, threading.Event()
        )
        self.assertEqual(automator.stale_outputs, [scan_recordings(self.source)[0]])

    def test_adopts_only_existing_outputs_that_pass_media_validation(self):
        group = scan_recordings(self.source)[0]
        result = self.output / group.expected_output_name
        result.write_bytes(b"0" * 1_000_001)
        with patch("qcam_batch_automator.validate_existing_render", return_value=True):
            self.assertEqual(adopt_existing_outputs([(self.source, self.output)]), 1)
        self.assertEqual(job_report(self.source, self.output)["groups"][0]["state"], "completed")

    def test_invalid_source_and_repeated_cli_inputs(self):
        with self.assertRaises(AutomationError):
            discover_jobs([self.root / "missing"])
        args = parse_args(["--source", str(self.root), "--source", str(self.source), "--analyze"])
        self.assertEqual(args.source, [self.root, self.source])
        self.assertFalse(args.direct)
        direct = parse_args(["--source", str(self.source), "--direct", "--analyze"])
        self.assertTrue(direct.direct)


if __name__ == "__main__":
    unittest.main()
