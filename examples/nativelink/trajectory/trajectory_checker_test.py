"""Checks for the fixture's geometry and the adapter's error handling."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import trajectory_checker


class TrajectoryCheckerTest(unittest.TestCase):
    def setUp(self):
        self.scene = Path(__file__).with_name("scenario.usda").read_text(encoding="utf-8")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.source = Path(self.temporary.name) / "scene.usda"
        self.report = Path(self.temporary.name) / "report.json"

    def run_checker(self, scene):
        self.source.write_text(scene, encoding="utf-8")
        arguments = [
            "trajectory_checker",
            "--operation", "validate",
            "--input", str(self.source),
            "--report", str(self.report),
        ]
        errors = io.StringIO()
        with patch("sys.argv", arguments), contextlib.redirect_stderr(errors):
            result = trajectory_checker.main()
        return result, errors.getvalue()

    def test_original_report_and_repeated_bytes(self):
        self.assertEqual(self.run_checker(self.scene), (0, ""))
        original_report = self.report.read_bytes()
        self.assertEqual(json.loads(original_report), {
            "collision_indices": [],
            "obstacle_radius": 0.25,
            "valid": True,
            "waypoint_count": 3,
        })
        self.assertEqual(self.run_checker(self.scene), (0, ""))
        self.assertEqual(self.report.read_bytes(), original_report)

    def test_changed_waypoint_reports_collision(self):
        changed = self.scene.replace(
            "waypointY = [0.0, 0.0, 0.0]", "waypointY = [1.0, 1.0, 1.0]"
        )
        self.assertEqual(self.run_checker(changed), (0, ""))
        report = json.loads(self.report.read_text(encoding="utf-8"))
        self.assertEqual(report["collision_indices"], [1])
        self.assertFalse(report["valid"])

    def test_touching_obstacle_counts_as_collision(self):
        touching = self.scene.replace("obstacleY = 1.0", "obstacleY = 0.25")
        self.assertEqual(self.run_checker(touching), (0, ""))
        report = json.loads(self.report.read_text(encoding="utf-8"))
        self.assertEqual(report["collision_indices"], [1])
        self.assertFalse(report["valid"])

    def test_malformed_geometry_fails_without_report(self):
        replacements = [
            ("#usda 1.0", "#unknown"),
            ("waypointY = [0.0, 0.0, 0.0]", "waypointY = [0.0]"),
            ("waypointY = [0.0, 0.0, 0.0]", "waypointY = []"),
            ("obstacleRadius = 0.25", "obstacleRadius = -0.25"),
            ("waypointX = [0.0, 1.0, 2.0]", "waypointX = [nan, 1.0, 2.0]"),
            ("obstacleRadius = 0.25", "obstacleRadius = 1e309"),
        ]
        for old, new in replacements:
            with self.subTest(value=new):
                result, errors = self.run_checker(self.scene.replace(old, new))
                self.assertEqual(result, 2)
                self.assertIn("trajectory checker:", errors)
                self.assertFalse(self.report.exists())


if __name__ == "__main__":
    unittest.main()
