#!/usr/bin/env python3
"""Mechanical Shakedown evidence checks; never assigns scientific scores."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


LIMIT_NS = 1_000_000

# ---------------------------------------------------------------------------
# C-5 legitimate-absence contract.
#
# An observer can end up with nothing to look at for reasons that are NOT
# interchangeable, and collapsing them is how a run silently turns "we never
# observed the thing" into "the thing was fine":
#
#   observer_status      did the OBSERVER work?  `succeeded` means it read the
#                        response and could say what is there -- including
#                        saying "nothing is there".  `malformed` means the
#                        response could not be evaluated at all, so nothing may
#                        be concluded from it in either direction.  There is
#                        deliberately no `failed`: acquisition and command
#                        failures are C-4 / C-1 territory and this module never
#                        produces one.
#   index_present /      WHAT was observed.  `null` only when the observer is
#   evaluated_count      `malformed`, never as a stand-in for "no".
#   absence_admissible   whether a frozen source PERMITS that absence.  This is
#                        a transcription of frozen policy, not a judgment made
#                        here, and it differs per observer (see below).
#   correlation_applicable /   whether a universal predicate had anything to
#   predicate result           range over.  A predicate over an EMPTY set is
#                              vacuously true as mathematics and says nothing
#                              as an observation, so it is recorded as `null`,
#                              never as `true`.
#
# EMPTY IS NOT MALFORMED.  An observer that correctly reports "this index does
# not exist" SUCCEEDED.  Whether that absence is acceptable is the separate
# `absence_admissible` axis.  Conflating the two would either excuse a frozen
# fail-close as "just a broken observer" or condemn a legitimate negative
# observation as a defect.
#
# Nothing here changes any fail-close: every case that stopped before still
# stops, in the same place, with the same effect. What changes is that the
# observation is RETAINED FIRST, so a stop is diagnosable instead of silent.
# ---------------------------------------------------------------------------
OBSERVER_SUCCEEDED = "succeeded"
OBSERVER_MALFORMED = "malformed"

# Per-observer transcription of frozen policy. Rule mapping: the
# ot-signals-zone-violation-* index is created LAZILY by zone_violation.py's
# first alert write, and no frozen Study 01 document requires it to exist, so
# its absence is a legitimate negative observation (see rule_mapping below).
# Collector and R-OBS-05 mapping: k6-r-obs-05-collector-query-contract.md SS2
# freezes the ot-logs-dnp3-* selector fields and the pre-T0 functional-
# readiness canary already guarantees that index exists, so absence there is a
# frozen fail-close and must NOT be relaxed into a "legitimate absence".
RULE_MAPPING_ABSENCE_ADMISSIBLE = True
COLLECTOR_MAPPING_ABSENCE_ADMISSIBLE = False
R_OBS_05_MAPPING_ABSENCE_ADMISSIBLE = False


def load(path: str):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write(path: str, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def get_path(value, dotted: str):
    if isinstance(value, dict) and dotted in value:
        return value[dotted]
    current = value
    for part in dotted.split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def scalar(value):
    if isinstance(value, list):
        return value[0] if value else None
    return value


def hits(response, *, require_nonempty: bool):
    block = response.get("hits", {})
    total = block.get("total")
    rows = block.get("hits")
    if not isinstance(total, dict) or total.get("relation") != "eq" or not isinstance(rows, list):
        raise ValueError("hits.total.relation must be eq and hits.hits must be an array")
    if total.get("value") != len(rows):
        raise ValueError("hits.total.value does not equal the retained hits array length")
    if len(rows) >= 10000:
        raise ValueError("retained hit count reached the fixed non-binding ceiling")
    if require_nonempty and not rows:
        raise ValueError("the fixed query returned zero hits")
    if any(not isinstance(row.get("_id"), str) or not row["_id"] for row in rows):
        raise ValueError("every retained hit must have a nonempty _id")
    return rows


def target(args):
    collector = hits(load(args.collector), require_nonempty=False)
    rules = hits(load(args.rule), require_nonempty=False)
    collector_ids = [row["_id"] for row in collector]
    collector_set = set(collector_ids)
    rule_rows = []
    for row in rules:
        source_id = scalar(get_path(row.get("_source", {}), "source_dnp3_doc_id"))
        rule_rows.append({"rule_id": row["_id"], "source_dnp3_doc_id": source_id,
                          "correlates_to_accepted_collector_hit": source_id in collector_set})
    # C5-R4, the vacuous-truth guard. `all([])` is True, so the previous
    # record answered "did every Rule hit correlate?" with `true` for a run
    # that returned NO Rule hits at all -- turning "we observed no
    # counterexample" into "we confirmed the correlation". Range B's frozen
    # expected Rule output is "No alert", so that empty case is the NORMAL
    # one, not a corner case. The predicate is now `null` when it had nothing
    # to range over, and `correlation_applicable` says so explicitly.
    correlation_applicable = bool(rule_rows)
    all_correlate = (all(row["correlates_to_accepted_collector_hit"] for row in rule_rows)
                     if correlation_applicable else None)
    write(args.output, {
        "mechanical_check": "complete frozen-selector Collector set to Rule source_dnp3_doc_id",
        "observer_status": OBSERVER_SUCCEEDED,
        "collector_hit_count": len(collector_ids),
        "accepted_collector_hit_ids": collector_ids,
        "rule_hit_count": len(rule_rows),
        "rule_correlations": rule_rows,
        "evaluated_count": len(rule_rows),
        "correlation_applicable": correlation_applicable,
        # An empty Rule hit set is a legitimate observation here: the Rule
        # index is lazily created and "No alert" is a frozen expected outcome.
        # It is the PREDICATE that becomes null, not the observation that
        # becomes a failure.
        "absence_admissible": True,
        "all_rule_hits_correlate": all_correlate,
        "all_rule_hits_correlate_note": (
            "null means the predicate had no Rule hits to range over. It is NOT "
            "an assertion that the correlation holds."),
    })
    # Independent mechanical verification, not just retention: the Rule
    # query itself now filters server-side on source_dnp3_doc_id.keyword IN
    # accepted_collector_hit_ids (frozen selector, freeze-decision-table.md
    # SS3), so every returned Rule hit correlating is an expected
    # CONSEQUENCE of that filter, not merely an observation. If it is ever
    # false, the filter did not do what it was built to do (a mapping/query
    # anomaly), and that must STOP here rather than surface later as a
    # silently wrong scoring-input transcription.
    if rule_rows and not all_correlate:
        raise ValueError("a retained Rule hit does not correlate to any accepted Collector hit -- the frozen Rule selector's source_dnp3_doc_id filter did not behave as built")


FIELDS = {
    "layers.frame.frame_frame_time": ("date", False),
    "layers.ip.ip_ip_src": ("text", True),
    "layers.ip.ip_ip_dst": ("text", True),
    "layers.tcp.tcp_tcp_srcport": ("text", True),
    "layers.tcp.tcp_tcp_dstport": ("text", True),
    "layers.dnp3.dnp3_dnp3_al_func": ("text", True),
    "layers.dnp3.dnp3_dnp3_src": ("text", True),
    "layers.dnp3.dnp3_dnp3_dst": ("text", True),
}

# Rule selector fields (freeze-decision-table.md SS3): `signal`, `src_ip`,
# `dst_ip`, `source_dnp3_doc_id`. Root cause this exists to fix (real VM
# run k8shakedown-rangea-20260829-084343): the Rule query used `term` on
# these fields directly, but the actual ot-signals-zone-violation-* mapping
# declares them `text` with a `.keyword` multi-field -- a `term` query
# against the analyzed `text` field itself does not reliably match the
# exact stored value, and the actual run's Rule stage silently came back
# "No alert" as a result. This gate mechanically verifies each field is
# exactly the expected `text`+`.keyword` shape BEFORE the Rule query is
# ever trusted, fail-closed on drift -- never a silent "No alert" caused by
# a mapping assumption that quietly stopped holding.
RULE_FIELDS = {
    "signal": ("text", True),
    "src_ip": ("text", True),
    "dst_ip": ("text", True),
    "source_dnp3_doc_id": ("text", True),
}


def mapping_field(properties, dotted):
    current = properties
    parts = dotted.split(".")
    for index, part in enumerate(parts):
        node = current.get(part) if isinstance(current, dict) else None
        if not isinstance(node, dict):
            return None
        if index == len(parts) - 1:
            return node
        current = node.get("properties")
    return None


def mapping_observation(gate_label, *, observer_status, index_present, evaluated_count,
                        absence_admissible, mapping_gate_pass, decisions):
    """The C-5 observer record. Written BEFORE any fail-close, so a stop is
    always accompanied by the observation that caused it."""
    return {
        "gate": gate_label,
        "observer_status": observer_status,
        "index_present": index_present,
        "evaluated_count": evaluated_count,
        "absence_admissible": absence_admissible,
        "mapping_gate_pass": mapping_gate_pass,
        "decisions": decisions,
    }


def mapping_gate(mapping_path: str, output_path: str, fields: dict, gate_label: str,
                 *, absence_admissible: bool):
    response = load(mapping_path)

    # MALFORMED: the observer could not evaluate the response at all, so it
    # cannot say whether an index is present. index_present/evaluated_count
    # stay null rather than being flattened to false/0 -- "unknown" is not
    # "no".
    if not isinstance(response, dict):
        write(output_path, mapping_observation(
            gate_label, observer_status=OBSERVER_MALFORMED, index_present=None,
            evaluated_count=None, absence_admissible=absence_admissible,
            mapping_gate_pass=False, decisions=[]))
        raise ValueError(
            f"{gate_label}: the mapping response could not be evaluated as an "
            "index->mapping object, so index presence is UNKNOWN, not absent")

    # EMPTY: the observer SUCCEEDED and correctly observed that no concrete
    # index matched. Whether that is acceptable is the separate admissibility
    # axis -- for the Rule gate it is (lazily created index); for the
    # Collector and R-OBS-05 gates it is a frozen fail-close and stays one.
    if not response:
        write(output_path, mapping_observation(
            gate_label, observer_status=OBSERVER_SUCCEEDED, index_present=False,
            evaluated_count=0, absence_admissible=absence_admissible,
            mapping_gate_pass=absence_admissible, decisions=[]))
        if absence_admissible:
            return
        raise ValueError(
            f"{gate_label}: mapping response contains no indices. The observer "
            "succeeded and this absence is real, but no frozen source permits it "
            "for this gate")

    decisions = []
    for index_name, index_value in response.items():
        properties = get_path(index_value, "mappings.properties")
        for field, (expected_type, needs_keyword) in fields.items():
            node = mapping_field(properties, field)
            ok = (isinstance(node, dict) and node.get("type") == expected_type and
                  (not needs_keyword or get_path(node, "fields.keyword.type") == "keyword"))
            decisions.append({"index": index_name, "field": field, "expected_type": expected_type,
                              "keyword_required": needs_keyword, "pass": ok})
    result = mapping_observation(
        gate_label, observer_status=OBSERVER_SUCCEEDED, index_present=True,
        evaluated_count=len(decisions), absence_admissible=absence_admissible,
        mapping_gate_pass=bool(decisions) and all(x["pass"] for x in decisions),
        decisions=decisions)
    write(output_path, result)
    if not result["mapping_gate_pass"]:
        raise ValueError(f"{gate_label}: mapping field/type drift detected")


def mapping(args):
    mapping_gate(args.mapping, args.output, FIELDS, "R-OBS-05 exact mapping field/type gate",
                 absence_admissible=R_OBS_05_MAPPING_ABSENCE_ADMISSIBLE)


def collector_mapping(args):
    mapping_gate(args.mapping, args.output, FIELDS, "Collector selector exact-match mapping gate (ot-logs-dnp3-*)",
                 absence_admissible=COLLECTOR_MAPPING_ABSENCE_ADMISSIBLE)


def rule_mapping(args):
    """
    Root cause this exists to fix (real VM run k8shakedown-rangeb-
    20260829-111026, closed, not rescued): confirmed against the pinned
    Amenonuboco source (78fc17746b5d663fafec9dffe563d79fe9ea02b7,
    scenarios/legacy-power-grid-signals/zone_violation.py) that the Rule
    alert index (ot-signals-zone-violation-*) is created LAZILY -- only by
    zone_violation.py's own `_bulk` write on its FIRST actual alert, inside
    an `if bulk_lines:` guard that is never entered when zero violations
    fire in a poll cycle. There is no startup-time index creation and no
    index template. A genuinely negative run -- Range B's own FROZEN,
    EXPECTED Rule output is "No alert" (scoring.md SS3) -- therefore has NO
    index to map at all, and Elasticsearch returns HTTP 200 with an empty
    `{}` body for a wildcard `_mapping` pattern that resolves to zero
    concrete indices. This is not an error and not a scientific finding:
    no frozen Study 01 document requires the Rule index to exist (unlike
    the Collector/R-OBS-05 ot-logs-dnp3-* mapping gate, which IS frozen by
    k6-r-obs-05-collector-query-contract.md SS2 and is deliberately left
    unaffected by this change -- that index is populated continuously by
    ALL structured traffic, not only alerts, and its existence is already
    guaranteed by the pre-T0 functional-readiness canary).

    Treating index-absence as a mapping-gate FAILURE made a genuine
    negative Rule observation impossible to ever complete -- a Shakedown
    observer defect introduced when this gate was added, not a runtime
    defect and not a frozen-procedure violation. An index that DOES exist
    but has a required field missing its `.keyword` multi-field remains a
    hard fail-close below: that is the actual defect class this gate
    exists to catch (see Invoke-K8AutomatedQueries's docstring for the
    original root cause).

    "Index absent" and "index present with 0 hits" are retained as
    distinguishable states (`index_present: false` vs. `true`) precisely
    so a later reader never conflates them into one undifferentiated
    "No alert" without knowing which one actually occurred.

    C-5 note: this gate's legitimate-absence case is no longer a separate
    code path with its own hand-written record. It is the SAME
    mapping_gate() as the Collector and R-OBS-05 gates, differing only by
    the `absence_admissible` constant above -- so the difference between
    the three observers is visible as frozen policy DATA rather than as
    divergent control flow that could drift apart. An index that DOES
    exist with a field/type drift still fails closed here exactly as
    before.
    """
    mapping_gate(args.mapping, args.output, RULE_FIELDS,
                 "Rule selector exact-match mapping gate (signal/src_ip/dst_ip/source_dnp3_doc_id)",
                 absence_admissible=RULE_MAPPING_ABSENCE_ADMISSIBLE)


DECIMAL = re.compile(r"^(?P<seconds>-?\d+)(?:\.(?P<fraction>\d{1,9}))?$")


def decimal_epoch_ns(value: str) -> int:
    match = DECIMAL.fullmatch(str(value).strip())
    if not match:
        raise ValueError(f"timestamp is not an exact decimal epoch with <=9 fractional digits: {value!r}")
    seconds = int(match.group("seconds"))
    fraction = (match.group("fraction") or "").ljust(9, "0")
    return seconds * 1_000_000_000 + int(fraction)


def iso_epoch_ns(value: str) -> int:
    match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(?:Z|\+00:00)", value)
    if not match:
        raise ValueError(f"document timestamp is not supported RFC3339 UTC: {value!r}")
    import calendar
    seconds = calendar.timegm(tuple(map(int, match.groups()[:6])) + (0, 0, 0))
    return seconds * 1_000_000_000 + int((match.group(7) or "").ljust(9, "0"))


def normalized(values):
    return tuple(str(scalar(v) or "") for v in values)


def document_tuple(row):
    source = row.get("_source", {})
    return normalized([
        get_path(source, "layers.ip.ip_ip_src"), get_path(source, "layers.ip.ip_ip_dst"),
        get_path(source, "layers.tcp.tcp_tcp_srcport"), get_path(source, "layers.tcp.tcp_tcp_dstport"),
        get_path(source, "layers.dnp3.dnp3_dnp3_al_func"), get_path(source, "layers.dnp3.dnp3_dnp3_src"),
        get_path(source, "layers.dnp3.dnp3_dnp3_dst"),
    ])


def robs_observation(*, observer_status, document_ids, decoded_frame_count,
                     evaluated_count, correlation_applicable, gate_pass,
                     contract_outcome, comparisons, matching_pairs):
    """The C-5 observer record for R-OBS-05.

    `r_obs_05_contract_outcome` carries ONLY the tokens the frozen contract
    itself names for the two absence cases -- SS3 "A zero total ... is
    `Unresolved`" and SS4 "If no document/frame pair meets all three rules,
    R-OBS-05 is `Fail`". It is null on the passing path: deriving a `Pass`
    would be this tooling authoring a scientific judgment, which it must not
    do. It is also NOT a scoring field: `Unresolved` in particular has no
    frozen scoring propagation (see k8_scoring_input_contract.py), so it is
    retained here as an observation and resolved by the operator.
    """
    return {
        "r_obs_05_mechanical_gate_pass": gate_pass,
        "observer_status": observer_status,
        "returned_document_ids": document_ids,
        "decoded_frame_count": decoded_frame_count,
        "evaluated_count": evaluated_count,
        "correlation_applicable": correlation_applicable,
        # Frozen: SS1 requires "nonempty applicable Collector evidence" and SS3
        # makes a zero total `Unresolved`. Absence is never admissible here.
        "absence_admissible": False,
        "r_obs_05_contract_outcome": contract_outcome,
        "comparisons": comparisons,
        "matching_pairs": matching_pairs,
    }


def robs(args):
    # Every fail-close below RETAINS the observation first. Previously a
    # zero-hit response or an unevaluable frame set raised before anything was
    # written, so the run stopped with no record of WHICH absence occurred --
    # the diagnostic gap C-5 exists to close. The stops themselves are
    # unchanged.
    try:
        documents = hits(load(args.response), require_nonempty=False)
    except ValueError:
        write(args.output, robs_observation(
            observer_status=OBSERVER_MALFORMED, document_ids=None,
            decoded_frame_count=None, evaluated_count=None,
            correlation_applicable=None, gate_pass=False,
            contract_outcome=None, comparisons=[], matching_pairs=[]))
        raise
    if not documents:
        write(args.output, robs_observation(
            observer_status=OBSERVER_SUCCEEDED, document_ids=[],
            decoded_frame_count=None, evaluated_count=0,
            correlation_applicable=False, gate_pass=False,
            contract_outcome="Unresolved", comparisons=[], matching_pairs=[]))
        raise ValueError("the fixed query returned zero hits")
    document_ids = [row["_id"] for row in documents]
    frames = load(args.frames)
    if not isinstance(frames, list):
        write(args.output, robs_observation(
            observer_status=OBSERVER_MALFORMED, document_ids=document_ids,
            decoded_frame_count=None, evaluated_count=None,
            correlation_applicable=None, gate_pass=False,
            contract_outcome=None, comparisons=[], matching_pairs=[]))
        raise ValueError("decoded unrelated-flow pcap rows are not an array")
    if not frames:
        write(args.output, robs_observation(
            observer_status=OBSERVER_SUCCEEDED, document_ids=document_ids,
            decoded_frame_count=0, evaluated_count=0,
            correlation_applicable=False, gate_pass=False,
            contract_outcome=None, comparisons=[], matching_pairs=[]))
        raise ValueError("decoded unrelated-flow pcap rows are empty")
    window_start_ns = iso_epoch_ns(args.window_start)
    window_end_ns = iso_epoch_ns(args.window_end)
    pairs = []
    matching_pairs = []
    for document in documents:
        source = document.get("_source", {})
        document_time = scalar(get_path(source, "layers.frame.frame_frame_time"))
        document_ns = iso_epoch_ns(str(document_time))
        document_in_window = window_start_ns <= document_ns <= window_end_ns
        dt = document_tuple(document)
        for frame in frames:
            ft = normalized([frame.get("ip_src"), frame.get("ip_dst"), frame.get("tcp_srcport"),
                             frame.get("tcp_dstport"), frame.get("dnp3_al_func"), frame.get("dnp3_src"),
                             frame.get("dnp3_dst")])
            frame_ns = decimal_epoch_ns(str(frame.get("frame_time_epoch")))
            frame_in_window = window_start_ns <= frame_ns <= window_end_ns
            delta = abs(frame_ns - document_ns)
            record = {"document_id": document["_id"], "frame_number": frame.get("frame_number"),
                      "document_in_window": document_in_window, "frame_in_window": frame_in_window,
                      "fields_equal": dt == ft, "delta_ns": delta, "within_1000000_ns": delta <= LIMIT_NS,
                      "correlates": document_in_window and frame_in_window and dt == ft and delta <= LIMIT_NS}
            pairs.append(record)
            if record["correlates"]:
                matching_pairs.append(record)
    gate_pass = bool(matching_pairs)
    result = robs_observation(
        observer_status=OBSERVER_SUCCEEDED, document_ids=document_ids,
        decoded_frame_count=len(frames), evaluated_count=len(pairs),
        correlation_applicable=bool(pairs), gate_pass=gate_pass,
        # SS4: "If no document/frame pair meets all three rules, R-OBS-05 is
        # `Fail`." Null on the passing path -- the tooling does not author a Pass.
        contract_outcome=(None if gate_pass else "Fail"),
        comparisons=pairs, matching_pairs=matching_pairs)
    write(args.output, result)
    if not gate_pass:
        raise ValueError("no unrelated-flow pcap/document pair met exact fields and <=1,000,000 ns")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("target-correlation")
    p.add_argument("--collector", required=True); p.add_argument("--rule", required=True); p.add_argument("--output", required=True)
    p.set_defaults(func=target)
    p = sub.add_parser("mapping-gate")
    p.add_argument("--mapping", required=True); p.add_argument("--output", required=True); p.set_defaults(func=mapping)
    p = sub.add_parser("collector-mapping-gate")
    p.add_argument("--mapping", required=True); p.add_argument("--output", required=True); p.set_defaults(func=collector_mapping)
    p = sub.add_parser("rule-mapping-gate")
    p.add_argument("--mapping", required=True); p.add_argument("--output", required=True); p.set_defaults(func=rule_mapping)
    p = sub.add_parser("r-obs-05")
    p.add_argument("--response", required=True); p.add_argument("--frames", required=True)
    p.add_argument("--window-start", required=True); p.add_argument("--window-end", required=True); p.add_argument("--output", required=True)
    p.set_defaults(func=robs)
    args = parser.parse_args(); args.func(args)


if __name__ == "__main__":
    main()
