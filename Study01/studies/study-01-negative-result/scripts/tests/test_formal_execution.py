import importlib.util
import json
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path


SCRIPTS = Path(__file__).parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


formal = load("study01_formal_actions", SCRIPTS / "study01_formal_actions.py")
packager = load("k8_rangec_formal_package", Path(__file__).parents[5] / "shakedown" / "tools" / "k8_rangec_formal_package.py")


class FormalExecutionTests(unittest.TestCase):
    def test_log_structurer_canary_error_is_fail_closed(self):
        self.assertFalse(formal.log_structurer_ready(True, True, 3, "target selector matched"))
        self.assertTrue(formal.log_structurer_ready(True, True, 3, None))

    def procedure(self, root):
        p = root / "ground-truth" / "procedure-conformance.json"
        p.parent.mkdir(parents=True)
        value = {"schema_version": 2, "invocation_count": 1, "same_run_retry": False,
                 "procedure_invalid": False, "invalid_reasons": [],
                 "sender_invocations": [{"timestamp": "2026-01-01T00:00:00+00:00", "exit_code": 0}]}
        p.write_text(json.dumps(value), encoding="utf-8")
        return value

    def test_scoring_template_keeps_semantic_fields_unfilled(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); output = root / "scoring-input.json"
            formal.scoring_template(Namespace(run_evidence=root, range="B", output=output))
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["runtime_contract"], "<FILL-IN>")
            self.assertEqual(value["r_obs_05"], "<FILL-IN>")
            self.assertEqual(value["procedure_conformance"], "<COPY ground-truth/procedure-conformance.json HERE>")

    def test_shape_validation_rejects_unfilled_semantic_values(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); self.procedure(root); output = root / "scoring-input.json"
            formal.scoring_template(Namespace(run_evidence=root, range="A", output=output))
            with self.assertRaises(RuntimeError):
                formal.validate_scoring(Namespace(run_evidence=root, range="A", input=output,
                    finalize_snapshot=root/"finalize.json", validation_report=None))

    def test_shape_validation_rejects_banana_values(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); output=root/"scoring-input.json"
            formal.scoring_template(Namespace(run_evidence=root,range="A",output=output))
            value=json.loads(output.read_text(encoding="utf-8"))
            for key in ("rule_output","runtime_contract","evidence_correlatable"): value[key]="BANANA"
            for key in value["stages"]: value["stages"][key]="BANANA"
            output.write_text(json.dumps(value),encoding="utf-8")
            with self.assertRaises(RuntimeError):
                formal.validate_scoring(Namespace(run_evidence=root,range="A",input=output,
                    finalize_snapshot=root/"finalize.json",validation_report=None))

    def test_range_c_default_still_refuses_canonical_formal_path(self):
        with tempfile.TemporaryDirectory() as d:
            destination = Path(d) / "evidence" / "static-validations" / "range-c" / "x"
            with self.assertRaises(packager.PackagingError):
                packager.assert_not_canonical_evidence_path(destination)

    def test_range_c_formal_binding_is_explicit_and_default_is_none(self):
        import inspect
        self.assertIsNone(inspect.signature(packager.build).parameters["formal_attempt_dir"].default)

    def test_range_c_formal_binding_requires_a_real_current_attempt(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            with self.assertRaisesRegex(packager.PackagingError, "missing attempt.json"):
                packager.build(root / "run-evidence", root / "run-records",
                               root / "evidence" / "static-validations" / "range-c" / "v",
                               "v", root / "range-c-human" / "v",
                               formal_attempt_dir=root)


if __name__ == "__main__": unittest.main()
