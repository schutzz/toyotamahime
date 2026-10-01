"""Formal K8-3 correction basis regression tests (post-`k8-repro-20261001-001`).

`k8-repro-20261001-001` ran every pre-trigger step correctly and in the frozen
order, but the real wall-clock time between the sensor stage's retained
listening confirmation and T0 was too short: `capture_lifecycle.validate()`
(correctly) rejected it once T0 was known, because nothing in the execution
path *enforced* "listening confirmation <= T0 - 5 s" before T0 was taken.

These tests cover `capture_lifecycle.required_stages_for_run`,
`latest_listening_confirmed_at`, and `ensure_pre_trigger_guard` directly
(unit level, with an injectable fake clock so no test sleeps for 5 real
seconds), plus one subprocess-level integration test against
`study01_sender.py` itself, proving the guard is actually wired into the
sender's execution path and that T0 is still recorded immediately before
invocation -- just no longer able to land too early.

No frozen event, selector, window, scoring rule, or expected result is
touched by this correction; see `study01_sender.py`'s own docstring.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))

from study01 import capture_lifecycle as lc  # noqa: E402
from study01.frozen import apparatus as ap  # noqa: E402


def _iso(dt):
    return dt.isoformat()


def write_lifecycle(root, stage, *, listening_completed_at, listening_ok=True,
                     exit_code=0, malformed_timestamp=False, missing_listening=False):
    """Write a minimal, two-step (start + listening-check) lifecycle record,
    the same shape `study01_capture.py start()` produces before `stop-export`
    has run. Deliberately does not reuse `test_phase1.lifecycle_record` (a
    six-step, fully validate()-able record) so this file exercises exactly
    the partial shape that exists at sender-invocation time.
    """
    spec = ap.ALL_CAPTURE_STAGES[stage]
    interface = spec["interface"] or "eth3"
    steps = [{"step": "start", "argv": ["docker"], "timestamp": _iso(listening_completed_at),
              "completed_at": _iso(listening_completed_at), "exit_code": 0, "output": "abc123"}]
    if not missing_listening:
        output = f"tcpdump: listening on {interface}" if listening_ok else "tcpdump: did not start"
        steps.append({
            "step": "listening-check", "argv": ["docker"],
            "timestamp": _iso(listening_completed_at),
            "completed_at": "not-a-timestamp" if malformed_timestamp else _iso(listening_completed_at),
            "exit_code": exit_code, "output": output,
        })
    record = {
        "schema_version": 1, "run_id": root.name, "execution_run_root": str(root), "stage": stage,
        "helper_name": f"{root.name}-{stage}-capture", "helper_image": ap.CAPTURE_IMAGE,
        "helper_container_id": "abc123", "namespace_service": spec["service"],
        "namespace_container_id": "def456", "interface": interface, "filter": spec["filter"],
        "container_pcap": spec["container_pcap"], "artifact": spec["artifact"],
        "pcap_sha256": None, "steps": steps,
    }
    path = root / spec["lifecycle"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2), encoding="utf-8")
    return path


class FakeClock:
    """now()/sleep() pair sharing one mutable instant, so a guard that sleeps
    actually advances what the next now() call reports -- the same relationship
    production code has with the real wall clock, without a real wait.
    """

    def __init__(self, start):
        self.current = start
        self.sleeps = []

    def now(self):
        return self.current

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.current += timedelta(seconds=seconds)


class RequiredStagesTests(unittest.TestCase):
    def test_range_a_requires_only_ground_truth_and_sensor(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "run"
            root.mkdir()
            write_lifecycle(root, "ground-truth", listening_completed_at=datetime.now(timezone.utc))
            write_lifecycle(root, "sensor", listening_completed_at=datetime.now(timezone.utc))
            self.assertEqual(set(lc.required_stages_for_run(root)), {"ground-truth", "sensor"})

    def test_range_b_additionally_requires_robs05_liveness(self):
        """A stage's own lifecycle record being present is what makes it
        required -- not a guess, and not a separate Range flag."""
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "run"
            root.mkdir()
            now = datetime.now(timezone.utc)
            for stage in ("ground-truth", "sensor", "robs05-liveness"):
                write_lifecycle(root, stage, listening_completed_at=now)
            self.assertEqual(set(lc.required_stages_for_run(root)),
                              {"ground-truth", "sensor", "robs05-liveness"})


class GuardWaitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "run"
        self.root.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_1_waits_when_listening_is_less_than_5s_old(self):
        listening_at = datetime(2026, 1, 1, tzinfo=timezone.utc)
        write_lifecycle(self.root, "ground-truth", listening_completed_at=listening_at)
        write_lifecycle(self.root, "sensor", listening_completed_at=listening_at)
        clock = FakeClock(listening_at + timedelta(seconds=2))  # only 2s old
        lc.ensure_pre_trigger_guard(self.root, ["ground-truth", "sensor"],
                                     now=clock.now, sleep=clock.sleep)
        self.assertEqual(clock.sleeps, [3.0])
        self.assertEqual(clock.current, listening_at + lc.WINDOW_LEAD)

    def test_2_does_not_wait_when_already_5s_or_more_old(self):
        listening_at = datetime(2026, 1, 1, tzinfo=timezone.utc)
        write_lifecycle(self.root, "ground-truth", listening_completed_at=listening_at)
        write_lifecycle(self.root, "sensor", listening_completed_at=listening_at)
        clock = FakeClock(listening_at + timedelta(seconds=6))  # already 6s old
        lc.ensure_pre_trigger_guard(self.root, ["ground-truth", "sensor"],
                                     now=clock.now, sleep=clock.sleep)
        self.assertEqual(clock.sleeps, [])  # no unnecessary wait

    def test_2b_does_not_wait_when_exactly_5s_old(self):
        listening_at = datetime(2026, 1, 1, tzinfo=timezone.utc)
        write_lifecycle(self.root, "ground-truth", listening_completed_at=listening_at)
        write_lifecycle(self.root, "sensor", listening_completed_at=listening_at)
        clock = FakeClock(listening_at + lc.WINDOW_LEAD)
        lc.ensure_pre_trigger_guard(self.root, ["ground-truth", "sensor"],
                                     now=clock.now, sleep=clock.sleep)
        self.assertEqual(clock.sleeps, [])

    def test_3_fails_closed_on_missing_lifecycle_record(self):
        write_lifecycle(self.root, "ground-truth", listening_completed_at=datetime.now(timezone.utc))
        # sensor lifecycle record never written
        with self.assertRaises(lc.CaptureLifecycleError) as cm:
            lc.ensure_pre_trigger_guard(self.root, ["ground-truth", "sensor"])
        self.assertIn("sensor", str(cm.exception))
        self.assertIn("do not trigger", str(cm.exception))

    def test_3b_fails_closed_on_missing_listening_check_step(self):
        write_lifecycle(self.root, "ground-truth", listening_completed_at=datetime.now(timezone.utc))
        write_lifecycle(self.root, "sensor", listening_completed_at=datetime.now(timezone.utc),
                         missing_listening=True)
        with self.assertRaises(lc.CaptureLifecycleError) as cm:
            lc.ensure_pre_trigger_guard(self.root, ["ground-truth", "sensor"])
        self.assertIn("no retained listening-check", str(cm.exception))

    def test_4_fails_closed_on_malformed_timestamp(self):
        write_lifecycle(self.root, "ground-truth", listening_completed_at=datetime.now(timezone.utc))
        write_lifecycle(self.root, "sensor", listening_completed_at=datetime.now(timezone.utc),
                         malformed_timestamp=True)
        with self.assertRaises(lc.CaptureLifecycleError) as cm:
            lc.ensure_pre_trigger_guard(self.root, ["ground-truth", "sensor"])
        self.assertIn("RFC3339", str(cm.exception))

    def test_4b_fails_closed_on_nonzero_listening_check_exit_code(self):
        write_lifecycle(self.root, "ground-truth", listening_completed_at=datetime.now(timezone.utc))
        write_lifecycle(self.root, "sensor", listening_completed_at=datetime.now(timezone.utc), exit_code=1)
        with self.assertRaises(lc.CaptureLifecycleError) as cm:
            lc.ensure_pre_trigger_guard(self.root, ["ground-truth", "sensor"])
        self.assertIn("did not succeed", str(cm.exception))

    def test_4c_fails_closed_on_output_not_confirming_listening(self):
        write_lifecycle(self.root, "ground-truth", listening_completed_at=datetime.now(timezone.utc))
        write_lifecycle(self.root, "sensor", listening_completed_at=datetime.now(timezone.utc),
                         listening_ok=False)
        with self.assertRaises(lc.CaptureLifecycleError) as cm:
            lc.ensure_pre_trigger_guard(self.root, ["ground-truth", "sensor"])
        self.assertIn("does not confirm", str(cm.exception))

    def test_5_range_b_guard_is_gated_by_the_slowest_of_all_three_stages(self):
        """robs05-liveness is consulted, not silently skipped, once its own
        lifecycle record makes it a required stage for this run."""
        base = datetime(2026, 1, 1, tzinfo=timezone.utc)
        write_lifecycle(self.root, "ground-truth", listening_completed_at=base)
        write_lifecycle(self.root, "sensor", listening_completed_at=base)
        # robs05-liveness confirmed listening 2s *later* than the other two.
        robs05_at = base + timedelta(seconds=2)
        write_lifecycle(self.root, "robs05-liveness", listening_completed_at=robs05_at)
        stages = lc.required_stages_for_run(self.root)
        self.assertIn("robs05-liveness", stages)
        clock = FakeClock(robs05_at + timedelta(seconds=1))  # 1s past robs05, 3s past the others
        lc.ensure_pre_trigger_guard(self.root, stages, now=clock.now, sleep=clock.sleep)
        # Gated by robs05-liveness (the slowest), not by ground-truth/sensor.
        self.assertEqual(clock.sleeps, [4.0])
        self.assertEqual(clock.current, robs05_at + lc.WINDOW_LEAD)

    def test_5b_range_b_fails_closed_if_robs05_liveness_not_yet_confirmed(self):
        """If robs05-liveness's own resolve/start already began for this run
        (its lifecycle file exists) but listening is not yet confirmed, the
        guard must not silently treat this run as Range A."""
        now = datetime.now(timezone.utc)
        write_lifecycle(self.root, "ground-truth", listening_completed_at=now)
        write_lifecycle(self.root, "sensor", listening_completed_at=now)
        write_lifecycle(self.root, "robs05-liveness", listening_completed_at=now, missing_listening=True)
        stages = lc.required_stages_for_run(self.root)
        self.assertIn("robs05-liveness", stages)
        with self.assertRaises(lc.CaptureLifecycleError) as cm:
            lc.ensure_pre_trigger_guard(self.root, stages)
        self.assertIn("robs05-liveness", str(cm.exception))


class SenderIntegrationTests(unittest.TestCase):
    """Subprocess-level: proves the guard is actually wired into
    `study01_sender.py`'s execution path, not just available as a library
    function, and that T0 is still recorded immediately before invocation."""

    def test_6_t0_is_recorded_after_the_guard_completes_and_just_before_invocation(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "fresh-run"
            (root / "ground-truth").mkdir(parents=True)
            # Only ~2s old: the real sender execution path must wait ~3s (real
            # time) before it may record T0. Short enough to keep this test fast.
            listening_at = datetime.now(timezone.utc) - timedelta(seconds=2)
            for stage in ("ground-truth", "sensor"):
                write_lifecycle(root, stage, listening_completed_at=listening_at)
            marker = root / "invoked.txt"
            cmd = [sys.executable, str(ROOT / "study01_sender.py"), "--run-id", "fresh-run",
                   "--run-evidence", str(root), "--",
                   sys.executable, "-c", f"import pathlib; pathlib.Path(r'{marker}').write_text('x')"]
            before = datetime.now(timezone.utc)
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            after = datetime.now(timezone.utc)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.is_file(), "sender did not invoke the command")
            t0 = datetime.fromisoformat((root / ap.T0_ARTIFACT).read_text().strip())
            # Structural guarantee under test: T0 - 5s cannot land before the
            # retained listening confirmation.
            self.assertGreaterEqual(t0, listening_at + lc.WINDOW_LEAD - timedelta(milliseconds=50))
            # T0 was recorded within this process's own wall-clock window, i.e.
            # immediately before invocation -- not before the guard ran.
            self.assertGreaterEqual(t0, before)
            self.assertLessEqual(t0, after)
            # The wait was real: the whole call took close to the ~3s owed.
            self.assertGreaterEqual((after - before).total_seconds(), 2.5)

    def test_6b_already_old_enough_listening_does_not_delay_t0(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "fresh-run"
            (root / "ground-truth").mkdir(parents=True)
            listening_at = datetime.now(timezone.utc) - timedelta(seconds=30)
            for stage in ("ground-truth", "sensor"):
                write_lifecycle(root, stage, listening_completed_at=listening_at)
            cmd = [sys.executable, str(ROOT / "study01_sender.py"), "--run-id", "fresh-run",
                   "--run-evidence", str(root), "--", sys.executable, "-c", "print('sent')"]
            before = datetime.now(timezone.utc)
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            after = datetime.now(timezone.utc)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertLessEqual((after - before).total_seconds(), 2.0)

    def test_6c_sender_fails_closed_without_capture_lifecycle_fixtures(self):
        """A run_evidence directory with no capture-lifecycle records at all
        (the old test fixture shape) must now refuse to invoke the sender."""
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "fresh-run"
            (root / "ground-truth").mkdir(parents=True)
            marker = root / "invoked.txt"
            cmd = [sys.executable, str(ROOT / "study01_sender.py"), "--run-id", "fresh-run",
                   "--run-evidence", str(root), "--",
                   sys.executable, "-c", f"import pathlib; pathlib.Path(r'{marker}').write_text('x')"]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("do not trigger", result.stderr)
            self.assertFalse(marker.is_file(), "sender must not invoke the command when fail-closed")
            self.assertFalse((root / ap.T0_ARTIFACT).is_file(), "T0 must not be recorded when fail-closed")


if __name__ == "__main__":
    unittest.main()
