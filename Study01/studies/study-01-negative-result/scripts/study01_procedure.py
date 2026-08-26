#!/usr/bin/env python3
"""Procedure-conformance guard for a host-side sender execution wrapper.

After every sender attempt, the wrapper updates the structured record and must
call ``guard-same-run`` before it can issue another sender invocation.
"""
import argparse
import json
from pathlib import Path

from study01.procedure_conformance import ProcedureConformanceError, may_continue_same_run, validate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "guard-same-run"))
    parser.add_argument("record", type=Path)
    args = parser.parse_args()
    try:
        record = json.loads(args.record.read_text(encoding="utf-8"))
        validate(record)
        if args.command == "guard-same-run" and not may_continue_same_run(record):
            parser.error("procedure-invalid run must close; retry requires a fresh run ID")
    except (OSError, json.JSONDecodeError, ProcedureConformanceError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
