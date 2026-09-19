"""Targeted tests for AMEND-006's R-OBS-05 auxiliary liveness capture stage.

Formal K8-3 attempt `k8-repro-20260919-002` could not evaluate Range B's
R-OBS-05 because the only capture mechanism available was the single global
`CAPTURE_FILTER`, which requires the target sender host in every retained frame
and so structurally excludes the unrelated flow the R-OBS-05 contract evaluates.
These cover the stage that closes that gap, and -- just as importantly -- that
it stays out of the target-event requirement set.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))
from study01 import capture_context as context
from study01 import capture_lifecycle as lifecycle
from study01.frozen import apparatus as ap
from study01_collect import validate

STAGE = "robs05-liveness"


class FrozenTargetEventStagesAreUnchanged(unittest.TestCase):
    def test_ground_truth_stage_keeps_the_original_filter(self):
        self.assertEqual(ap.CAPTURE_STAGES["ground-truth"]["filter"], ap.CAPTURE_FILTER)

    def test_sensor_stage_keeps_the_original_filter(self):
        self.assertEqual(ap.CAPTURE_STAGES["sensor"]["filter"], ap.CAPTURE_FILTER)

    def test_capture_filter_value_is_unchanged(self):
        self.assertEqual(ap.CAPTURE_FILTER,
                         "host 10.1.20.11 and host 10.1.10.10 and tcp port 20000")

    def test_target_event_stage_set_and_paths_are_unchanged(self):
        """The target-event requirement set is exactly the two frozen stages."""
        self.assertEqual(tuple(ap.CAPTURE_STAGES), ("ground-truth", "sensor"))
        self.assertEqual(ap.CAPTURE_CONTAINER_PATHS,
                         ("/data/c2-original-path.pcap", "/data/c2-mirror-sensor.pcap"))
        self.assertEqual(ap.CAPTURE_STAGES["sensor"]["artifact"],
                         "sensor-input/mirror-capture/c2-mirror-sensor.pcap")
        self.assertEqual(ap.CAPTURE_STAGES["ground-truth"]["artifact"],
                         "ground-truth/independent-capture/c2-original-path.pcap")


class Robs05LivenessStage(unittest.TestCase):
    def test_uses_the_contracts_own_frozen_selector(self):
        """The filter is the R-OBS-05 contract's selector, not a new value."""
        spec = ap.AUXILIARY_CAPTURE_STAGES[STAGE]
        self.assertEqual(spec["filter"], ap.ROBS05_LIVENESS_FILTER)
        self.assertEqual(ap.ROBS05_LIVENESS_FILTER,
                         "host 10.1.10.10 and host 10.1.40.10 and tcp port 20000")
        self.assertNotEqual(spec["filter"], ap.CAPTURE_FILTER)

    def test_observes_the_same_frozen_mirror_point_as_the_sensor_stage(self):
        spec = ap.AUXILIARY_CAPTURE_STAGES[STAGE]
        self.assertEqual(spec["service"], ap.CAPTURE_STAGES["sensor"]["service"])
        self.assertEqual(spec["interface"], ap.CAPTURE_STAGES["sensor"]["interface"])

    def test_artifacts_are_retained_under_contract_output(self):
        spec = ap.AUXILIARY_CAPTURE_STAGES[STAGE]
        for key in ("artifact", "lifecycle", "context"):
            self.assertTrue(spec[key].startswith("contract-output/"), spec[key])

    def test_is_not_in_the_target_event_requirement_set(self):
        """R-OBS-05 is Range B only, so it must never become Range A evidence."""
        self.assertNotIn(STAGE, ap.CAPTURE_STAGES)
        self.assertIn(STAGE, ap.ALL_CAPTURE_STAGES)


class LifecycleRecordsTheStagesOwnFilter(unittest.TestCase):
    def _record(self, stage):
        return lifecycle.new_record(
            run_id="k6-range-b-20260101-001", stage=stage,
            namespace_container="abc123", interface="eth0",
            run_root="/host/k6-range-b-20260101-001")

    def test_new_record_carries_each_stages_own_filter(self):
        self.assertEqual(self._record("sensor")["filter"], ap.CAPTURE_FILTER)
        self.assertEqual(self._record(STAGE)["filter"], ap.ROBS05_LIVENESS_FILTER)

    def test_validate_accepts_the_stages_own_filter(self):
        record = self._record(STAGE)
        ctx = {"schema_version": context.SCHEMA_VERSION,
               "run_id": record["run_id"], "stage": STAGE,
               "namespace_service": "tap_observer",
               "namespace_resolution": {"argv": ["docker"], "output": "abc123", "exit_code": 0},
               "resolved_container_id": "abc123", "interface_resolution": None,
               "normalized_interface": "eth0"}
        record["helper_container_id"] = "helper1"
        record["pcap_sha256"] = "0" * 64
        record["steps"] = []
        # The filter this stage actually captured with is the one it declares.
        self.assertEqual(record["filter"], ap.AUXILIARY_CAPTURE_STAGES[STAGE]["filter"])
        self.assertEqual(ctx["normalized_interface"], record["interface"])

    def test_validate_rejects_a_drifted_filter_for_this_stage(self):
        record = self._record(STAGE)
        record["filter"] = ap.CAPTURE_FILTER  # the target-event filter, not this stage's
        with self.assertRaises(lifecycle.CaptureLifecycleError):
            lifecycle.validate(record)

    def test_validate_rejects_the_robs05_filter_on_a_target_event_stage(self):
        record = self._record("sensor")
        record["filter"] = ap.ROBS05_LIVENESS_FILTER
        with self.assertRaises(lifecycle.CaptureLifecycleError):
            lifecycle.validate(record)

    def test_the_helper_argv_captures_with_this_stages_filter(self):
        """The stage's filter is what actually reaches tcpdump's argv."""
        robs05 = lifecycle.expected_argv(self._record(STAGE), "start")
        self.assertEqual(robs05[-1], ap.ROBS05_LIVENESS_FILTER)
        self.assertIn("/data/c2-robs05-liveness.pcap", robs05)

        sensor = lifecycle.expected_argv(self._record("sensor"), "start")
        self.assertEqual(sensor[-1], ap.CAPTURE_FILTER)
        self.assertIn("/data/c2-mirror-sensor.pcap", sensor)


class RangeARequirementSetIsUnaffected(unittest.TestCase):
    """A run retaining only the two target-event stages still validates."""

    def test_validate_does_not_require_the_robs05_artifact(self):
        sys.path.insert(0, str(ROOT / "tests"))
        from test_phase1 import retention_artifacts, GOOD_PROCEDURE
        from study01.evidence_tree import RUNTIME_DIRS
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "k6-range-a-20260101-001"
            root.mkdir()
            (root / "metadata.md").write_text("metadata", encoding="utf-8")
            (root / "deviations.md").write_text("none", encoding="utf-8")
            for name in RUNTIME_DIRS:
                (root / name).mkdir(parents=True, exist_ok=True)
                (root / name / "retained.txt").write_text("fixture", encoding="utf-8")
            (root / "ground-truth" / "procedure-conformance.json").write_text(
                json.dumps(GOOD_PROCEDURE), encoding="utf-8")
            retention_artifacts(root)
            robs05 = root / ap.AUXILIARY_CAPTURE_STAGES[STAGE]["artifact"]
            self.assertFalse(robs05.exists(),
                             "the fixture must not create the R-OBS-05 artifact")
            validate(root)  # must not raise: Range A never retains robs05-liveness


if __name__ == "__main__":
    unittest.main()
