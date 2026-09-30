import importlib.util
import copy
import json
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
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


class ImageInventoryServiceResolutionTests(unittest.TestCase):
    """K8-3 diagnostic continuation regression (2026-09-30): fixed condition observed in
    formal attempt k8-repro-20260930-001. `docker compose images --format json` on
    Docker Compose v5.4.0 carries no "Service" key at all, and the underscore-containing
    service name "es_enrich_refresher" (and any other underscore-containing service, e.g.
    "wan_router", "cc_ups") could never match the old ContainerName-token fallback, because
    that fallback destroyed underscores (via .replace("_","-")) before comparing them
    against the un-mangled service name. `docker compose ps --format json` reliably
    carries both "Name" and "Service"; image_inventory() now resolves ContainerName ->
    Service from that instead of pattern-matching the container name string."""

    def _run_stub(self, config_services, images_rows, ps_rows, image_inspect_by_ref):
        def fake_run(argv, *, text=True, check=True):
            if argv[:2] == ["docker", "compose"] and "config" in argv:
                stdout = "\n".join(config_services)
            elif argv[:2] == ["docker", "compose"] and "images" in argv:
                stdout = json.dumps(images_rows)
            elif argv[:2] == ["docker", "compose"] and "ps" in argv:
                stdout = json.dumps(ps_rows)
            elif argv[:2] == ["docker", "image"]:
                ref = argv[3]
                stdout = json.dumps([image_inspect_by_ref[ref]])
            else:
                raise AssertionError(f"unexpected command in test stub: {argv!r}")
            return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")
        return fake_run

    def _project_fixture(self):
        project = "k8-range-a-20260930-001"
        # Real shape observed in k8-repro-20260930-001's retained compose-images.json:
        # no "Service" key anywhere, ContainerName is the only correlation key available.
        images_rows = [
            {"ID": "sha256:" + "1" * 64, "ContainerName": f"{project}-elasticsearch-1",
             "Repository": "docker.elastic.co/elasticsearch/elasticsearch", "Tag": "8.12.0"},
            {"ID": "sha256:" + "2" * 64, "ContainerName": f"{project}-cc_ups-1",
             "Repository": "ghcr.io/schutzz/amenonuboco-power-grid-python-tools", "Tag": ""},
            {"ID": "sha256:" + "3" * 64, "ContainerName": f"{project}-wan_router-1",
             "Repository": "ghcr.io/schutzz/amenonuboco-network-tools", "Tag": ""},
            {"ID": "sha256:" + "4" * 64, "ContainerName": f"{project}-es_enrich_refresher-1",
             "Repository": "curlimages/curl", "Tag": "latest"},
        ]
        ps_rows = [
            {"Name": row["ContainerName"], "Service": row["ContainerName"][len(project) + 1:-2]}
            for row in images_rows
        ]
        image_inspect_by_ref = {}
        for row in images_rows:
            ref = row["ID"]
            image_inspect_by_ref[ref] = {"Id": ref, "RepoDigests": []}
        config_services = [row["Service"] for row in ps_rows]
        return project, config_services, images_rows, ps_rows, image_inspect_by_ref

    def test_underscore_service_names_resolve_via_ps_service_field(self):
        project, config_services, images_rows, ps_rows, inspect_by_ref = self._project_fixture()
        self.assertIn("es_enrich_refresher", config_services)  # fixture matches the observed failure
        with tempfile.TemporaryDirectory() as d:
            run_evidence = Path(d) / "run-evidence"
            (run_evidence / "environment").mkdir(parents=True)
            a = Namespace(run_id=project, compose=Path("compose.yml"), run_evidence=run_evidence)
            fake_run = self._run_stub(config_services, images_rows, ps_rows, inspect_by_ref)
            with unittest.mock.patch.object(formal, "run", side_effect=fake_run):
                formal.image_inventory(a)
            written = json.loads((run_evidence / "environment" / "image-inventory.json").read_text(encoding="utf-8"))
            resolved_services = sorted(row["service"] for row in written["services"])
            self.assertEqual(resolved_services, sorted(config_services))
            es_row = next(row for row in written["services"] if row["service"] == "es_enrich_refresher")
            self.assertEqual(es_row["resolved_reference"], "sha256:" + "4" * 64)

    def test_zero_matching_rows_still_fails_closed(self):
        project, config_services, images_rows, ps_rows, inspect_by_ref = self._project_fixture()
        # Drop the ps row that would let "es_enrich_refresher" resolve at all.
        ps_rows = [r for r in ps_rows if r["Service"] != "es_enrich_refresher"]
        with tempfile.TemporaryDirectory() as d:
            run_evidence = Path(d) / "run-evidence"
            (run_evidence / "environment").mkdir(parents=True)
            a = Namespace(run_id=project, compose=Path("compose.yml"), run_evidence=run_evidence)
            fake_run = self._run_stub(config_services, images_rows, ps_rows, inspect_by_ref)
            with unittest.mock.patch.object(formal, "run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "got 0"):
                    formal.image_inventory(a)

    def test_multiple_matching_rows_still_fails_closed(self):
        project, config_services, images_rows, ps_rows, inspect_by_ref = self._project_fixture()
        # A second images row that also maps to "es_enrich_refresher" via ps must not be
        # silently accepted -- exactly one row is required, never a "first match wins".
        duplicate = dict(images_rows[-1]); duplicate["ID"] = "sha256:" + "5" * 64
        duplicate["ContainerName"] = f"{project}-es_enrich_refresher-2"
        images_rows = images_rows + [duplicate]
        ps_rows = ps_rows + [{"Name": duplicate["ContainerName"], "Service": "es_enrich_refresher"}]
        inspect_by_ref[duplicate["ID"]] = {"Id": duplicate["ID"], "RepoDigests": []}
        with tempfile.TemporaryDirectory() as d:
            run_evidence = Path(d) / "run-evidence"
            (run_evidence / "environment").mkdir(parents=True)
            a = Namespace(run_id=project, compose=Path("compose.yml"), run_evidence=run_evidence)
            fake_run = self._run_stub(config_services, images_rows, ps_rows, inspect_by_ref)
            with unittest.mock.patch.object(formal, "run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "got 2"):
                    formal.image_inventory(a)


class RuntimeObservationUnrelatedMirrorFilterTests(unittest.TestCase):
    """K8-3 diagnostic continuation cross-check (2026-09-30, one-time bounded
    review of docs/k8-formal-actions.json): runtime_observation()'s Range B
    branch previously re-queried the FAULT interface itself under the
    misleading name "unrelated-mirror-filters.txt" and asserted nothing --
    c2-dnp3-range-derivation.md §3 requires verifying that an UNRELATED
    observed-segment mirror filter remains available. The qualified
    Shakedown mechanism (Assert-K8UnrelatedMirrorFilter) enumerates every
    OTHER interface (excluding lo and the fault interface) and fails closed
    if none retains a mirred egress mirror filter; this was an
    INDEPENDENT_EQUIVALENCE_UNTESTED gap now closed to match."""

    ROUTER = "router-cid"
    ZONE = "zone-cid"
    IFACE = "eth5"

    def _seed_required_evidence(self, run_evidence, range_="B"):
        rel = ["ground-truth/independent-capture/capture-lifecycle.json",
               "sensor-input/mirror-capture/capture-lifecycle.json",
               "collector-output/collector-response.json", "rule-output/rule-response.json"]
        if range_ == "B": rel += ["contract-output/r-obs-05-mapping-gate.json", "contract-output/r-obs-05-correlation.json"]
        for r in rel:
            p = run_evidence / r
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("{}", encoding="utf-8")

    def _run_stub(self, link_show_lines, filters_by_iface):
        def fake_run(argv, *, text=True, check=True):
            if argv[:4] == ["docker", "compose", "-p", "k8-range-b-1"]:
                stdout = json.dumps([{"Service": "wan_router"}])
            elif argv[:3] == ["docker", "exec", self.ROUTER] and argv[3:6] == ["sh", "-lc", "ip -o -4 addr show"]:
                stdout = f"5: {self.IFACE}    inet 10.1.20.254/24 scope global {self.IFACE}\\       valid_lft forever preferred_lft forever"
            elif argv[:4] == ["docker", "exec", self.ROUTER, "tc"] and argv[4:7] == ["qdisc", "show", "dev"]:
                stdout = "qdisc noqueue 0: root refcnt 2"
            elif argv[:4] == ["docker", "exec", self.ROUTER, "ip"] and argv[4:] == ["-o", "link", "show"]:
                stdout = "\n".join(link_show_lines)
            elif argv[:4] == ["docker", "exec", self.ROUTER, "tc"] and argv[4:6] == ["filter", "show"]:
                other = argv[argv.index("dev") + 1]
                stdout = filters_by_iface.get(other, "")
            elif argv[:2] == ["docker", "inspect"]:
                stdout = "true"
            else:
                raise AssertionError(f"unexpected command in test stub: {argv!r}")
            return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")
        return fake_run

    def _resolve_container_stub(self):
        def fake_resolve(run_id, compose, service="elasticsearch"):
            return {"wan_router": self.ROUTER, "zone_detector": self.ZONE}[service]
        return fake_resolve

    def test_unrelated_interface_with_mirror_filter_passes_and_excludes_fault_interface(self):
        link_lines = [f"5: {self.IFACE}:    <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500",
                      "1: lo:    <LOOPBACK,UP,LOWER_UP> mtu 65536",
                      "8: eth7:    <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"]
        # Real iproute2 tc output for a MIRROR (not redirect) action names the
        # target device inside the parenthetical, then repeats the action
        # class word right after "Egress": "Egress Mirror to device X".
        filters = {"eth7": "filter parent ffff: protocol all pref 1 matchall\n\taction order 1: mirred (Egress Mirror to device eth3) pipe"}
        with tempfile.TemporaryDirectory() as d:
            run_evidence = Path(d) / "run-evidence"; run_evidence.mkdir()
            self._seed_required_evidence(run_evidence)
            a = Namespace(run_id="k8-range-b-1", compose=Path("compose.yml"), run_evidence=run_evidence, range="B")
            with unittest.mock.patch.object(formal, "run", side_effect=self._run_stub(link_lines, filters)), \
                 unittest.mock.patch.object(formal, "resolve_container", side_effect=self._resolve_container_stub()):
                formal.runtime_observation(a)
            written = json.loads((run_evidence / "contract-output" / "unrelated-mirror-filters.json").read_text(encoding="utf-8"))
            self.assertEqual(written["fault_interface"], self.IFACE)
            probed_ifaces = [row["interface"] for row in written["probed"]]
            self.assertNotIn(self.IFACE, probed_ifaces)  # the fault interface itself must be excluded
            self.assertNotIn("lo", probed_ifaces)
            self.assertIn("eth7", probed_ifaces)
            nontriviality = json.loads((run_evidence / "contract-output" / "range-b-nontriviality.json").read_text(encoding="utf-8"))
            self.assertTrue(nontriviality["unrelated_mirror_filter_found"])

    def test_no_unrelated_interface_with_mirror_filter_fails_closed(self):
        link_lines = [f"5: {self.IFACE}:    <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500",
                      "1: lo:    <LOOPBACK,UP,LOWER_UP> mtu 65536",
                      "8: eth7:    <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"]
        filters = {"eth7": "filter parent ffff: protocol all pref 1 matchall\naction drop"}  # no mirred egress mirror anywhere
        with tempfile.TemporaryDirectory() as d:
            run_evidence = Path(d) / "run-evidence"; run_evidence.mkdir()
            self._seed_required_evidence(run_evidence)
            a = Namespace(run_id="k8-range-b-1", compose=Path("compose.yml"), run_evidence=run_evidence, range="B")
            with unittest.mock.patch.object(formal, "run", side_effect=self._run_stub(link_lines, filters)), \
                 unittest.mock.patch.object(formal, "resolve_container", side_effect=self._resolve_container_stub()):
                with self.assertRaisesRegex(RuntimeError, "no unrelated gateway interface retained a mirred egress mirror filter"):
                    formal.runtime_observation(a)


if __name__ == "__main__": unittest.main()
