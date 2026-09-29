#!/usr/bin/env python3
"""The literal, executable Range A/B target-event Collector and Rule queries.

Formal K8-3 correction basis: freeze-decision-table.md §3 and evidence-schema.md
§3 fix the frozen selectors, index patterns, and required retained artifacts
for the Collector and Rule stages, but published no literal, executable query
an operator could run without synthesizing one -- the same class of
executable-transcription gap already fixed once for the Range A/B pcap decode
command (c2-dnp3-capture-procedure.md §5.2) and once for Range C's execution
authority (README §5.3). Formal K8-3 attempt `k8-repro-20260929-001` found
this gap at the Collector/Rule step -- after Range A's provisioning through
pcap decode verification had already passed -- and closed Failed rather than
synthesizing a query from outside knowledge, per README §7.

This script promotes the already-qualified
`shakedown/tools/collector-query.template.json` and `rule-query.template.json`
-- byte-for-byte, now shipped under `study01/frozen/` -- and the
docker-exec-curl-into-the-elasticsearch-container mechanism
`shakedown/tools/K8ShakedownCommon.psm1`'s `Invoke-K8ElasticsearchRequest`
already used, into the formal Study01 package. See
protocol/c2-dnp3-collector-rule-query-procedure.md for the literal commands
and retained-artifact paths.

It changes no frozen event, selector, window, index pattern, evidence-schema
path, or scoring rule. A well-formed response with zero matching hits is not
a script failure: `study01_score.py` classifies the run, not this script --
see README §6.1 (Range B's Collector/Rule stages are *expected* to fail).
This script only fails closed on a transport or apparatus-level anomaly: the
Elasticsearch container could not be resolved, a non-200 HTTP status, an
unparseable response body, or (for the Collector stage) a `hits.total` that
is not a clean, unambiguous count.
"""
import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from study01.es_query import ElasticsearchRequestError, request, resolve_container
from study01.evidence_io import write_text
from study01.frozen import apparatus


def _read_t0(run_evidence):
    t0_path = run_evidence / apparatus.T0_ARTIFACT
    if not t0_path.exists():
        raise SystemExit(f"{t0_path} does not exist; run the sender procedure before querying")
    return datetime.fromisoformat(t0_path.read_text(encoding="utf-8").strip())


def _window(t0):
    """freeze-decision-table.md §3: [T0 - 5 s, T0 + 15 s], as RFC3339 UTC instants."""
    start = t0 - timedelta(seconds=apparatus.PRE_TRIGGER_GUARD_SECONDS)
    end = t0 + timedelta(seconds=apparatus.SETTLE_WINDOW_SECONDS)
    return (start.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            end.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"))


def _run_search(run_id, compose, index_pattern, body_text, out_dir, prefix):
    out_dir.mkdir(parents=True, exist_ok=True)
    container = resolve_container(run_id, compose)
    http_status, raw_body = request(container, "POST", f"{index_pattern}/_search", body_text)
    write_text(out_dir / f"{prefix}-query.json", body_text)
    write_text(out_dir / f"{prefix}-response.json", raw_body)
    write_text(out_dir / f"{prefix}-http-status.txt", http_status)
    if http_status != "200":
        raise SystemExit(f"{prefix} query returned HTTP {http_status}, not 200: {raw_body[:500]}")
    try:
        return json.loads(raw_body)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{prefix} response was not valid JSON: {exc}") from exc


def cmd_collector(a):
    run_evidence = a.run_evidence
    out_dir = run_evidence / "collector-output"
    window_start, window_end = _window(_read_t0(run_evidence))
    body = (apparatus.COLLECTOR_QUERY_TEMPLATE.read_text(encoding="utf-8")
            .replace("<WINDOW_START>", window_start).replace("<WINDOW_END>", window_end))
    parsed = _run_search(a.run_id, a.compose, apparatus.COLLECTOR_INDEX_PATTERN, body, out_dir, "collector")

    total = parsed.get("hits", {}).get("total", {})
    hits = parsed.get("hits", {}).get("hits", [])
    hit_ids = sorted(h["_id"] for h in hits)
    write_text(out_dir / "accepted-collector-hit-ids.json", json.dumps(hit_ids, indent=2))

    if total.get("relation") != "eq" or total.get("value") != len(hits) or total.get("value", 0) >= 10000:
        raise SystemExit(
            "collector query response is not a clean, unambiguous count "
            f"(freeze-decision-table.md §3): total={total!r}, retained hits={len(hits)}"
        )
    print(f"[collector] window [{window_start}, {window_end}]: "
          f"{len(hits)} hit(s) matching the complete frozen selector")
    print(f"[collector] {'PASS' if hits else 'Fail'}: accepted hit IDs retained at "
          f"{out_dir / 'accepted-collector-hit-ids.json'}: {hit_ids}")


def cmd_rule(a):
    run_evidence = a.run_evidence
    out_dir = run_evidence / "rule-output"
    collector_ids_path = run_evidence / "collector-output" / "accepted-collector-hit-ids.json"
    if not collector_ids_path.exists():
        raise SystemExit(f"{collector_ids_path} does not exist; run the collector query before the rule query")
    accepted_ids = json.loads(collector_ids_path.read_text(encoding="utf-8"))

    window_start, window_end = _window(_read_t0(run_evidence))
    body = (apparatus.RULE_QUERY_TEMPLATE.read_text(encoding="utf-8")
            .replace("<WINDOW_START>", window_start).replace("<WINDOW_END>", window_end)
            .replace('"<COLLECTOR_HIT_IDS_JSON>"', json.dumps(accepted_ids)))
    parsed = _run_search(a.run_id, a.compose, apparatus.RULE_INDEX_PATTERN, body, out_dir, "rule")

    hits = parsed.get("hits", {}).get("hits", [])
    correlated = [h["_id"] for h in hits if h.get("_source", {}).get("source_dnp3_doc_id") in accepted_ids]
    print(f"[rule] window [{window_start}, {window_end}]: {len(hits)} hit(s), "
          f"{len(correlated)} correlated to an accepted Collector hit ID via source_dnp3_doc_id")
    if not hits:
        print("[rule] No alert: zero matching rule documents in the frozen window.")
    elif correlated:
        print(f"[rule] PASS: {len(correlated)} rule hit(s) correlated to an accepted Collector hit ID")
    else:
        print("[rule] hit(s) returned, but none correlate via source_dnp3_doc_id to an accepted Collector hit ID")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="stage", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--run-id", required=True)
    common.add_argument("--run-evidence", type=Path, required=True)
    common.add_argument("--compose", type=Path, required=True)

    sub.add_parser("collector", parents=[common],
                    help="query ot-logs-dnp3-* for the frozen target-event selector").set_defaults(func=cmd_collector)
    sub.add_parser("rule", parents=[common],
                    help="query ot-signals-zone-violation-* and correlate against accepted Collector hit IDs").set_defaults(func=cmd_rule)

    a = p.parse_args()
    try:
        a.func(a)
    except ElasticsearchRequestError as exc:
        p.error(str(exc))


if __name__ == "__main__":
    main()
