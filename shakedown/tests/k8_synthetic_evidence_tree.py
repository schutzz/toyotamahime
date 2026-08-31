#!/usr/bin/env python3
"""Build a synthetic Range A/B evidence tree that the FROZEN collector accepts.

Purpose (K8-S2 Batch 2 frozen-apparatus non-regression): C-4 adds
`*.observation.json` sidecars and C-5 adds axes to the observer records, both
INSIDE the run evidence tree. Those files are new bytes in a tree that
`study01_collect.py` validates, finalizes and verifies. This builder produces a
tree containing them so the regression suite can run the three frozen commands
against it for real, instead of reasoning about whether they would pass.

Every structural value below is taken from the frozen modules themselves
(`frozen/apparatus.py`, `capture_lifecycle.py`, `capture_context.py`), never
re-typed, so this fixture cannot drift away from what the frozen validator
actually requires.

RANGE C IS DELIBERATELY NOT BUILT HERE. The frozen collector hard-requires the
five runtime directories, metadata/deviations, procedure-conformance, T0 and
both capture stages' lifecycle/context records -- none of which a Range C
static validation has or should have. Growing fake runtime directories onto a
Range C fixture just to push it through the frozen collector would change what
Range C MEANS in order to make a test pass. Range C is covered by the C-6
stage-contract checks and its own C-4 observation checks instead.

This is a TEST FIXTURE. It is not a run, not evidence, and nothing it produces
is a Study 01 observation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


def frozen(scripts_dir: Path):
    scripts_dir = scripts_dir.resolve()
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))
    from study01 import capture_context, capture_lifecycle  # noqa: E402
    from study01.frozen import apparatus  # noqa: E402
    return apparatus, capture_lifecycle, capture_context


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def build_context(apparatus, capture_context, run_id, stage, container_id, base):
    """A capture-context record the frozen validator accepts."""
    spec = apparatus.CAPTURE_STAGES[stage]
    record = {
        "schema_version": capture_context.SCHEMA_VERSION,
        "run_id": run_id,
        "stage": stage,
        "namespace_service": spec["service"],
        "namespace_resolution": {
            "argv": capture_context.compose_argv(run_id, "compose.yml", spec["service"]),
            "output": container_id + "\n",
            "exit_code": 0,
        },
        "resolved_container_id": container_id,
        "interface_resolution": None,
        "normalized_interface": spec["interface"],
    }
    if spec["interface"] is None:
        # Ground Truth resolves its device at runtime from the frozen gateway
        # address, so the record must carry the resolution it followed from.
        token = "eth7@if42"
        output = (f"lo               UNKNOWN        127.0.0.1/8\n"
                  f"{token}       UP             {apparatus.GATEWAY_CIDR}\n")
        matching = capture_context.matching_tokens(output)
        record["interface_resolution"] = {
            "argv": capture_context.interface_argv(container_id),
            "output": output,
            "exit_code": 0,
            "matching_tokens": matching,
            "match_count": len(matching),
            "selected_token": matching[0].split()[0],
        }
        record["normalized_interface"] = capture_context.normalize_device(matching[0].split()[0])
    write_json(base / spec["context"], record)
    return record


def build_lifecycle(apparatus, capture_lifecycle, run_id, stage, container_id, base, t0, pcap_bytes):
    """A capture-lifecycle record the frozen validator accepts, covering the
    frozen [T0-5s, T0+15s] window."""
    spec = apparatus.CAPTURE_STAGES[stage]
    artifact = base / Path(spec["artifact"])
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_bytes(pcap_bytes)

    context = json.loads((base / spec["context"]).read_text(encoding="utf-8"))
    interface = context["normalized_interface"]
    helper_id = "c0ffee" + stage.replace("-", "")[:6]

    record = capture_lifecycle.new_record(run_id, stage, container_id, interface, str(base))
    record["helper_container_id"] = helper_id
    record["pcap_sha256"] = sha256_bytes(pcap_bytes)

    # Instants chosen so the frozen coverage rules hold: listening confirmed
    # before T0-5s, liveness observed at/after T0+15s, stop after that.
    schedule = {
        "start": (t0 - timedelta(seconds=30), t0 - timedelta(seconds=28)),
        "listening-check": (t0 - timedelta(seconds=20), t0 - timedelta(seconds=10)),
        "window-end-liveness-check": (t0 + timedelta(seconds=16), t0 + timedelta(seconds=17)),
        "stop": (t0 + timedelta(seconds=18), t0 + timedelta(seconds=19)),
        "export": (t0 + timedelta(seconds=20), t0 + timedelta(seconds=21)),
        "remove": (t0 + timedelta(seconds=22), t0 + timedelta(seconds=23)),
    }
    outputs = {
        "start": helper_id + "\n",
        "listening-check": f"tcpdump: listening on {interface}, link-type EN10MB\n",
        "window-end-liveness-check": "true\n",
        "stop": record["helper_name"] + "\n",
        "export": "",
        "remove": record["helper_name"] + "\n",
    }
    steps = []
    for name in capture_lifecycle.STEPS:
        started, completed = schedule[name]
        steps.append({
            "step": name,
            "argv": capture_lifecycle.expected_argv(record, name),
            "timestamp": iso(started),
            "completed_at": iso(completed),
            "exit_code": 0,
            "output": outputs[name],
        })
    record["steps"] = steps
    write_json(base / spec["lifecycle"], record)
    return record


def build(root: Path, run_id: str, range_key: str, scripts_dir: Path) -> None:
    apparatus, capture_lifecycle, capture_context = frozen(scripts_dir)
    base = root
    base.mkdir(parents=True, exist_ok=True)

    t0 = datetime(2026, 8, 31, 12, 0, 0, tzinfo=timezone.utc)

    for name in ("ground-truth", "sensor-input", "collector-output", "rule-output",
                 "contract-output", "environment"):
        (base / name).mkdir(parents=True, exist_ok=True)

    # --- Batch 1: the provenance mirror lives at the tree root ---------------
    write_json(base / "run-provenance.json", {
        "schema": "k8shakedown-run-provenance/1",
        "run_id": run_id,
        "range": range_key,
        "sequence_id": "k8shakedown-seq-synthetic",
        "tooling_head": "0" * 40,
        "tree_clean": True,
        "dirty_paths": [],
        "started_utc": iso(t0 - timedelta(minutes=5)),
        "tooling_repo_root": str(root),
        "sequence_locked_head": "0" * 40,
        "observation_point": "run-initialization",
    })

    # --- frozen procedure conformance + T0 ----------------------------------
    write_json(base / "ground-truth" / "procedure-conformance.json", {
        "schema_version": 2,
        "sender_invocations": [{"timestamp": iso(t0), "exit_code": 0}],
        "invocation_count": 1,
        "same_run_retry": False,
        "procedure_invalid": False,
        "invalid_reasons": [],
    })
    write_text(base / apparatus.T0_ARTIFACT, iso(t0))
    write_text(base / "ground-truth" / "sender-record.txt",
               f"argv=study01_sender.py --run-id {run_id}\nexit_code=0\n")

    # --- capture stages -----------------------------------------------------
    for index, stage in enumerate(apparatus.CAPTURE_STAGES):
        container_id = f"deadbeef{index:04d}"
        build_context(apparatus, capture_context, run_id, stage, container_id, base)
        build_lifecycle(apparatus, capture_lifecycle, run_id, stage, container_id, base, t0,
                        b"\xd4\xc3\xb2\xa1synthetic-" + stage.encode())
        spec = apparatus.CAPTURE_STAGES[stage]
        write_json(Path(base / spec["artifact"]).parent / "decoded-verification.json",
                   {"decoded_row_count": 1, "rows": [{"frame_number": "1"}]})

    # --- Collector / Rule, with the C-5 axes present ------------------------
    hits = {"hits": {"total": {"relation": "eq", "value": 1},
                     "hits": [{"_id": "doc-1", "_source": {"source_dnp3_doc_id": "doc-1"}}]}}
    write_json(base / "collector-output" / "collector-response.json", hits)
    write_json(base / "collector-output" / "collector-index-mapping.json", {"ot-logs-dnp3-000001": {}})
    write_json(base / "collector-output" / "collector-selector-mapping-gate.json", {
        "gate": "Collector selector exact-match mapping gate (ot-logs-dnp3-*)",
        "observer_status": "succeeded", "index_present": True, "evaluated_count": 8,
        "absence_admissible": False, "mapping_gate_pass": True, "decisions": [],
    })
    write_json(base / "collector-output" / "accepted-collector-hit-ids.json", ["doc-1"])
    write_json(base / "rule-output" / "rule-response.json",
               {"hits": {"total": {"relation": "eq", "value": 0}, "hits": []}})
    write_json(base / "rule-output" / "rule-index-mapping.json", {})
    write_json(base / "rule-output" / "rule-selector-mapping-gate.json", {
        "gate": "Rule selector exact-match mapping gate (signal/src_ip/dst_ip/source_dnp3_doc_id)",
        "observer_status": "succeeded", "index_present": False, "evaluated_count": 0,
        "absence_admissible": True, "mapping_gate_pass": True, "decisions": [],
    })
    write_json(base / "rule-output" / "collector-rule-correlation.json", {
        "mechanical_check": "complete frozen-selector Collector set to Rule source_dnp3_doc_id",
        "observer_status": "succeeded", "collector_hit_count": 1,
        "accepted_collector_hit_ids": ["doc-1"], "rule_hit_count": 0, "rule_correlations": [],
        "evaluated_count": 0, "correlation_applicable": False, "absence_admissible": True,
        "all_rule_hits_correlate": None,
        "all_rule_hits_correlate_note": "null means the predicate had no Rule hits to range over.",
    })

    # --- contract-output / environment --------------------------------------
    write_text(base / "contract-output" / "gateway-interface-resolution.txt", "interface=eth7\n")
    write_text(base / "contract-output" / "runtime-contract-record.md",
               f"# Runtime contract observational record -- {run_id}\n")
    write_json(base / "environment" / "image-inventory.json", {"services": []})
    write_json(base / "environment" / "collector-query.json", {"query": {}})
    write_json(base / "environment" / "rule-query.json", {"query": {}})

    if range_key == "b":
        build_range_b(base, run_id, t0)

    write_text(base / "metadata.md", f"# Run metadata -- {run_id} (synthetic test fixture)\n")
    write_text(base / "deviations.md", f"# Deviations -- {run_id}\n\nSynthetic fixture.\n")


def observation(label, argv, exit_code, when, stdout, stderr, containing):
    """A C-4 `separated` observation, byte-for-byte the shape the module writes."""
    def descriptor(text):
        data = text.encode("utf-8")
        return {"path": None, "bytes": len(data), "sha256": sha256_bytes(data),
                "empty": len(data) == 0}
    return {
        "label": label, "argv": list(argv), "exit_code": exit_code,
        "timestamp_utc": when, "capture_semantics": "separated",
        "containing_artifact": containing,
        "stdout": descriptor(stdout), "stderr": descriptor(stderr),
        "combined_output": None, "artifacts": None,
        "capture_note": "synthetic fixture",
    }


def build_range_b(base: Path, run_id: str, t0: datetime) -> None:
    contract = base / "contract-output"
    for name, label in (("qdisc-pre-fault", "pre-fault"),
                        ("fault-injection-command", "fault"),
                        ("qdisc-post-fault", "post-fault"),
                        ("unrelated-mirror-filters", "unrelated scan")):
        write_text(contract / f"{name}.txt", f"# {label}\nargv=docker exec r tc\nexit_code=0\n")
        # The C-4 sidecar: new bytes inside the tree the frozen collector will
        # validate, finalize and verify.
        write_json(contract / f"{name}.observation.json", {
            "schema": "k8shakedown-command-observation/1",
            "run_id": run_id, "range": "b",
            "producer": "synthetic", "stage": "fault-injection",
            "artifact": f"contract-output/{name}.txt",
            "observation_count": 1,
            "observations": [observation(label, ["docker", "exec", "r", "tc"], 0, iso(t0),
                                         "", "", f"contract-output/{name}.txt")],
        })

    write_json(contract / "r-obs-05-mapping-response.json", {"ot-logs-dnp3-000001": {}})
    write_json(contract / "r-obs-05-mapping-gate.json", {
        "gate": "R-OBS-05 exact mapping field/type gate",
        "observer_status": "succeeded", "index_present": True, "evaluated_count": 8,
        "absence_admissible": False, "mapping_gate_pass": True, "decisions": [],
    })
    write_json(base / "environment" / "r-obs-05-query.json", {"query": {}})
    write_json(contract / "r-obs-05-response.json",
               {"hits": {"total": {"relation": "eq", "value": 1}, "hits": [{"_id": "u-1"}]}})
    (contract / "r-obs-05-liveness.pcap").write_bytes(b"\xd4\xc3\xb2\xa1liveness")
    write_json(contract / "r-obs-05-capture-lifecycle.json", {"steps": []})
    write_json(contract / "r-obs-05-pcap-rows.json", [{"frame_number": "1"}])
    write_text(contract / "r-obs-05-liveness-decode.txt", "decoded_row_count=1\n")
    write_json(contract / "r-obs-05-correlation.json", {
        "r_obs_05_mechanical_gate_pass": True, "observer_status": "succeeded",
        "returned_document_ids": ["u-1"], "decoded_frame_count": 1,
        "evaluated_count": 1, "correlation_applicable": True,
        "absence_admissible": False, "r_obs_05_contract_outcome": None,
        "comparisons": [], "matching_pairs": [{"document_id": "u-1"}],
    })
    write_text(contract / "r-obs-05-contract-reference.txt",
               "protocol/k6-r-obs-05-collector-query-contract.md\nsha256=0\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--range", required=True, choices=("a", "b"))
    parser.add_argument("--scripts-dir", required=True, type=Path)
    args = parser.parse_args()
    root = args.root / args.run_id
    build(root, args.run_id, args.range, args.scripts_dir)
    print(str(root))


if __name__ == "__main__":
    main()
