"""Targeted regression for the evidence-tree exposure defect.

Formal K8-3 attempt k8-repro-20260918-001 was stopped at 12/13 by the
execution preflight gate: `evidence_tree.create()` builds eight directories
and the gate requires all eight, but no published command created them and
the schema document's tree diagram showed only six, so the operator built
six by hand. These cover the gap itself -- one definition, reachable from a
published command, and named in the documents an operator actually reads.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))
from study01 import preflight
from study01.evidence_tree import NESTED_EXPORT_DIRS, RUNTIME_DIRS, create

STUDY_ROOT = ROOT.parent
CLI = ROOT / "study01_evidence_tree.py"


class EvidenceTreeCli(unittest.TestCase):
    def test_cli_creates_exactly_what_the_gate_requires(self):
        """The wrapper and the gate must never be able to disagree."""
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "k8-3-range-a-001"
            result = subprocess.run(
                (sys.executable, str(CLI), "--run-evidence", str(root)),
                capture_output=True, text=True, cwd=str(ROOT))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(preflight.evidence_tree(root).ok,
                            preflight.evidence_tree(root).detail)
            created = sorted(p.relative_to(root).as_posix()
                             for p in root.rglob("*") if p.is_dir())
            self.assertEqual(created, sorted(RUNTIME_DIRS + NESTED_EXPORT_DIRS))

    def test_cli_refuses_an_existing_tree(self):
        """Reusing a run ID's tree is refused here, not only at the gate."""
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "k8-3-range-a-001"
            create(root)
            result = subprocess.run(
                (sys.executable, str(CLI), "--run-evidence", str(root)),
                capture_output=True, text=True, cwd=str(ROOT))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fresh run ID", result.stderr)


class PublishedProcedureNamesEveryRequiredDirectory(unittest.TestCase):
    """The defect was documentation exposure, so the documents are the test."""

    def _read(self, relative):
        return (STUDY_ROOT / relative).read_text(encoding="utf-8")

    def test_schema_diagram_names_the_nested_capture_export_destinations(self):
        schema = self._read("protocol/evidence-schema.md")
        for name in NESTED_EXPORT_DIRS:
            self.assertIn(name.split("/")[-1] + "/", schema,
                          f"evidence-schema.md does not show {name}")

    def test_derivation_procedure_gives_a_literal_tree_creation_command(self):
        derivation = self._read("protocol/c2-dnp3-range-derivation.md")
        self.assertIn("study01_evidence_tree.py", derivation)
        for name in RUNTIME_DIRS + NESTED_EXPORT_DIRS:
            self.assertIn(name, derivation,
                          f"c2-dnp3-range-derivation.md does not name {name}")


if __name__ == "__main__":
    unittest.main()
