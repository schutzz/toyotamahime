"""Structured, fail-closed sender-procedure conformance for a single run.

This is an executable transcription of the frozen sender procedure.  It does
not interpret ``deviations.md``; that file remains an audit narrative.

Scope is deliberately limited to what the sender execution path can establish
at the moment it sends: how many times it was invoked, with what exit code, and
whether it was a same-run retry.  Whether the selected DNP3 event actually
appeared on the wire is **not** recorded here.  That fact is a correlation of
the retained original-path pcap against the frozen selector, it cannot exist
until after the send and the settle window, and the Ground Truth stage already
derives it from that primary evidence.  Schema version 2 removed the field that
asked for it up front; see the sender procedure's pre-Pilot correction.
"""
from datetime import datetime

SCHEMA_VERSION = 2
INVALID_REASONS = {
    "sender_command_failure",
    "sender_invocation_count_not_one",
    "same_run_retry",
    "sender_placement_failure",
    "sender_source_address_failure",
    "sender_output_failure",
}


class ProcedureConformanceError(ValueError):
    """The retained machine-readable procedure record is absent or invalid."""


def _timestamp(value):
    if not isinstance(value, str):
        raise ProcedureConformanceError("invocation timestamp must be an RFC3339 string")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ProcedureConformanceError("invocation timestamp is not RFC3339") from exc


def validate(record):
    """Validate and return a normalized record; unknown states are rejected."""
    if not isinstance(record, dict) or set(record) != {
        "schema_version", "sender_invocations", "invocation_count", "same_run_retry",
        "procedure_invalid", "invalid_reasons",
    }:
        raise ProcedureConformanceError("procedure-conformance fields are incomplete or unknown")
    if record["schema_version"] != SCHEMA_VERSION:
        raise ProcedureConformanceError("unknown procedure-conformance schema version")
    attempts = record["sender_invocations"]
    if not isinstance(attempts, list) or not attempts:
        raise ProcedureConformanceError("sender_invocations must be a non-empty list")
    for attempt in attempts:
        if not isinstance(attempt, dict) or set(attempt) != {"timestamp", "exit_code"}:
            raise ProcedureConformanceError("sender invocation fields are incomplete or unknown")
        _timestamp(attempt["timestamp"])
        if type(attempt["exit_code"]) is not int:
            raise ProcedureConformanceError("sender invocation types are invalid")
    if type(record["invocation_count"]) is not int or record["invocation_count"] != len(attempts):
        raise ProcedureConformanceError("invocation_count does not match sender_invocations")
    if type(record["same_run_retry"]) is not bool or type(record["procedure_invalid"]) is not bool:
        raise ProcedureConformanceError("procedure-conformance boolean fields are invalid")
    reasons = record["invalid_reasons"]
    if not isinstance(reasons, list) or len(reasons) != len(set(reasons)) or not set(reasons) <= INVALID_REASONS:
        raise ProcedureConformanceError("invalid_reasons are invalid")

    derived = set()
    if any(item["exit_code"] != 0 for item in attempts):
        derived.add("sender_command_failure")
    if record["invocation_count"] != 1:
        derived.add("sender_invocation_count_not_one")
    if record["same_run_retry"]:
        derived.add("same_run_retry")
        if record["invocation_count"] < 2:
            raise ProcedureConformanceError("same_run_retry requires multiple invocations")
    if record["invocation_count"] > 1 and not record["same_run_retry"]:
        raise ProcedureConformanceError("multiple invocations require same_run_retry=true")
    if not derived <= set(reasons):
        raise ProcedureConformanceError("derived procedure-invalid reason is missing")
    if bool(reasons) != record["procedure_invalid"]:
        raise ProcedureConformanceError("procedure_invalid must agree with invalid_reasons")
    if not record["procedure_invalid"] and attempts[0]["exit_code"] != 0:
        raise ProcedureConformanceError("a conformant sender run requires one successful invocation")
    return record


def may_continue_same_run(record):
    """Execution wrappers must stop rather than repair/reuse an invalid run ID."""
    return not validate(record)["procedure_invalid"]
