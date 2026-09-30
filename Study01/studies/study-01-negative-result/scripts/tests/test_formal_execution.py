import importlib.util
import copy
import json
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path


SCRIPTS = Path(__file__).parents[1]
if str(SCRIPTS) not in sys.path: sys.path.insert(0,str(SCRIPTS))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


formal = load("study01_formal_actions", SCRIPTS / "study01_formal_actions.py")
packager = load("k8_rangec_formal_package", Path(__file__).parents[5] / "shakedown" / "tools" / "k8_rangec_formal_package.py")
producer = load("study01_range_c", SCRIPTS / "study01_range_c.py")
REPO = Path(__file__).parents[5]


class FormalExecutionTests(unittest.TestCase):
    def range_c_records(self, root):
        producer_root=root/"range-c-producer"/"v"; records=producer_root/"run-records"; evidence=producer_root/"run-evidence"
        records.mkdir(parents=True); evidence.mkdir()
        environment={"schema":"k8shakedown-range-c-environment/1","worktree":{"source":{"head":"a"*40},"disposable":{"head":"b"*40,"clean":True}},
                     "validator_source":{"pinned_commit":"b"*40},"versions":[{"name":n,"status":"succeeded","value":n+"-v"} for n in ("git","python","pydantic","pyyaml")]}
        observation={"observations":[{"argv":["python","platform/cli.py"],"exit_code":1,"stdout":{"bytes":0},"stderr":{"bytes":4}}]}
        candidates=producer.deviation_candidates(observation,environment,producer.ACCEPTED_EXITS,"2026-01-01T00:00:00+00:00")
        candidate_record={"schema":"k8shakedown-deviation-candidates/1","range":"c","generated_utc":"2026-01-01T00:00:00+00:00","candidates":candidates}
        producer.dump(records/"range-c-environment.json",environment); producer.dump(records/"deviation-candidates.json",candidate_record)
        producer.bind_producer_records(producer_root,records,evidence)
        return producer_root,records,evidence,environment,observation,candidate_record

    def test_range_c_candidate_transcription_and_human_boundary(self):
        with tempfile.TemporaryDirectory() as d:
            _,_,_,_,_,record=self.range_c_records(Path(d))
            multi=[c for c in record["candidates"] if c["class"]=="multi-valued-acceptance"]
            self.assertEqual(len(multi),1); self.assertRegex(multi[0]["candidate_id"],r"^dc-\d{3}$")
            forbidden={"judgment","disposition","verdict","accepted","is_deviation","none","no_impact"}
            self.assertFalse(forbidden & set(multi[0]))
            with self.assertRaises(packager.PackagingError): packager.assert_candidate_citation_coverage(record,"human text without id")
            packager.assert_candidate_citation_coverage(record,f"reviewed {multi[0]['candidate_id']}")
            self.assertNotIn("expected/",(SCRIPTS/"study01_range_c.py").read_text(encoding="utf-8"))
            # The same supplied domain controls cardinality and rendered fact.
            _,_,_,environment,observation,_=self.range_c_records(Path(d)/"second")
            single=producer.deviation_candidates(observation,environment,(1,),"2026-01-01T00:00:00+00:00")
            self.assertFalse(any(c["class"]=="multi-valued-acceptance" for c in single))
            supplied=producer.deviation_candidates(observation,environment,(1,7),"2026-01-01T00:00:00+00:00")
            rendered=next(c for c in supplied if c["class"]=="multi-valued-acceptance")
            self.assertIn("accepted exits [1, 7]",rendered["observed_fact"])
            # Existing ordering remains: inconsistency, multi-valued, incomplete.
            inconsistent=copy.deepcopy(observation); inconsistent["observations"][0]["exit_code"]=0
            incomplete=copy.deepcopy(environment); incomplete["versions"][0]["status"]="unavailable"
            ordered=producer.deviation_candidates(inconsistent,incomplete,(0,1),"2026-01-01T00:00:00+00:00")
            self.assertEqual([c["class"] for c in ordered[:3]],
                             ["internal-inconsistency","multi-valued-acceptance","incomplete-observation"])
            self.assertEqual([c["candidate_id"] for c in ordered[:3]],["dc-001","dc-002","dc-003"])

    def test_range_c_producer_integrity_binding_and_mutation_rejection(self):
        for target in ("range-c-environment.json","deviation-candidates.json"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as d:
                _,records,evidence,_,_,_=self.range_c_records(Path(d))
                self.assertEqual(packager.verify_producer_binding(evidence,records),[])
                (records/target).write_text("{}\n",encoding="utf-8")
                self.assertTrue(packager.verify_producer_binding(evidence,records))
                with self.assertRaises(packager.PackagingError): packager.require_producer_binding(evidence,records)
                self.assertTrue(any("producer record" in p for p in packager.verify(Path(d)/"package",evidence,records)))

    def test_packager_uses_retained_environment_facts(self):
        with tempfile.TemporaryDirectory() as d:
            _,records,evidence,environment,observation,_=self.range_c_records(Path(d))
            retained=packager.load_json(records/"range-c-environment.json","environment")
            rendered=packager.render_versions_json(retained,observation)
            self.assertEqual(rendered["versions"]["python"],"python-v")
            self.assertEqual(packager.verify_producer_binding(evidence,records),[])

    def test_teardown_ordering_range_specific_regression(self):
        inventory_path=REPO/"Study01"/"docs"/"k8-formal-actions.json"; inventory=json.loads(inventory_path.read_text(encoding="utf-8"))
        checker=REPO/"Study01"/"tools"/"Test-ExecutionCompleteness.ps1"
        def check(value):
            with tempfile.TemporaryDirectory() as d:
                p=Path(d)/"inventory.json"; p.write_text(json.dumps(value),encoding="utf-8")
                return subprocess.run(["pwsh","-NoProfile","-File",str(checker),"-InventoryPath",str(p)],capture_output=True,text=True)
        valid=check(inventory); self.assertEqual(valid.returncode,0,valid.stdout+valid.stderr)
        premature=copy.deepcopy(inventory)
        teardown=next(a for a in premature["actions"] if a["action_id"]=="A15-teardown")
        teardown["depends_on"]=["A09-capture-stop-export"]; teardown["input_origin"]=["range-ab:pcaps"]
        failed=check(premature); self.assertNotEqual(failed.returncode,0)
        self.assertIn("A/A15-teardown",failed.stdout+failed.stderr); self.assertIn("B/A15-teardown",failed.stdout+failed.stderr)
        # The valid A graph must not inherit either Range-B-only prerequisite.
        sender=next(a for a in inventory["actions"] if a["action_id"]=="A08-sender-t0")
        runtime=next(a for a in inventory["actions"] if a["action_id"]=="A12-runtime-observation")
        self.assertNotIn("B02-robs05-capture-start",sender["depends_on"])
        self.assertNotIn("B03-robs05-observation",runtime["depends_on"])

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
