#!/usr/bin/env python3
"""The required host-side execution path for one Pilot/Main sender invocation.

It deliberately owns only the invocation boundary: it refuses an existing run
record, retains stdout/stderr and writes the structured result once.  Placement,
capture, and pcap verification remain the canonical procedure's existing steps.

It records only what is established at send time -- the exit code and the single
invocation.  It does not accept or record whether the event was seen on the
wire: that correlation does not exist until after the send and the settle
window, and the Ground Truth stage derives it from the retained pcap.
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from study01.evidence_io import write_text
from study01.frozen import apparatus
from study01.procedure_conformance import SCHEMA_VERSION, ProcedureConformanceError, validate


def _existing_record_blocks(record_path):
    if not record_path.exists():
        return
    try:
        validate(json.loads(record_path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, ProcedureConformanceError) as exc:
        raise ProcedureConformanceError(f"existing procedure record is unsafe to reuse: {exc}") from exc
    raise ProcedureConformanceError("sender was already invoked for this run; retry requires a fresh run ID")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--run-id", required=True)
    p.add_argument("--run-evidence", type=Path, required=True)
    p.add_argument("command", nargs=argparse.REMAINDER)
    a = p.parse_args()
    if not a.command or a.command[0] != "--":
        p.error("pass the canonical sender command after --")
    command = a.command[1:]
    if not command:
        p.error("missing canonical sender command")
    root = a.run_evidence
    record = root / "ground-truth" / "procedure-conformance.json"
    sender_record = root / "ground-truth" / "sender-record.txt"
    t0_record = root / apparatus.T0_ARTIFACT
    try:
        if root.name != a.run_id:
            raise ProcedureConformanceError("run ID must equal the evidence directory name")
        _existing_record_blocks(record)
        if sender_record.exists():
            raise ProcedureConformanceError("sender record already exists; retry requires a fresh run ID")
        if t0_record.exists():
            raise ProcedureConformanceError("T0 already recorded for this run; retry requires a fresh run ID")
        # T0 is the frozen event window's origin, so it is taken here, immediately
        # before the invocation, and retained as its own primary artifact rather
        # than being transcribed into metadata prose afterwards.
        t0 = datetime.now(timezone.utc).isoformat()
        write_text(t0_record, t0)
        completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        write_text(sender_record, completed.stdout)
        structured = {
            "schema_version": SCHEMA_VERSION,
            "sender_invocations": [{
                "timestamp": t0,
                "exit_code": completed.returncode,
            }],
            "invocation_count": 1,
            "same_run_retry": False,
            "procedure_invalid": completed.returncode != 0,
            "invalid_reasons": ["sender_command_failure"] if completed.returncode != 0 else [],
        }
        validate(structured)
        write_text(record, json.dumps(structured, indent=2, sort_keys=True))
        sys.stdout.write(completed.stdout)
        if completed.returncode:
            p.error("sender failed; this retained Invalid run must close and retry requires a fresh run ID")
    except (OSError, ProcedureConformanceError) as exc:
        p.error(str(exc))


if __name__ == "__main__":
    main()
