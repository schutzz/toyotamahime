#!/usr/bin/env python3
"""The required execution path for one capture helper's whole lifecycle.

`start` launches the helper and confirms it is listening; `stop-export` first
confirms the helper is still running -- which is what proves the far end of the
frozen window was covered -- then stops it, exports its pcap to the schema
destination, and removes it.  Run `stop-export` only after `T0 + 15 s`.  Both retain the
exact argv, exit code, output, and timestamp of every command, so capture
procedure §5's primary records exist as evidence rather than as prose an
operator has to remember to write.
"""
import argparse
import json
import time
from pathlib import Path

from study01 import capture_context as context
from study01 import capture_lifecycle as lifecycle
from study01.frozen import apparatus


def _stage_paths(run_evidence, stage):
    spec = apparatus.CAPTURE_STAGES[stage]
    return run_evidence / spec["lifecycle"], run_evidence / spec["artifact"], spec


def resolve(a):
    """Retain the runtime resolutions the helper's frozen argv will carry."""
    spec = apparatus.CAPTURE_STAGES[a.stage]
    path = a.run_evidence / spec["context"]
    if path.exists():
        raise context.CaptureContextError("a capture-context already exists; retry requires a fresh run ID")
    ns = lifecycle.run_step("start", context.compose_argv(a.run_id, a.compose, spec["service"]))
    resolution = {"argv": ns["argv"], "output": ns["output"], "exit_code": ns["exit_code"]}
    resolved = ns["output"].strip().splitlines()[-1].strip() if ns["output"].strip() else ""
    record = {"schema_version": context.SCHEMA_VERSION, "run_id": a.run_id, "stage": a.stage,
              "namespace_service": spec["service"], "namespace_resolution": resolution,
              "resolved_container_id": resolved, "interface_resolution": None,
              "normalized_interface": spec["interface"]}
    if spec["interface"] is None:
        iface = lifecycle.run_step("start", context.interface_argv(resolved))
        found = context.matching_tokens(iface["output"])
        token = found[0].split()[0] if len(found) == 1 and found[0].split() else ""
        record["interface_resolution"] = {
            "argv": iface["argv"], "output": iface["output"], "exit_code": iface["exit_code"],
            "matching_tokens": found, "match_count": len(found), "selected_token": token}
        record["normalized_interface"] = context.normalize_device(token)
    path.parent.mkdir(parents=True, exist_ok=True)
    context.write(path, record)
    context.validate(record, a.run_id)
    print(f"[resolve] {a.stage}: container {record['resolved_container_id']}, "
          f"device {record['normalized_interface']}; context retained at {path}")


def start(a):
    record_path, _, spec = _stage_paths(a.run_evidence, a.stage)
    if record_path.exists():
        raise lifecycle.CaptureLifecycleError("a lifecycle record already exists; retry requires a fresh run ID")
    context_path = a.run_evidence / spec["context"]
    if not context_path.is_file():
        raise context.CaptureContextError("run `resolve` first; the helper's runtime values must be retained")
    ctx = context.validate(json.loads(context_path.read_text(encoding="utf-8")), a.run_id)
    record = lifecycle.new_record(a.run_id, a.stage, ctx["resolved_container_id"],
                                  ctx["normalized_interface"], a.run_evidence)
    interface = ctx["normalized_interface"]
    # The command is derived from the same function validation checks against,
    # so the retained argv cannot drift from the frozen one.
    started = lifecycle.run_step("start", lifecycle.expected_argv(record, "start"))
    record["steps"].append(started)
    if started["exit_code"] != 0:
        lifecycle.write(record_path, record)
        raise lifecycle.CaptureLifecycleError(f"helper start failed; retained record at {record_path}")
    record["helper_container_id"] = started["output"].strip().splitlines()[-1].strip()

    time.sleep(a.settle)
    check = lifecycle.run_step("listening-check", lifecycle.expected_argv(record, "listening-check"))
    record["steps"].append(check)
    lifecycle.write(record_path, record)
    if f"listening on {interface}" not in check["output"]:
        raise lifecycle.CaptureLifecycleError(
            "helper did not confirm listening; do not trigger, and retry with a fresh run ID")
    print(f"[start] {record['helper_name']} listening on {interface}; lifecycle retained at {record_path}")


def stop_export(a):
    record_path, artifact, spec = _stage_paths(a.run_evidence, a.stage)
    if not record_path.exists():
        raise lifecycle.CaptureLifecycleError("no lifecycle record from start; nothing to stop")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    if record.get("execution_run_root") != lifecycle.normalize_root(a.run_evidence):
        raise lifecycle.CaptureLifecycleError(
            "the evidence tree moved since start; the retained export destination would not match")
    if any(s["step"] in ("window-end-liveness-check", "stop", "export", "remove") for s in record["steps"]):
        raise lifecycle.CaptureLifecycleError("this helper was already stopped; retry requires a fresh run ID")
    artifact.parent.mkdir(parents=True, exist_ok=True)
    for step in ("window-end-liveness-check", "stop", "export", "remove"):
        result = lifecycle.run_step(step, lifecycle.expected_argv(record, step))
        record["steps"].append(result)
        lifecycle.write(record_path, record)
        if result["exit_code"] != 0:
            raise lifecycle.CaptureLifecycleError(f"lifecycle step {step} failed; retained record at {record_path}")
        if step == "window-end-liveness-check" and result["output"].strip().splitlines()[-1:] != ["true"]:
            raise lifecycle.CaptureLifecycleError(
                "the helper was not running at the window end; the capture did not cover it "
                f"and this run must close. Retained record at {record_path}")
    if not artifact.is_file():
        raise lifecycle.CaptureLifecycleError(f"export did not produce {artifact}")
    record["pcap_sha256"] = lifecycle.pcap_sha256(artifact)
    lifecycle.validate(record)
    lifecycle.write(record_path, record)
    print(f"[stop-export] {artifact.name} exported, sha256={record['pcap_sha256']}")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="command", required=True)
    for name, handler in (("resolve", resolve), ("start", start), ("stop-export", stop_export)):
        s = sub.add_parser(name)
        s.add_argument("--run-id", required=True)
        s.add_argument("--run-evidence", type=Path, required=True)
        s.add_argument("--stage", choices=tuple(apparatus.CAPTURE_STAGES), required=True)
        s.set_defaults(handler=handler)
        if name == "resolve":
            s.add_argument("--compose", type=Path, required=True, help="the generated Range A/B Compose file")
        if name == "start":
            s.add_argument("--settle", type=float, default=4.0, help="seconds to wait before the listening check")
    a = p.parse_args()
    a.run_evidence = a.run_evidence.resolve()
    if a.run_evidence.name != a.run_id:
        p.error("run ID must equal the evidence directory name")
    try:
        a.handler(a)
    except (OSError, json.JSONDecodeError, lifecycle.CaptureLifecycleError,
            context.CaptureContextError) as exc:
        p.error(str(exc))


if __name__ == "__main__":
    main()
