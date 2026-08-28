#!/usr/bin/env python3
"""Mechanical Shakedown evidence checks; never assigns scientific scores."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


LIMIT_NS = 1_000_000


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
    write(args.output, {
        "mechanical_check": "complete frozen-selector Collector set to Rule source_dnp3_doc_id",
        "collector_hit_count": len(collector_ids),
        "accepted_collector_hit_ids": collector_ids,
        "rule_hit_count": len(rule_rows),
        "rule_correlations": rule_rows,
        "all_rule_hits_correlate": all(row["correlates_to_accepted_collector_hit"] for row in rule_rows),
    })


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


def mapping(args):
    response = load(args.mapping)
    if not response:
        raise ValueError("mapping response contains no indices")
    decisions = []
    for index_name, index_value in response.items():
        properties = get_path(index_value, "mappings.properties")
        for field, (expected_type, needs_keyword) in FIELDS.items():
            node = mapping_field(properties, field)
            ok = (isinstance(node, dict) and node.get("type") == expected_type and
                  (not needs_keyword or get_path(node, "fields.keyword.type") == "keyword"))
            decisions.append({"index": index_name, "field": field, "expected_type": expected_type,
                              "keyword_required": needs_keyword, "pass": ok})
    result = {"mapping_gate_pass": bool(decisions) and all(x["pass"] for x in decisions),
              "decisions": decisions}
    write(args.output, result)
    if not result["mapping_gate_pass"]:
        raise ValueError("R-OBS-05 mapping field/type drift detected")


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


def robs(args):
    documents = hits(load(args.response), require_nonempty=True)
    frames = load(args.frames)
    if not isinstance(frames, list) or not frames:
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
    result = {"r_obs_05_mechanical_gate_pass": bool(matching_pairs),
              "returned_document_ids": [row["_id"] for row in documents],
              "decoded_frame_count": len(frames), "comparisons": pairs, "matching_pairs": matching_pairs}
    write(args.output, result)
    if not result["r_obs_05_mechanical_gate_pass"]:
        raise ValueError("no unrelated-flow pcap/document pair met exact fields and <=1,000,000 ns")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("target-correlation")
    p.add_argument("--collector", required=True); p.add_argument("--rule", required=True); p.add_argument("--output", required=True)
    p.set_defaults(func=target)
    p = sub.add_parser("mapping-gate")
    p.add_argument("--mapping", required=True); p.add_argument("--output", required=True); p.set_defaults(func=mapping)
    p = sub.add_parser("r-obs-05")
    p.add_argument("--response", required=True); p.add_argument("--frames", required=True)
    p.add_argument("--window-start", required=True); p.add_argument("--window-end", required=True); p.add_argument("--output", required=True)
    p.set_defaults(func=robs)
    args = parser.parse_args(); args.func(args)


if __name__ == "__main__":
    main()
