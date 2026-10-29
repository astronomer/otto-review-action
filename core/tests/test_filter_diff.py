"""Tests for core/filter-diff.py. Run: python3 -m unittest discover core/tests"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CORE = Path(__file__).resolve().parent.parent
DIFF = (
    "diff --git a/dags/a.py b/dags/a.py\n+a\n"
    "diff --git a/nested/proj/dags/b.py b/nested/proj/dags/b.py\n+b\n"
    "diff --git a/models/m.sql b/models/m.sql\n+m\n"
    "diff --git a/old.tf b/infra/main.tf\nrename from old.tf\nrename to infra/main.tf\n"
    "diff --git a/README.md b/README.md\n+r\n"
)


def run(scope, include="", exclude=""):
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "scope.json"
        proc = subprocess.run(
            [sys.executable, str(CORE / "filter-diff.py"),
             "--scopes", str(CORE / "scopes.json"), "--scope", scope,
             "--include", include, "--exclude", exclude, "--scope-out", str(out)],
            input=DIFF, capture_output=True, text=True,
        )
        info = json.loads(out.read_text()) if out.exists() else None
        return proc, info


class FilterDiffTest(unittest.TestCase):
    def test_entire_repo_keeps_everything(self):
        proc, info = run("entire-repo")
        self.assertEqual(proc.stdout, DIFF)
        self.assertFalse(info["limited"])
        self.assertEqual(info["note"], "")

    def test_just_airflow_matches_nested_projects(self):
        _, info = run("airflow")
        self.assertEqual(info["included"], ["dags/a.py", "nested/proj/dags/b.py"])
        self.assertTrue(info["limited"])

    def test_data_engineer_adds_sql(self):
        _, info = run("data-engineer")
        self.assertIn("models/m.sql", info["included"])
        self.assertIn("dags/a.py", info["included"])
        self.assertNotIn("README.md", info["included"])

    def test_data_platform_engineer_adds_terraform_and_matches_rename_by_either_path(self):
        proc, info = run("data-platform-engineer")
        self.assertEqual(info["included"], ["dags/a.py", "nested/proj/dags/b.py", "infra/main.tf"])
        self.assertIn("rename from old.tf", proc.stdout)

    def test_devops_engineer_excludes_data_and_terraform(self):
        proc, info = run("devops-engineer")
        self.assertEqual(info["included"], [])
        self.assertEqual(proc.stdout, "")

    def test_include_replaces_and_exclude_applies(self):
        _, info = run("entire-repo", include="**/*.py, *.sql", exclude="nested/**")
        self.assertEqual(info["included"], ["dags/a.py", "models/m.sql"])

    def test_nothing_in_scope_yields_empty_diff(self):
        proc, info = run("airflow", include="nothing/**")
        self.assertEqual(proc.stdout, "")
        self.assertEqual(info["included"], [])

    def test_unknown_scope_fails(self):
        proc, _ = run("data-ops")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Unknown review-scope", proc.stderr)


if __name__ == "__main__":
    unittest.main()
