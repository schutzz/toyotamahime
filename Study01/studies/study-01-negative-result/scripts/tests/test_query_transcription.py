"""Targeted regression for the Collector/Rule query executable-transcription gap.

Formal K8-3 attempt k8-repro-20260929-001 found that freeze-decision-table.md
§3 and evidence-schema.md §3 fixed the frozen Collector/Rule selectors and
index patterns, but no document published a literal, executable query -- the
apparatus published nothing an operator could run without synthesizing one
from outside knowledge. These tests cover the gap itself: a formal query
mechanism must exist, must be reachable from a published command, and its
frozen request bodies must actually carry the selectors freeze-decision-table.md
§3 fixes -- so a future release cannot again say "retain the Collector/Rule
query" without exposing the executable means to do so.
"""
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))
from study01.frozen import apparatus

STUDY_ROOT = ROOT.parent  # studies/study-01-negative-result/
STUDY01_ROOT = STUDY_ROOT.parents[1]  # Study01/, where README.md lives
CLI = ROOT / "study01_query.py"


class FrozenQueryTemplatesMatchTheFrozenSelectors(unittest.TestCase):
    """freeze-decision-table.md §3 is the sole source of these values."""

    def test_collector_template_carries_every_frozen_selector_field(self):
        text = apparatus.COLLECTOR_QUERY_TEMPLATE.read_text(encoding="utf-8")
        for needle in (
            '"layers.ip.ip_ip_src.keyword": "10.1.20.11"',
            '"layers.ip.ip_ip_dst.keyword": "10.1.10.10"',
            '"layers.tcp.tcp_tcp_dstport.keyword": "20000"',
            '"layers.dnp3.dnp3_dnp3_al_func.keyword": "5"',
            '"layers.dnp3.dnp3_dnp3_src.keyword": "1024"',
            '"layers.dnp3.dnp3_dnp3_dst.keyword": "1"',
            "layers.frame.frame_frame_time",
            "<WINDOW_START>",
            "<WINDOW_END>",
        ):
            self.assertIn(needle, text, f"collector-query.template.json is missing frozen selector element: {needle}")

    def test_rule_template_carries_every_frozen_selector_field(self):
        text = apparatus.RULE_QUERY_TEMPLATE.read_text(encoding="utf-8")
        for needle in (
            '"signal.keyword": "signal-1-zone-violation"',
            '"src_ip.keyword": "10.1.20.11"',
            '"dst_ip.keyword": "10.1.10.10"',
            "source_dnp3_doc_id.keyword",
            "<COLLECTOR_HIT_IDS_JSON>",
            "<WINDOW_START>",
            "<WINDOW_END>",
        ):
            self.assertIn(needle, text, f"rule-query.template.json is missing frozen selector element: {needle}")

    def test_index_patterns_match_freeze_decision_table(self):
        self.assertEqual(apparatus.COLLECTOR_INDEX_PATTERN, "ot-logs-dnp3-*")
        self.assertEqual(apparatus.RULE_INDEX_PATTERN, "ot-signals-zone-violation-*")
        self.assertEqual(apparatus.PRE_TRIGGER_GUARD_SECONDS, 5)
        self.assertEqual(apparatus.SETTLE_WINDOW_SECONDS, 15)


class QueryCliExposesCollectorAndRuleSubcommands(unittest.TestCase):
    def test_cli_help_lists_both_stages(self):
        result = subprocess.run((sys.executable, str(CLI), "-h"), capture_output=True, text=True, cwd=str(ROOT))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("collector", result.stdout)
        self.assertIn("rule", result.stdout)

    def test_rule_refuses_to_run_before_a_collector_query_is_retained(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            run_evidence = Path(d) / "k8-3-range-a-001"
            (run_evidence / "ground-truth").mkdir(parents=True)
            (run_evidence / apparatus.T0_ARTIFACT).write_text("2026-01-01T00:00:00+00:00", encoding="utf-8")
            result = subprocess.run(
                (sys.executable, str(CLI), "rule", "--run-id", "k8-3-range-a-001",
                 "--run-evidence", str(run_evidence), "--compose", "unused.yml"),
                capture_output=True, text=True, cwd=str(ROOT))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("collector query", result.stderr)


class PublishedProcedureNamesTheLiteralQueryCommand(unittest.TestCase):
    """The defect was documentation exposure, so the documents are the test."""

    def _read(self, relative):
        return (STUDY_ROOT / relative).read_text(encoding="utf-8")

    def test_readme_gives_a_literal_collector_rule_query_command(self):
        readme = (STUDY01_ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("study01_query.py", readme)
        self.assertIn("c2-dnp3-collector-rule-query-procedure.md", readme)

    def test_query_procedure_document_names_the_frozen_index_patterns(self):
        procedure = self._read("protocol/c2-dnp3-collector-rule-query-procedure.md")
        self.assertIn("ot-logs-dnp3-*", procedure)
        self.assertIn("ot-signals-zone-violation-*", procedure)
        self.assertIn("study01_query.py", procedure)


if __name__ == "__main__":
    unittest.main()
