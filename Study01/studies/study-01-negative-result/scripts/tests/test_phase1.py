import json, unittest, tempfile, subprocess
from pathlib import Path
import sys
ROOT=Path(__file__).parents[1]; sys.path.insert(0, str(ROOT))
from study01.scorer import score, UncoveredSemanticState
from study01_collect import validate, RUNTIME_DIRS
from study01.evidence_tree import create as create_evidence_tree
from study01.procedure_conformance import ProcedureConformanceError, may_continue_same_run
from study01 import preflight
from study01.frozen import apparatus

T0_FIXTURE="2026-08-25T00:00:30+00:00"
GOOD_PROCEDURE={"schema_version":2,"sender_invocations":[{"timestamp":T0_FIXTURE,"exit_code":0}],"invocation_count":1,"same_run_retry":False,"procedure_invalid":False,"invalid_reasons":[]}
BASE={"range":"A","stages":{"ground_truth":"Pass","sensor":"Pass","collector":"Pass"},"rule_output":"Alert","runtime_contract":"Pass","evidence_correlatable":True,"procedure_conformance":GOOD_PROCEDURE}
def procedure_file(root, record=GOOD_PROCEDURE):
  (root/"ground-truth"/"procedure-conformance.json").write_text(json.dumps(record), encoding="utf-8")


def good_steps(): return [dict(s) for s in lifecycle_record("r","ground-truth")["steps"]]

def lifecycle_record(run_id, stage, interface=None, pcap_sha=None, t0=T0_FIXTURE, run_root=None, listening_done=None, container="def456"):
  """Build a record whose argv and timestamps satisfy the frozen bindings."""
  import os
  from datetime import datetime, timedelta
  from study01 import capture_lifecycle as lc
  from study01.frozen import apparatus as ap
  spec=ap.CAPTURE_STAGES[stage]
  iface=interface if interface is not None else (spec["interface"] or "eth3")
  root=lc.normalize_root(run_root if run_root is not None else os.path.abspath(os.path.join(os.sep,"host",run_id)))
  rec={"schema_version":1,"run_id":run_id,"execution_run_root":root,"stage":stage,"helper_name":f"{run_id}-{stage}-capture",
       "helper_image":ap.CAPTURE_IMAGE,"helper_container_id":"abc123","namespace_service":spec["service"],
       "namespace_container_id":container,"interface":iface,"filter":ap.CAPTURE_FILTER,
       "container_pcap":spec["container_pcap"],"artifact":spec["artifact"],
       "pcap_sha256":pcap_sha or "0"*64,"steps":[]}
  base=datetime.fromisoformat(t0)
  when={"start":base-timedelta(seconds=30),"listening-check":base-timedelta(seconds=20),
        "window-end-liveness-check":base+timedelta(seconds=38),
        "stop":base+timedelta(seconds=40),"export":base+timedelta(seconds=41),"remove":base+timedelta(seconds=42)}
  for s in lc.STEPS:
   argv=lc.expected_argv(rec, s)
   done=when[s]+timedelta(seconds=1)
   if s=="listening-check" and listening_done is not None: done=listening_done
   rec["steps"].append({"step":s,"argv":argv,"timestamp":when[s].isoformat(),
                        "completed_at":done.isoformat(),"exit_code":0,
                        "output":("abc123" if s=="start"
                                  else f"tcpdump: listening on {iface}" if s=="listening-check"
                                  else "true" if s=="window-end-liveness-check" else "ok")})
  return rec

def context_record(run_id, stage, interface="eth3", container="def456"):
  from study01 import capture_context as cc
  from study01.frozen import apparatus as ap
  spec=ap.CAPTURE_STAGES[stage]
  rec={"schema_version":1,"run_id":run_id,"stage":stage,"namespace_service":spec["service"],
       "namespace_resolution":{"argv":cc.compose_argv(run_id,"c.yml",spec["service"]),
                               "output":container,"exit_code":0},
       "resolved_container_id":container,"interface_resolution":None,
       "normalized_interface":spec["interface"]}
  if spec["interface"] is None:
   raw="\n".join(["lo   UNKNOWN  127.0.0.1/8", f"{interface}@if99   UP   {ap.GATEWAY_CIDR}"])+"\n"
   found=cc.matching_tokens(raw)
   rec["interface_resolution"]={"argv":cc.interface_argv(container),"output":raw,"exit_code":0,
                                "matching_tokens":found,"match_count":len(found),
                                "selected_token":found[0].split()[0]}
   rec["normalized_interface"]=interface
  return rec

def retention_artifacts(root, interface="eth3"):
  """Write the primary artifacts capture procedure section 5 and T0 require."""
  import hashlib
  from study01.frozen import apparatus as ap
  from study01.evidence_io import write_text
  write_text(root/ap.T0_ARTIFACT, T0_FIXTURE)
  for stage, spec in ap.CAPTURE_STAGES.items():
   art=root/spec["artifact"]; art.parent.mkdir(parents=True, exist_ok=True)
   art.write_bytes(b"\xd4\xc3\xb2\xa1pcap-"+stage.encode())
   rec=lifecycle_record(root.name, stage, interface=(interface if spec["interface"] is None else None),
                        pcap_sha=hashlib.sha256(art.read_bytes()).hexdigest(), run_root=root.resolve())
   write_text(root/spec["lifecycle"], json.dumps(rec, indent=2))
   write_text(root/spec["context"], json.dumps(context_record(root.name, stage, interface), indent=2))

class Phase1Tests(unittest.TestCase):
 def procedure_file(self, root, record=GOOD_PROCEDURE):
   procedure_file(root, record)
 def test_1_invalid_precedes_inconclusive(self):
  r={**BASE,"stages":{**BASE["stages"],"sensor":"Invalid","collector":"Unresolved"}}; self.assertEqual(score(r)["experiment_classification"],"Invalid run")
 def test_2_error_inconclusive_but_invalid_wins(self):
  self.assertEqual(score({**BASE,"rule_output":"Error"})["experiment_classification"],"Inconclusive experiment")
  self.assertEqual(score({**BASE,"rule_output":"Error","stages":{**BASE["stages"],"sensor":"Invalid"}})["experiment_classification"],"Invalid run")
 def test_2a_procedure_invalid_precedes_inconclusive(self):
  failed={"schema_version":2,"sender_invocations":[{"timestamp":"2026-08-24T11:31:42.361361+00:00","exit_code":2},{"timestamp":"2026-08-24T11:32:09.249958+00:00","exit_code":0}],"invocation_count":2,"same_run_retry":True,"procedure_invalid":True,"invalid_reasons":["sender_command_failure","sender_invocation_count_not_one","same_run_retry"]}
  self.assertEqual(score({**BASE,"procedure_conformance":failed,"stages":{**BASE["stages"],"sensor":"Unresolved"}})["experiment_classification"],"Invalid run")
  self.assertFalse(may_continue_same_run(failed))
 def test_2b_same_run_retry_without_second_event_is_invalid(self):
  retry={"schema_version":2,"sender_invocations":[{"timestamp":"2026-08-24T11:31:42+00:00","exit_code":2},{"timestamp":"2026-08-24T11:32:09+00:00","exit_code":0}],"invocation_count":2,"same_run_retry":True,"procedure_invalid":True,"invalid_reasons":["sender_command_failure","sender_invocation_count_not_one","same_run_retry"]}
  self.assertEqual(score({**BASE,"procedure_conformance":retry})["experiment_classification"],"Invalid run")
 def test_2c_malformed_procedure_fails_closed(self):
  with self.assertRaises(UncoveredSemanticState): score({**BASE,"procedure_conformance":{}})
 def test_2d_wrapper_guard_rejects_same_run_repair(self):
  failed={"schema_version":2,"sender_invocations":[{"timestamp":"2026-08-24T11:31:42+00:00","exit_code":2}],"invocation_count":1,"same_run_retry":False,"procedure_invalid":True,"invalid_reasons":["sender_command_failure"]}
  with tempfile.TemporaryDirectory() as d:
   record=Path(d)/"procedure-conformance.json"; record.write_text(json.dumps(failed), encoding="utf-8")
   result=subprocess.run([sys.executable, str(ROOT/"study01_procedure.py"), "guard-same-run", str(record)], capture_output=True, text=True)
   self.assertNotEqual(result.returncode, 0)
   self.assertIn("fresh run ID", result.stderr)
 def test_2e_sender_execution_path_rejects_same_run_second_invocation(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"fresh-run"; (root/"ground-truth").mkdir(parents=True)
   command=[sys.executable, str(ROOT/"study01_sender.py"), "--run-id", "fresh-run", "--run-evidence", str(root), "--", sys.executable, "-c", "import sys; sys.exit(2)"]
   first=subprocess.run(command, capture_output=True, text=True)
   self.assertNotEqual(first.returncode, 0)
   stored=json.loads((root/"ground-truth"/"procedure-conformance.json").read_text())
   self.assertTrue(stored["procedure_invalid"])
   second=subprocess.run(command, capture_output=True, text=True)
   self.assertNotEqual(second.returncode, 0)
   self.assertIn("fresh run ID", second.stderr)
 def test_2f_sender_execution_path_normal_allows_scoring(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"fresh-run"; (root/"ground-truth").mkdir(parents=True)
   command=[sys.executable, str(ROOT/"study01_sender.py"), "--run-id", "fresh-run", "--run-evidence", str(root), "--", sys.executable, "-c", "print('sent')"]
   self.assertEqual(subprocess.run(command, capture_output=True, text=True).returncode, 0)
   procedure=json.loads((root/"ground-truth"/"procedure-conformance.json").read_text())
   self.assertEqual(score({**BASE,"procedure_conformance":procedure})["experiment_classification"], "Valid detection result")
 def test_2g_send_time_unknowable_fields_are_rejected(self):
  """Schema 2 refuses a record asserting an observation the sender cannot have."""
  from study01.procedure_conformance import ProcedureConformanceError as PCE, validate as vp
  stale={**GOOD_PROCEDURE,"sender_invocations":[{**GOOD_PROCEDURE["sender_invocations"][0],"network_event_observed":True}]}
  with self.assertRaises(PCE): vp(stale)
  with self.assertRaises(PCE): vp({**GOOD_PROCEDURE,"schema_version":1})
  bad_reason={**GOOD_PROCEDURE,"procedure_invalid":True,"invalid_reasons":["sender_pcap_correlation_failure"]}
  with self.assertRaises(PCE): vp(bad_reason)
 def test_2h_sender_wrapper_records_only_send_time_facts(self):
  """The wrapper takes no observation argument and records none."""
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"fresh-run"; (root/"ground-truth").mkdir(parents=True)
   ok=subprocess.run([sys.executable, str(ROOT/"study01_sender.py"), "--run-id", "fresh-run",
                      "--run-evidence", str(root), "--", sys.executable, "-c", "print('sent')"],
                     capture_output=True, text=True)
   self.assertEqual(ok.returncode, 0)
   rec=json.loads((root/"ground-truth"/"procedure-conformance.json").read_text())
   self.assertEqual(set(rec["sender_invocations"][0]), {"timestamp","exit_code"})
   self.assertFalse(rec["procedure_invalid"])
   self.assertEqual(score({**BASE,"procedure_conformance":rec})["experiment_classification"], "Valid detection result")
 def test_2i_009_shape_survives_the_scope_reduction(self):
  """exit 2 still closes the run and still blocks a same-run second invocation."""
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"fresh-run"; (root/"ground-truth").mkdir(parents=True)
   cmd=[sys.executable, str(ROOT/"study01_sender.py"), "--run-id", "fresh-run",
        "--run-evidence", str(root), "--", sys.executable, "-c", "import sys; sys.exit(2)"]
   first=subprocess.run(cmd, capture_output=True, text=True)
   self.assertNotEqual(first.returncode, 0)
   rec=json.loads((root/"ground-truth"/"procedure-conformance.json").read_text())
   self.assertTrue(rec["procedure_invalid"])
   self.assertEqual(rec["invalid_reasons"], ["sender_command_failure"])
   self.assertEqual(score({**BASE,"procedure_conformance":rec})["experiment_classification"], "Invalid run")
   second=subprocess.run(cmd, capture_output=True, text=True)
   self.assertNotEqual(second.returncode, 0)
   self.assertIn("fresh run ID", second.stderr)
 def test_3_range_c_has_no_experiment_classification(self):
  self.assertIsNone(score({"range":"C","static_contract":"Fail","validator_result":"REJECT"})["experiment_classification"])
 def test_4_r_obs_05_failure(self):
  r={**BASE,"range":"B","rule_output":"No alert","runtime_contract":"Fail","r_obs_05":"Fail"}; o=score(r); self.assertEqual((o["runtime_contract"],o["experiment_classification"]),("Unresolved","Inconclusive experiment"))
 def test_5_uncorrelatable_alert(self): self.assertEqual(score({**BASE,"evidence_correlatable":False})["experiment_classification"],"Inconclusive experiment")
 def test_6_range_a_empty_capture(self):
  o=score({**BASE,"sensor_capture":"empty","sensor_liveness":False}); self.assertEqual((o["stages"]["sensor"],o["experiment_classification"]),("Unresolved","Inconclusive experiment"))
 def test_happy_and_negative_paths(self):
  self.assertEqual(score(BASE)["experiment_classification"],"Valid detection result")
  b={**BASE,"range":"B","stages":{**BASE["stages"],"sensor":"Fail","collector":"Fail"},"rule_output":"No alert","runtime_contract":"Fail","target_observation_absent":True,"r_obs_05":"Pass"}; self.assertEqual(score(b)["experiment_classification"],"Invalid negative result")
 def test_uncovered_fails_closed(self):
  with self.assertRaises(UncoveredSemanticState): score({**BASE,"rule_output":"No alert","runtime_contract":"Not applicable"})
 def test_drift_text(self):
  protocol=ROOT.parent/"protocol"; text=(protocol/"amendments.md").read_text(encoding="utf-8")+(protocol/"scoring.md").read_text(encoding="utf-8")
  for token in ("Rule output = Error", "R-OBS-05 Fail", "Inconclusive experiment", "source_dnp3_doc_id", "Range C", "Invalid run"): self.assertIn(token,text)
 def test_capture_procedure_frozen_anchors(self):
  procedure=(ROOT.parent/"protocol"/"c2-dnp3-capture-procedure.md").read_text(encoding="utf-8")
  inventory=(ROOT.parent/"protocol"/"c2-dnp3-image-inventory.md").read_text(encoding="utf-8")
  for token in ("corfr/tcpdump@sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b", "--network container:<container-id>", "10.1.20.254/24", "zero or multiple", "ground-truth/independent-capture/c2-original-path.pcap", "sensor-input/mirror-capture/c2-mirror-sensor.pcap", "[T0 - 5 seconds, T0 + 15 seconds]", "fresh run ID"):
   self.assertIn(token, procedure)
  self.assertIn("corfr/tcpdump@sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b", inventory)
  self.assertNotIn("apt-get install", procedure)
 def test_capture_device_normalization(self):
  normalize=lambda token: token.split("@", 1)[0]
  self.assertEqual(normalize("eth6@if5890"), "eth6")
  self.assertEqual(normalize("eth2"), "eth2")
 def test_sender_directory_preparation_is_fixed(self):
  procedure=(ROOT.parent/"protocol"/"c2-dnp3-sender-procedure.md").read_text(encoding="utf-8")
  expected_hash="093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B"
  for token in ("mkdir -p /study/traffic", "docker cp", "/study/traffic/send_direct_operate.py", expected_hash, "directory preparation → `docker cp` → in-container hash verification → `T0` → exactly-one invocation"):
   self.assertIn(token, procedure)
  self.assertIn("no untracked host bind mount or ad hoc `/tmp` copy is permitted", procedure)
 def test_sender_wrapper_preflight_inputs(self):
  asset=ROOT.parent/"experiments"/"shared"/"traffic"/"send_direct_operate.py"
  import hashlib
  self.assertTrue(asset.is_file())
  self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest().upper(), "093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B")
  def scalar(value):
   if not isinstance(value, str) or not value.strip(): raise ValueError("container ID must be one non-empty scalar string")
   return value
  self.assertEqual(scalar("abc123"), "abc123")
  with self.assertRaises(ValueError): scalar(["a", "b"])
 def test_evidence_tree_preflight_uses_schema_paths(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"range-a"/"preflight-run"
   created=create_evidence_tree(root)
   self.assertEqual(tuple(p.relative_to(root).as_posix() for p in created), ("environment", "ground-truth", "sensor-input", "collector-output", "rule-output", "contract-output", "ground-truth/independent-capture", "sensor-input/mirror-capture"))
   self.assertTrue(all(p.is_dir() and p.is_relative_to(root) for p in created))
   self.assertFalse(any("+" in str(p) for p in created))
 def test_evidence_validation_has_no_classification(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d); (root/"metadata.md").write_text("metadata"); (root/"deviations.md").write_text("none")
   for name in RUNTIME_DIRS: (root/name).mkdir(); (root/name/"retained.txt").write_text("fixture")
   self.procedure_file(root); retention_artifacts(root)
   self.assertIsNone(validate(root))
 def test_evidence_requires_valid_procedure_conformance(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d); (root/"metadata.md").write_text("metadata"); (root/"deviations.md").write_text("none")
   for name in RUNTIME_DIRS: (root/name).mkdir(); (root/name/"retained.txt").write_text("fixture")
   with self.assertRaises(ValueError): validate(root)
 def test_score_requires_evidence_procedure_identity(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d); (root/"ground-truth").mkdir(); self.procedure_file(root)
   input_file=root/"scoring-input.json"; input_file.write_text(json.dumps(BASE), encoding="utf-8")
   output=root/"scoring-record.json"
   command=[sys.executable, str(ROOT/"study01_score.py"), str(input_file), "--run-evidence", str(root), "--output", str(output)]
   self.assertEqual(subprocess.run(command, capture_output=True, text=True).returncode, 0)
   mismatched={**BASE,"procedure_conformance":{**GOOD_PROCEDURE,"procedure_invalid":True,"invalid_reasons":["sender_output_failure"]}}
   input_file.write_text(json.dumps(mismatched), encoding="utf-8")
   self.assertNotEqual(subprocess.run(command, capture_output=True, text=True).returncode, 0)
   input_file.write_text(json.dumps({key:value for key,value in BASE.items() if key != "procedure_conformance"}), encoding="utf-8")
   self.assertNotEqual(subprocess.run(command, capture_output=True, text=True).returncode, 0)
   (root/"ground-truth"/"procedure-conformance.json").write_text("{}", encoding="utf-8")
   with self.assertRaises(ValueError): validate(root)
 def test_evidence_empty_subdirectory_is_not_an_artifact(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d); (root/"metadata.md").write_text("metadata"); (root/"deviations.md").write_text("none")
   for name in RUNTIME_DIRS: (root/name).mkdir(); (root/name/"nested").mkdir()
   for name in RUNTIME_DIRS[:-1]: (root/name/"retained.txt").write_text("fixture")
   self.procedure_file(root); retention_artifacts(root)
   with self.assertRaises(ValueError): validate(root)
 def test_evidence_integrity_detects_tampering(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d); (root/"metadata.md").write_text("metadata"); (root/"deviations.md").write_text("none")
   for name in RUNTIME_DIRS: (root/name).mkdir(); (root/name/"retained.txt").write_text("fixture")
   self.procedure_file(root); retention_artifacts(root)
   import hashlib
   entries=[f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(root).as_posix()}" for f in sorted(root.rglob("*")) if f.is_file()]
   (root/"hashes.sha256").write_text("\n".join(entries)+"\n"); validate(root, True)
   (root/"rule-output"/"retained.txt").write_text("changed")
   with self.assertRaises(ValueError): validate(root, True)
 def test_hash_manifest_is_one_file_per_line_and_verifiable(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d); (root/"metadata.md").write_text("metadata"); (root/"deviations.md").write_text("none")
   for name in RUNTIME_DIRS: (root/name).mkdir(); (root/name/"retained.txt").write_text(name)
   self.procedure_file(root); retention_artifacts(root)
   from study01_collect import files
   import hashlib
   lines=[f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(root).as_posix()}" for f in files(root)]
   (root/"hashes.sha256").write_text("\n".join(lines)+"\n", encoding="utf-8")
   self.assertEqual(len(lines), len((root/"hashes.sha256").read_text().splitlines()))
   validate(root, True)

COMPOSE_BODY="services:\n  sub_a_ied_02:\n    build: ../protocol-images/dnp3\n    volumes:\n    - {bind}:/app/loader.py:ro\n"
class PreflightTests(unittest.TestCase):
 """Each check is bound to the attempt whose host-side failure motivated it."""
 def worktree(self, d, workspace="manifests"):
  """A minimal fixed worktree whose generated Compose sits at the given depth."""
  root=Path(d)/"worktree"; (root/"protocol-images"/"dnp3").mkdir(parents=True)
  bind=root/"platform"/"loader.py"; bind.parent.mkdir(parents=True); bind.write_text("asset")
  compose=root.joinpath(*workspace.split("/"))/"power-grid-reference.range-a.docker-compose.yml"
  compose.parent.mkdir(parents=True)
  compose.write_text(COMPOSE_BODY.format(bind=bind.as_posix()), encoding="utf-8")
  return root, compose
 def test_7a_msys_shell_is_rejected(self):
  self.assertFalse(preflight.canonical_shell("7.4.6", {"MSYSTEM":"MINGW64"}).ok)
  self.assertFalse(preflight.canonical_shell("5.1.19041.6093", {}).ok)
  self.assertTrue(preflight.canonical_shell("7.4.6", {}).ok)
 def test_7b_rewritten_container_paths_are_rejected(self):
  """Attempt 009's exact MSYS rewrite, reproduced without Docker."""
  mangled=["C:/Program Files/Git"+p for p in apparatus.CONTAINER_PATH_PROBES]
  self.assertFalse(preflight.container_path_probes(mangled).ok)
  self.assertTrue(preflight.container_path_probes(apparatus.CONTAINER_PATH_PROBES).ok)
 def test_7c_run_workspace_depth_is_fixed(self):
  """Attempt 010 placed the Compose file two levels below the worktree root."""
  with tempfile.TemporaryDirectory() as d:
   root, compose=self.worktree(d)
   self.assertTrue(preflight.run_workspace_placement(compose, root).ok)
  with tempfile.TemporaryDirectory() as d:
   root, compose=self.worktree(d, "runs/k5-range-a-20260824-010")
   self.assertFalse(preflight.run_workspace_placement(compose, root).ok)
 def test_7d_unresolved_build_context_is_detected(self):
  """The same depth error, seen through the context Buildx would resolve."""
  with tempfile.TemporaryDirectory() as d:
   root, compose=self.worktree(d)
   self.assertTrue(preflight.compose_build_contexts(compose).ok)
  with tempfile.TemporaryDirectory() as d:
   root, compose=self.worktree(d, "runs/k5-range-a-20260824-010")
   check=preflight.compose_build_contexts(compose)
   self.assertFalse(check.ok); self.assertIn("runs", check.detail)
 def test_7e_unparseable_compose_fails_closed(self):
  """No readable build context may satisfy the gate, whatever the cause."""
  for label, body in (("declared but unparseable","services:\n  a:\n    build:\n"),
                      ("empty",""), ("not yaml","%%% corrupted %%%\n"),
                      ("truncated before services","networks:\n  cc_lan:\n    driver: bridge\n")):
   with self.subTest(label), tempfile.TemporaryDirectory() as d:
    compose=Path(d)/"x.yml"; compose.write_text(body, encoding="utf-8")
    self.assertFalse(preflight.compose_build_contexts(compose).ok)
 def test_7f_missing_bind_source_is_detected(self):
  with tempfile.TemporaryDirectory() as d:
   root, compose=self.worktree(d)
   self.assertTrue(preflight.compose_bind_sources(compose).ok)
   (root/"platform"/"loader.py").unlink()
   self.assertFalse(preflight.compose_bind_sources(compose).ok)
 def test_7g_incomplete_evidence_tree_is_rejected(self):
  """Attempt 008 omitted the nested capture export destinations."""
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"k5-range-a-20260824-011"; create_evidence_tree(root)
   self.assertTrue(preflight.evidence_tree(root).ok)
   (root/"sensor-input"/"mirror-capture").rmdir()
   self.assertFalse(preflight.evidence_tree(root).ok)
 def test_7h_non_fresh_evidence_tree_is_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"k5-range-a-20260824-011"; create_evidence_tree(root)
   (root/"ground-truth"/"sender-record.txt").write_text("carried over")
   self.assertFalse(preflight.evidence_tree(root).ok)
 def test_7i_unusable_worktree_git_is_rejected(self):
  """Covers the `dubious ownership` class observed on the execution host."""
  with tempfile.TemporaryDirectory() as d:
   self.assertFalse(preflight.worktree_git(Path(d)).ok)
 def test_7j_one_run_id_names_project_teardown_and_evidence(self):
  run="k5-range-a-20260824-011"; evidence=Path("/tmp")/run
  self.assertTrue(preflight.project_name_binding(run, run, run, evidence).ok)
  self.assertFalse(preflight.project_name_binding(run, run, "k5-range-a-20260824-010", evidence).ok)
  self.assertFalse(preflight.project_name_binding(run, run, run, Path("/tmp/other")).ok)
 def test_7k_compose_hash_is_recorded_not_gated(self):
  """The hash embeds absolute bind paths, so it cannot gate cross-run equality."""
  with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
   _, first=self.worktree(d1); _, second=self.worktree(d2)
   a, b=preflight.compose_integrity(first), preflight.compose_integrity(second)
   self.assertTrue(a.ok and b.ok)
   self.assertNotEqual(a.detail, b.detail)
 def test_7l_wrapper_and_scorer_interfaces_are_available(self):
  self.assertTrue(preflight.sender_wrapper(ROOT).ok)
  self.assertTrue(preflight.capture_wrapper(ROOT).ok)
  self.assertTrue(preflight.scorer_wiring(ROOT).ok)
  with tempfile.TemporaryDirectory() as d: self.assertFalse(preflight.capture_wrapper(Path(d)).ok)
 def test_7n_preflight_anchors_are_bound_to_the_procedures(self):
  protocol=ROOT.parent/"protocol"
  derivation=(protocol/"c2-dnp3-range-derivation.md").read_text(encoding="utf-8")
  sender=(protocol/"c2-dnp3-sender-procedure.md").read_text(encoding="utf-8")
  capture=(protocol/"c2-dnp3-capture-procedure.md").read_text(encoding="utf-8")
  for token in ("study01_preflight.py", "exactly one level below", "../protocol-images/", "within-run integrity record"):
   self.assertIn(token, derivation)
  for token in ("study01_capture.py", "capture-lifecycle.json", "fails closed"):
   self.assertIn(token, capture)
  for token in ("PowerShell 7", "Git Bash"): self.assertIn(token, sender); self.assertIn(token, capture)
  for path in apparatus.CONTAINER_PATH_PROBES: self.assertIn(path, derivation)
 def test_7m_sender_asset_hash_is_checked_host_side(self):
  self.assertTrue(preflight.sender_asset(ROOT.parents[2]).ok)
  self.assertFalse(preflight.sender_asset(ROOT).ok)

class RetentionTests(unittest.TestCase):
 """Every check here exists because run 013's retained evidence lacked it."""
 def lifecycle(self, stage="ground-truth", **over):
  rec=lifecycle_record("r", stage)
  rec.update(over); return rec
 def test_8a_evidence_writer_emits_lf_only(self):
  from study01.evidence_io import write_text, write_lines
  with tempfile.TemporaryDirectory() as d:
   f=Path(d)/"a.txt"; write_text(f, "one\r\ntwo\rthree\n\n")
   self.assertEqual(f.read_bytes(), b"one\ntwo\nthree\n")
   write_lines(f, ["x\r\ny", "z"]); self.assertEqual(f.read_bytes(), b"x\ny\nz\n")
 def test_8b_capture_lifecycle_requires_every_step_in_order(self):
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  self.assertTrue(v(self.lifecycle()))
  with self.assertRaises(E): v(self.lifecycle(steps=good_steps()[:3]))
  shuffled=[good_steps()[i] for i in (1,0,2,3,4,5)]
  with self.assertRaises(E): v(self.lifecycle(steps=shuffled))
 def test_8c_capture_lifecycle_fails_closed_on_unproven_listening(self):
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  quiet=[dict(s, output="") if s["step"]=="listening-check" else dict(s) for s in good_steps()]
  with self.assertRaises(E): v(self.lifecycle(steps=quiet))
  wrong=self.lifecycle(interface="eth9")
  with self.assertRaises(E): v(wrong)
 def test_8d_capture_lifecycle_rejects_failed_step_and_drifted_frozen_values(self):
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  failed=[dict(s, exit_code=1) if s["step"]=="stop" else dict(s) for s in good_steps()]
  with self.assertRaises(E): v(self.lifecycle(steps=failed))
  with self.assertRaises(E): v(self.lifecycle(helper_image="corfr/tcpdump:latest"))
  with self.assertRaises(E): v(self.lifecycle(filter="host 10.0.0.1"))
  with self.assertRaises(E): v(self.lifecycle(helper_container_id=""))
 def test_8h_lifecycle_argv_is_bound_to_the_frozen_command(self):
  """A retained argv proves nothing unless it is the command the procedure fixes."""
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  from study01.frozen import apparatus as ap
  self.assertTrue(v(lifecycle_record("r","ground-truth")))
  def mutated(step, fn):
   rec=lifecycle_record("r","ground-truth")
   for s in rec["steps"]:
    if s["step"]==step: s["argv"]=fn(list(s["argv"]))
   return rec
  cases={
   "placeholder start argv": mutated("start", lambda a: ["docker","x"]),
   "wrong image":            mutated("start", lambda a: [x if x!=ap.CAPTURE_IMAGE else "corfr/tcpdump:latest" for x in a]),
   "wrong interface in argv":mutated("start", lambda a: [x if x!="eth3" else "eth9" for x in a]),
   "wrong filter":           mutated("start", lambda a: [x if x!=ap.CAPTURE_FILTER else "host 10.0.0.1" for x in a]),
   "wrong namespace":        mutated("start", lambda a: [x if not x.startswith("container:") else "container:zzz" for x in a]),
   "missing cap-add":        mutated("start", lambda a: [x for x in a if x!="NET_RAW"]),
   "logs of other helper":   mutated("listening-check", lambda a: ["docker","logs","someone-else"]),
   "stop of other helper":   mutated("stop", lambda a: ["docker","stop","someone-else"]),
   "remove of other helper": mutated("remove", lambda a: ["docker","container","rm","someone-else"]),
   "export wrong source":    mutated("export", lambda a: ["docker","cp","other:/data/x.pcap",a[3]]),
  }
  for label, rec in cases.items():
   with self.subTest(label), self.assertRaises(E): v(rec)
 def test_8i_export_destination_is_bound_to_the_executing_evidence_root(self):
  """Execution provenance, not the verifier's location, fixes the destination."""
  import os
  from study01 import capture_lifecycle as lc
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  executed=os.path.abspath(os.path.join(os.sep,"original","runs","r"))
  ok=lifecycle_record("r","sensor", run_root=executed)
  self.assertTrue(v(ok))
  dest=[s for s in ok["steps"] if s["step"]=="export"][0]["argv"][3]
  self.assertEqual(dest, lc.normalize_root(os.path.join(executed,"sensor-input","mirror-capture","c2-mirror-sensor.pcap")))
  def with_dest(d):
   rec=lifecycle_record("r","sensor", run_root=executed)
   for s in rec["steps"]:
    if s["step"]=="export": s["argv"][3]=d
   return rec
  # a different tree that merely shares the run ID and schema tail is rejected
  decoy=os.path.abspath(os.path.join(os.sep,"tmp","r","sensor-input","mirror-capture","c2-mirror-sensor.pcap"))
  with self.assertRaises(E): v(with_dest(lc.normalize_root(decoy)))
  # so are a bare schema suffix and another stage's artifact
  with self.assertRaises(E): v(with_dest(lc.normalize_root(
   os.path.join(os.sep,"sensor-input","mirror-capture","c2-mirror-sensor.pcap"))))
  with self.assertRaises(E): v(with_dest(lc.normalize_root(
   os.path.join(executed,"ground-truth","independent-capture","c2-original-path.pcap"))))
 def test_8i2_execution_run_root_must_be_absolute_canonical_and_this_run(self):
  import os
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  # inconsistent roots are caught because the export argv no longer matches
  for bad in (os.path.join("relative","r"), ""):
   rec=lifecycle_record("r","sensor"); rec["execution_run_root"]=bad
   with self.subTest(bad or "empty"), self.assertRaises(E): v(rec)
  # a fully self-consistent record whose root belongs to another run must still
  # fail: the argv agrees with itself, so only the run-ID binding catches it
  other=lifecycle_record("r","sensor", run_root=os.path.abspath(os.path.join(os.sep,"runs","other")))
  from study01 import capture_lifecycle as _lc
  export_step=next(s for s in other["steps"] if s["step"]=="export")
  self.assertEqual(export_step["argv"], _lc.expected_argv(other,"export"))
  with self.assertRaises(E) as cm: v(other)
  self.assertIn("run ID", str(cm.exception))
  # and a non-canonical spelling of the right root is rejected rather than guessed at
  messy=lifecycle_record("r","sensor", run_root=os.path.abspath(os.path.join(os.sep,"runs","r")))
  messy["execution_run_root"]=messy["execution_run_root"]+os.sep+"."
  with self.assertRaises(E): v(messy)
 def test_8i3_record_stays_verifiable_after_relocation(self):
  """A fresh checkout elsewhere must not invalidate execution provenance."""
  import os
  from study01.capture_lifecycle import validate as v
  executed=os.path.abspath(os.path.join(os.sep,"original","runs","r"))
  rec=lifecycle_record("r","sensor", run_root=executed)
  self.assertTrue(v(rec))  # validated from a machine that never had that path
 def test_8j_stage_identity_bindings_are_enforced(self):
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  from study01.frozen import apparatus as ap
  with self.assertRaises(E): v(lifecycle_record("r","sensor", interface="eth7"))   # sensor device is frozen
  self.assertTrue(v(lifecycle_record("r","ground-truth", interface="eth9")))        # GT device is runtime-resolved
  drifted=lifecycle_record("r","ground-truth"); drifted["helper_name"]="other-capture"
  with self.assertRaises(E): v(drifted)
  swapped=lifecycle_record("r","ground-truth"); swapped["namespace_service"]="tap_observer"
  with self.assertRaises(E): v(swapped)
  paths=lifecycle_record("r","ground-truth"); paths["artifact"]=ap.CAPTURE_STAGES["sensor"]["artifact"]
  with self.assertRaises(E): v(paths)
 def test_8k_window_coverage_is_decided_from_retained_timestamps(self):
  """013 asserted 35.18 s in prose; coverage must be recomputable from evidence."""
  from datetime import datetime, timedelta
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  t0=datetime.fromisoformat(T0_FIXTURE)
  self.assertTrue(v(lifecycle_record("r","ground-truth"), t0))
  def shifted(step, delta):
   rec=lifecycle_record("r","ground-truth")
   for s in rec["steps"]:
    if s["step"]==step: s["timestamp"]=(datetime.fromisoformat(s["timestamp"])+delta).isoformat()
   return rec
  # listening confirmed after the window opened -> not covered
  with self.assertRaises(E): v(shifted("listening-check", timedelta(seconds=16)), t0)
  # liveness observed before T0 + 15 s -> the far end is not proven
  with self.assertRaises(E): v(shifted("window-end-liveness-check", timedelta(seconds=-30)), t0)
  # exactly on the boundaries is covered
  rec=lifecycle_record("r","ground-truth")
  for s in rec["steps"]:
   if s["step"]=="listening-check":
    s["timestamp"]=(t0-timedelta(seconds=9)).isoformat(); s["completed_at"]=(t0-timedelta(seconds=5)).isoformat()
   if s["step"]=="window-end-liveness-check": s["timestamp"]=(t0+timedelta(seconds=15)).isoformat()
  self.assertTrue(v(rec, t0))
 def test_8o_listening_evidence_is_timed_by_command_completion(self):
  """The listening line only exists once `docker logs` returned."""
  from datetime import datetime, timedelta
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  t0=datetime.fromisoformat(T0_FIXTURE)
  # started well before the window opened, but the output only came back after:
  # the evidence is not proven to predate T0 - 5 s, so this must fail.
  straddling=lifecycle_record("r","ground-truth", listening_done=t0-timedelta(seconds=1))
  self.assertLess(datetime.fromisoformat(
   [s for s in straddling["steps"] if s["step"]=="listening-check"][0]["timestamp"]), t0-timedelta(seconds=5))
  with self.assertRaises(E) as cm: v(straddling, t0)
  self.assertIn("listening", str(cm.exception))
  # completion before the window opens is covered
  self.assertTrue(v(lifecycle_record("r","ground-truth", listening_done=t0-timedelta(seconds=6)), t0))
 def test_8q_window_end_requires_observed_liveness_not_a_late_stop(self):
  """A helper that died inside the window must not pass on stop timing alone."""
  from datetime import datetime, timedelta
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  t0=datetime.fromisoformat(T0_FIXTURE)
  # the exact scenario stop-timestamp reasoning could not exclude:
  # listening before the window, helper dead inside it, stop issued afterwards
  dead=lifecycle_record("r","ground-truth")
  for s in dead["steps"]:
   if s["step"]=="window-end-liveness-check":
    s["output"]="false"
  with self.assertRaises(E) as cm: v(dead, t0)
  self.assertIn("still running", str(cm.exception))
  # an empty or unparsed inspect result is not a liveness proof either
  for bogus in ("", "Error: No such object: r-ground-truth-capture", "TRUE-ish"):
   rec=lifecycle_record("r","ground-truth")
   for s in rec["steps"]:
    if s["step"]=="window-end-liveness-check": s["output"]=bogus
   with self.subTest(bogus or "empty"), self.assertRaises(E): v(rec, t0)
 def test_8r_stop_may_not_precede_the_liveness_observation(self):
  from datetime import datetime, timedelta
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  rec=lifecycle_record("r","ground-truth")
  for s in rec["steps"]:
   if s["step"]=="stop":
    s["timestamp"]=(datetime.fromisoformat(s["timestamp"])-timedelta(seconds=10)).isoformat()
    s["completed_at"]=(datetime.fromisoformat(s["completed_at"])-timedelta(seconds=10)).isoformat()
  with self.assertRaises(E) as cm: v(rec)
  self.assertIn("stopped before its liveness", str(cm.exception))
 def test_8s_capture_cli_fails_closed_when_the_helper_is_not_alive(self):
  """The CLI must refuse to export a capture that did not survive the window."""
  source=(ROOT/"study01_capture.py").read_text(encoding="utf-8")
  self.assertIn("window-end-liveness-check", source)
  self.assertIn("not running at the window end", source)
  # the liveness step must be executed before the helper is stopped
  self.assertIn('for step in ("window-end-liveness-check", "stop", "export", "remove"):', source)
 def test_8t_t0_must_be_the_sender_invocation_instant(self):
  """Cross-review counterexample: two independently valid but unrelated times."""
  from datetime import datetime, timedelta
  from study01.evidence_io import write_text
  from study01.evidence_tree import create as tree
  from study01.frozen import apparatus as ap
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"run"; tree(root)
   write_text(root/"metadata.md","m"); write_text(root/"deviations.md","dv")
   for name in RUNTIME_DIRS: write_text(root/name/"retained.txt","fixture")
   procedure_file(root); retention_artifacts(root)
   self.assertIsNone(validate(root))
   # the exact shape the reviewer flagged: sender says one instant, T0 another
   procedure_file(root, {**GOOD_PROCEDURE,
    "sender_invocations":[{"timestamp":"2026-08-24T11:32:09.249958+00:00","exit_code":0}]})
   with self.assertRaises(ValueError) as cm: validate(root)
   self.assertIn("sender invocation instant", str(cm.exception))
   # the same instant spelled differently is still the same instant
   other=(datetime.fromisoformat(T0_FIXTURE).astimezone(
    __import__("datetime").timezone(timedelta(hours=9)))).isoformat()
   self.assertNotEqual(other, T0_FIXTURE)
   procedure_file(root, {**GOOD_PROCEDURE,"sender_invocations":[{"timestamp":other,"exit_code":0}]})
   self.assertIsNone(validate(root))
   # more than one invocation is not a conformant run to anchor a window to
   procedure_file(root, {**GOOD_PROCEDURE,"invocation_count":2,"same_run_retry":True,
    "procedure_invalid":True,"invalid_reasons":["sender_invocation_count_not_one","same_run_retry"],
    "sender_invocations":[{"timestamp":T0_FIXTURE,"exit_code":0},{"timestamp":T0_FIXTURE,"exit_code":0}]})
   with self.assertRaises(ValueError): validate(root)
 def test_8u_lifecycle_timestamps_must_describe_a_possible_sequence(self):
  """Cross-review counterexample: start occurring after remove completed."""
  from datetime import datetime, timedelta
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  t0=datetime.fromisoformat(T0_FIXTURE)
  impossible=lifecycle_record("r","ground-truth")
  for s in impossible["steps"]:
   if s["step"]=="start":
    s["timestamp"]=(t0+timedelta(seconds=100)).isoformat()
    s["completed_at"]=(t0+timedelta(seconds=101)).isoformat()
  with self.assertRaises(E) as cm: v(impossible, t0)
  self.assertIn("timestamped before", str(cm.exception))
  # adjacent inversion anywhere in the chain is rejected
  for earlier, later in (("listening-check","window-end-liveness-check"),
                         ("window-end-liveness-check","stop"),("stop","export"),("export","remove")):
   rec=lifecycle_record("r","ground-truth")
   for s in rec["steps"]:
    if s["step"]==later:
     s["timestamp"]=(t0-timedelta(seconds=120)).isoformat()
     s["completed_at"]=(t0-timedelta(seconds=119)).isoformat()
   with self.subTest(f"{earlier}->{later}"), self.assertRaises(E): v(rec)
  # touching boundaries are allowed
  ok=lifecycle_record("r","ground-truth")
  for s in ok["steps"]:
   if s["step"]=="export": s["timestamp"]=[x for x in ok["steps"] if x["step"]=="stop"][0]["completed_at"]
  self.assertTrue(v(ok))
 def test_8v_runtime_helper_and_namespace_identity_must_be_proven(self):
  """Cross-review counterexample: a claimed ID unrelated to the start output."""
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  from study01 import capture_context as cc
  claimed=lifecycle_record("r","ground-truth")
  claimed["helper_container_id"]="claimed-id-unrelated-to-start-output"
  with self.assertRaises(E) as cm: v(claimed)
  self.assertIn("start command printed", str(cm.exception))
  # the namespace container and device must come from the retained resolutions
  ctx=context_record("r","ground-truth")
  self.assertTrue(v(lifecycle_record("r","ground-truth"), None, ctx))
  # self-consistent: the argv agrees with the drifted ID, so only the context catches it
  drifted=lifecycle_record("r","ground-truth", container="some-other-container")
  from study01 import capture_lifecycle as _lc
  self.assertEqual([s for s in drifted["steps"] if s["step"]=="start"][0]["argv"],
                   _lc.expected_argv(drifted,"start"))
  with self.assertRaises(E) as cm: v(drifted, None, ctx)
  self.assertIn("Compose query resolved", str(cm.exception))
  wrong_dev=lifecycle_record("r","ground-truth", interface="eth9")
  with self.assertRaises(E) as cm: v(wrong_dev, None, ctx)
  self.assertIn("interface resolution selected", str(cm.exception))
 def test_8w_capture_context_derives_every_value_from_retained_output(self):
  from study01.capture_context import CaptureContextError as E, validate as v
  from study01.frozen import apparatus as ap
  self.assertTrue(v(context_record("r","ground-truth"), "r"))
  self.assertTrue(v(context_record("r","sensor"), "r"))
  # the container ID must be what the Compose query printed.  Only the output is
  # changed, so every other field stays self-consistent and this check is the
  # one that has to catch it.
  rec=context_record("r","ground-truth"); rec["namespace_resolution"]["output"]="a-different-id"
  with self.assertRaises(E) as cm: v(rec, "r")
  self.assertIn("Compose query printed", str(cm.exception))
  # nor may the query have printed several IDs and one been chosen after the fact
  rec=context_record("r","ground-truth"); rec["namespace_resolution"]["output"]="def456\nextra-id"
  with self.assertRaises(E): v(rec, "r")
  # a non-unique gateway match may not be resolved to one device
  rec=context_record("r","ground-truth")
  rec["interface_resolution"]["output"]+=f"eth7@if12   UP   {ap.GATEWAY_CIDR}\n"
  rec["interface_resolution"]["matching_tokens"]=__import__("study01.capture_context",fromlist=["x"]).matching_tokens(rec["interface_resolution"]["output"])
  rec["interface_resolution"]["match_count"]=2
  with self.assertRaises(E) as cm: v(rec, "r")
  self.assertIn("unique match", str(cm.exception))
  # derived fields may not disagree with the retained output
  for field, value in (("match_count",5),("selected_token","eth9@if1"),("matching_tokens",[])):
   bad=context_record("r","ground-truth"); bad["interface_resolution"][field]=value
   with self.subTest(field), self.assertRaises(E): v(bad, "r")
  # the sensor device is frozen and takes no runtime resolution
  bad=context_record("r","sensor"); bad["normalized_interface"]="eth5"
  with self.assertRaises(E): v(bad, "r")
  bad=context_record("r","sensor"); bad["interface_resolution"]=context_record("r","ground-truth")["interface_resolution"]
  with self.assertRaises(E): v(bad, "r")
  # and the context must belong to this run
  with self.assertRaises(E): v(context_record("other","sensor"), "r")
 def test_8x_liveness_result_must_be_exactly_true(self):
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  for bogus in ("false\ntrue", "warning\ntrue", " true false"):
   rec=lifecycle_record("r","ground-truth")
   for s in rec["steps"]:
    if s["step"]=="window-end-liveness-check": s["output"]=bogus
   with self.subTest(bogus), self.assertRaises(E): v(rec)
 def test_8p_step_completion_cannot_precede_its_start(self):
  from datetime import datetime, timedelta
  from study01.capture_lifecycle import CaptureLifecycleError as E, validate as v
  rec=lifecycle_record("r","ground-truth")
  for s in rec["steps"]:
   if s["step"]=="stop":
    s["completed_at"]=(datetime.fromisoformat(s["timestamp"])-timedelta(seconds=5)).isoformat()
  with self.assertRaises(E): v(rec)
 def test_8l_collector_enforces_window_coverage_end_to_end(self):
  from datetime import datetime, timedelta
  from study01.evidence_io import write_text
  from study01.evidence_tree import create as tree
  from study01.frozen import apparatus as ap
  import hashlib
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"run"; tree(root)
   write_text(root/"metadata.md","m"); write_text(root/"deviations.md","d"); procedure_file(root)
   for name in RUNTIME_DIRS: write_text(root/name/"retained.txt","fixture")
   retention_artifacts(root)
   self.assertIsNone(validate(root))
   # move the whole invocation later, keeping T0 and the sender record in step,
   # so only the retained capture coverage becomes insufficient
   late=(datetime.fromisoformat(T0_FIXTURE)+timedelta(minutes=5)).isoformat()
   write_text(root/ap.T0_ARTIFACT, late)
   procedure_file(root, {**GOOD_PROCEDURE,"sender_invocations":[{"timestamp":late,"exit_code":0}]})
   with self.assertRaises(ValueError) as cm: validate(root)
   self.assertIn("window", str(cm.exception))
 def test_8m_capture_cli_cannot_drift_from_the_validated_command(self):
  """The CLI must derive every command from the same function validation checks."""
  source=(ROOT/"study01_capture.py").read_text(encoding="utf-8")
  code="\n".join(l for l in source.splitlines() if not l.strip().startswith("#"))
  self.assertTrue([l for l in code.splitlines() if "run_step(" in l], "the CLI executes no lifecycle step")
  # The only permitted source of an argv is the function validation checks against.
  self.assertNotIn('"docker"', code, "a hand-built docker argv would bypass argv validation")
  self.assertGreaterEqual(code.count("expected_argv"), 3)
  from study01 import capture_lifecycle as lc
  rec=lifecycle_record("r13","ground-truth")
  self.assertEqual(lc.expected_argv(rec,"start")[:4], ["docker","run","-d","--name"])
  self.assertIn("--cap-add", lc.expected_argv(rec,"start"))
 def test_8n_capture_cli_refuses_a_second_start_without_touching_docker(self):
  from study01.frozen import apparatus as ap
  from study01.evidence_io import write_text
  from study01.evidence_tree import create as tree
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"r13"; tree(root)
   spec=ap.CAPTURE_STAGES["ground-truth"]
   write_text(root/spec["lifecycle"], json.dumps(lifecycle_record("r13","ground-truth")))
   write_text(root/spec["context"], json.dumps(context_record("r13","ground-truth")))
   out=subprocess.run([sys.executable,str(ROOT/"study01_capture.py"),"start","--run-id","r13",
                       "--run-evidence",str(root),"--stage","ground-truth"],capture_output=True,text=True)
   self.assertNotEqual(out.returncode,0)
   self.assertIn("fresh run ID", out.stderr)
   mismatch=subprocess.run([sys.executable,str(ROOT/"study01_capture.py"),"start","--run-id","other",
                            "--run-evidence",str(root),"--stage","sensor"],capture_output=True,text=True)
   self.assertNotEqual(mismatch.returncode,0)
   self.assertIn("run ID must equal", mismatch.stderr)
 def test_8e_collector_requires_t0_and_lifecycle_primary_artifacts(self):
  from study01.frozen import apparatus as ap
  from study01.evidence_io import write_text
  from study01.evidence_tree import create as tree
  import hashlib
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"run"; tree(root)
   write_text(root/"metadata.md","m"); write_text(root/"deviations.md","d")
   procedure_file(root)
   for name in RUNTIME_DIRS: write_text(root/name/"retained.txt","fixture")
   # T0 missing -> fail; malformed -> fail; valid -> proceeds
   with self.assertRaises(ValueError): validate(root)
   write_text(root/ap.T0_ARTIFACT,"not-a-timestamp")
   with self.assertRaises(ValueError): validate(root)
   write_text(root/ap.T0_ARTIFACT,T0_FIXTURE)
   # lifecycle records still missing -> fail
   with self.assertRaises(ValueError): validate(root)
   for stage,spec in ap.CAPTURE_STAGES.items():
    art=root/spec["artifact"]; art.parent.mkdir(parents=True,exist_ok=True); art.write_bytes(b"\xd4\xc3\xb2\xa1pcap")
    rec=lifecycle_record(root.name, stage, pcap_sha=hashlib.sha256(art.read_bytes()).hexdigest(), run_root=root.resolve())
    write_text(root/spec["lifecycle"], json.dumps(rec))
    write_text(root/spec["context"], json.dumps(context_record(root.name, stage)))
   self.assertIsNone(validate(root))
   # a pcap that does not match its retained lifecycle hash fails closed
   (root/ap.CAPTURE_STAGES["sensor"]["artifact"]).write_bytes(b"tampered")
   with self.assertRaises(ValueError): validate(root)
 def test_8f_sender_wrapper_writes_t0_as_a_primary_artifact(self):
  from study01.frozen import apparatus as ap
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/"fresh-run"; (root/"ground-truth").mkdir(parents=True)
   cmd=[sys.executable,str(ROOT/"study01_sender.py"),"--run-id","fresh-run","--run-evidence",str(root),
        "--",sys.executable,"-c","print('sent')"]
   self.assertEqual(subprocess.run(cmd,capture_output=True,text=True).returncode,0)
   t0=(root/ap.T0_ARTIFACT)
   self.assertTrue(t0.is_file())
   self.assertEqual(t0.read_bytes(), t0.read_bytes().replace(b"\r\n",b"\n"))
   from datetime import datetime as dt
   dt.fromisoformat(t0.read_text().strip())
   rec=json.loads((root/"ground-truth"/"procedure-conformance.json").read_text())
   self.assertEqual(rec["sender_invocations"][0]["timestamp"], t0.read_text().strip())
   second=subprocess.run(cmd,capture_output=True,text=True)
   self.assertNotEqual(second.returncode,0)
 def test_8g_finalized_hashes_survive_a_real_git_commit_and_fresh_checkout(self):
  """The 013 blocker: verify-integrity must hold against repository bytes."""
  import hashlib, shutil
  from study01.frozen import apparatus as ap
  from study01.evidence_io import write_text
  from study01.evidence_tree import create as tree
  git=shutil.which("git")
  if not git: self.skipTest("git unavailable")
  with tempfile.TemporaryDirectory() as d:
   origin=Path(d)/"origin"; origin.mkdir()
   def run(*a, cwd): subprocess.run([git,*a],cwd=cwd,check=True,capture_output=True)
   run("init","-q","-b","main",cwd=origin)
   run("config","user.email","t@example.com",cwd=origin); run("config","user.name","t",cwd=origin)
   # the repository's real EOL policy is what broke 013
   (origin/".gitattributes").write_bytes((ROOT.parents[2]/".gitattributes").read_bytes())
   root=origin/"run"; tree(root)
   write_text(root/"metadata.md","meta\nline"); write_text(root/"deviations.md","dev")
   procedure_file(root); write_text(root/ap.T0_ARTIFACT,T0_FIXTURE)
   for name in RUNTIME_DIRS: write_text(root/name/"retained.txt","fixture\ntext")
   for stage,spec in ap.CAPTURE_STAGES.items():
    art=root/spec["artifact"]; art.parent.mkdir(parents=True,exist_ok=True); art.write_bytes(b"\xd4\xc3\xb2\xa1\r\n\r\npcap")
    rec=lifecycle_record(root.name, stage, pcap_sha=hashlib.sha256(art.read_bytes()).hexdigest(), run_root=root.resolve())
    write_text(root/spec["lifecycle"], json.dumps(rec,indent=2))
    write_text(root/spec["context"], json.dumps(context_record(root.name, stage),indent=2))
   subprocess.run([sys.executable,str(ROOT/"study01_collect.py"),"finalize-evidence",str(root)],check=True,capture_output=True)
   run("add","-A",cwd=origin); run("commit","-qm","evidence",cwd=origin)
   fresh=Path(d)/"fresh"
   subprocess.run([git,"clone","-q",str(origin),str(fresh)],check=True,capture_output=True)
   out=subprocess.run([sys.executable,str(ROOT/"study01_collect.py"),"verify-integrity",str(fresh/"run")],
                      capture_output=True,text=True)
   self.assertEqual(out.returncode,0, f"verify-integrity failed on a fresh checkout: {out.stderr}")
   self.assertEqual((fresh/"run"/ap.CAPTURE_STAGES["sensor"]["artifact"]).read_bytes(), b"\xd4\xc3\xb2\xa1\r\n\r\npcap",
                    "binary pcap bytes must survive the round trip unchanged")
if __name__ == "__main__": unittest.main()
