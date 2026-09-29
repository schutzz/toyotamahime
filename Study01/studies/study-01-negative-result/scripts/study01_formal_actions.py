#!/usr/bin/env python3
"""Formal K8-3 mechanical actions promoted from qualified Shakedown mechanics.

This module intentionally owns no sequence/control-plane lifecycle and makes no
scientific verdict.  Each subcommand is invoked through Invoke-K8Step.ps1 and
only retains machine observations needed by the frozen Study01 procedures.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

from study01.es_query import request, resolve_container
from study01.evidence_io import write_text
from study01.frozen import apparatus


def run(argv, *, text=True, check=True):
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=text)
    if check and p.returncode != 0:
        raise RuntimeError(f"command failed ({p.returncode}): {argv!r}: {p.stderr if text else p.stderr!r}")
    return p


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    write_text(path, json.dumps(value, indent=2, ensure_ascii=False))


def json_values(raw):
    """Parse one array/object or concatenated/NDJSON Compose JSON values."""
    decoder=json.JSONDecoder(); values=[]; pos=0
    while pos < len(raw):
        while pos < len(raw) and raw[pos].isspace(): pos += 1
        if pos == len(raw): break
        value,pos = decoder.raw_decode(raw,pos)
        values.extend(value if isinstance(value,list) else [value])
    return values


def t0_window(root: Path):
    t0 = datetime.fromisoformat((root / apparatus.T0_ARTIFACT).read_text(encoding="utf-8").strip().replace("Z", "+00:00"))
    start = t0 - timedelta(seconds=apparatus.PRE_TRIGGER_GUARD_SECONDS)
    end = t0 + timedelta(seconds=apparatus.SETTLE_WINDOW_SECONDS)
    iso = lambda x: x.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    return iso(start), iso(end)


def log_structurer_ready(tshark, loader, canary_count, error):
    return tshark and loader and canary_count > 0 and error is None


PROCESS_PROBE = 'for p in /proc/[0-9]*/cmdline; do tr "\\0" " " < "$p" 2>/dev/null; printf "\\n"; done'
CANARY_QUERY = '{"size":3,"track_total_hits":true,"sort":[{"_doc":"desc"}],"query":{"bool":{"minimum_should_match":1,"should":[{"bool":{"filter":[{"term":{"layers.ip.ip_ip_src.keyword":"10.1.10.10"}},{"term":{"layers.ip.ip_ip_dst.keyword":"10.1.40.10"}},{"term":{"layers.tcp.tcp_tcp_dstport.keyword":"20000"}},{"terms":{"layers.dnp3.dnp3_dnp3_al_func.keyword":["1","5"]}},{"term":{"layers.dnp3.dnp3_dnp3_src.keyword":"1"}},{"term":{"layers.dnp3.dnp3_dnp3_dst.keyword":"20"}}]}},{"bool":{"filter":[{"term":{"layers.ip.ip_ip_src.keyword":"10.1.40.10"}},{"term":{"layers.ip.ip_ip_dst.keyword":"10.1.10.10"}},{"term":{"layers.tcp.tcp_tcp_srcport.keyword":"20000"}},{"term":{"layers.dnp3.dnp3_dnp3_al_func.keyword":"129"}},{"term":{"layers.dnp3.dnp3_dnp3_src.keyword":"20"}},{"term":{"layers.dnp3.dnp3_dnp3_dst.keyword":"1"}}]}}]}}}'
ZONE_SEARCH = '{"size":50,"sort":[{"_doc":"desc"}],"query":{"wildcard":{"layers.frame.frame_frame_protocols":"*dnp3*"}}}'


def wait_log_structurer(a, out):
    container=resolve_container(a.run_id,a.compose,"log_structurer"); attempts=[]; deadline=time.monotonic()+a.timeout_seconds
    es_container=resolve_container(a.run_id,a.compose,"elasticsearch")
    while time.monotonic() < deadline:
        dump=run(["docker","exec",container,"sh","-lc",PROCESS_PROBE],check=False)
        lines=dump.stdout.splitlines() if dump.returncode == 0 else []
        tshark=any("tshark" in x and "dnp3" in x for x in lines)
        loader=any("bulk_loader.py" in x and "dnp3" in x for x in lines)
        canary_count=0; error=None
        try:
            status,body=request(es_container,"POST","ot-logs-dnp3-*/_search",CANARY_QUERY); parsed=json.loads(body)
            if not status.startswith("2"): raise RuntimeError(f"HTTP {status}")
            hits=parsed["hits"]["hits"]; canary_count=int(parsed["hits"]["total"]["value"])
            for hit in hits:
                layers=hit["_source"]["layers"]
                if _scalar(layers["ip"]["ip_ip_src"]) == "10.1.20.11" and _scalar(layers["dnp3"]["dnp3_dnp3_al_func"]) == "5":
                    raise RuntimeError("operational canary matched the target scientific selector")
        except Exception as exc: error=str(exc)
        attempts.append({"tshark_dnp3_process_found":tshark,"bulk_loader_dnp3_process_found":loader,
                         "operational_canary_hit_count":canary_count,"operational_canary_query_error":error})
        if log_structurer_ready(tshark,loader,canary_count,error):
            write_json(out/"log-structurer-readiness.json",{"result":"PASS","container":container,"attempts":attempts}); return
        time.sleep(a.poll_seconds)
    write_json(out/"log-structurer-readiness.json",{"result":"TIMEOUT","container":container,"attempts":attempts})
    raise RuntimeError("log_structurer functional readiness timed out")


def wait_zone_detector(a, out):
    container=resolve_container(a.run_id,a.compose,"zone_detector"); attempts=[]; deadline=time.monotonic()+a.timeout_seconds
    while time.monotonic() < deadline:
        dump=run(["docker","exec",container,"sh","-lc",PROCESS_PROBE],check=False)
        plugin=any("python3" in x and "signal-1-zone-violation" in x for x in dump.stdout.splitlines()) if dump.returncode == 0 else False
        es_url=run(["docker","exec",container,"sh","-lc",'printf "%s" "${ES_URL:-http://elasticsearch:9200}"'],check=False).stdout or "http://elasticsearch:9200"
        probe=("import json,sys,urllib.request;" +
               f"r=urllib.request.urlopen('{es_url}/_cluster/health',timeout=5);" +
               "json.loads(r.read());sys.stdout.write(str(r.status))")
        conn=run(["docker","exec",container,"python3","-c",probe],check=False)
        connectivity=conn.returncode == 0 and conn.stdout.startswith("2")
        search_ok=False; search_result=None
        if connectivity:
            search=("import json,sys,urllib.request;" +
                    f"b={ZONE_SEARCH!r}.encode();r=urllib.request.urlopen(urllib.request.Request('{es_url}/ot-logs-dnp3-*/_search',data=b,headers={{'Content-Type':'application/json'}},method='POST'),timeout=5);" +
                    "json.loads(r.read());sys.stdout.write(str(r.status))")
            observed=run(["docker","exec",container,"python3","-c",search],check=False)
            search_result=observed.stdout; search_ok=observed.returncode == 0 and observed.stdout.startswith("2")
        attempts.append({"signal1_plugin_process_found":plugin,"es_url_used":es_url,
                         "zone_detector_to_es_connectivity_ok":connectivity,
                         "zone_detector_source_index_search_ok":search_ok,"zone_detector_source_index_search_result":search_result})
        if plugin and connectivity and search_ok:
            write_json(out/"zone-detector-readiness.json",{"result":"PASS","container":container,"attempts":attempts}); return
        time.sleep(a.poll_seconds)
    write_json(out/"zone-detector-readiness.json",{"result":"TIMEOUT","container":container,"attempts":attempts})
    raise RuntimeError("zone_detector functional readiness timed out")


def readiness(a):
    out = a.run_evidence / "environment"
    out.mkdir(parents=True, exist_ok=True)
    expected = set(run(["docker", "compose", "-p", a.run_id, "-f", str(a.compose), "config", "--services"]).stdout.split())
    if not expected: raise RuntimeError("Compose file declares no services")
    deadline=time.monotonic()+a.timeout_seconds; attempts=0; record=None
    while time.monotonic() < deadline:
        attempts += 1
        capture=run(["docker","compose","-p",a.run_id,"-f",str(a.compose),"ps","--all","--format","json"],check=False)
        try:
            rows=json_values(capture.stdout) if capture.returncode == 0 else []
            by_service={str(r.get("Service")):r for r in rows if r.get("Service")}
            missing=sorted(expected-set(by_service)); not_running=sorted(s for s in expected if s in by_service and by_service[s].get("State") != "running")
            not_healthy=sorted(s for s in expected if s in by_service and by_service[s].get("Health") not in (None,"","healthy"))
            ready=not missing and not not_running and not not_healthy
            record={"decision":"PASS" if ready else "WAIT","expected_services":sorted(expected),"missing":missing,
                    "not_running":not_running,"not_healthy":not_healthy,"poll_attempts":attempts,"raw_ps_output":capture.stdout}
            if ready: break
        except (json.JSONDecodeError,ValueError) as exc:
            record={"decision":"WAIT-PARSE","expected_services":sorted(expected),"parse_diagnostic":str(exc),"poll_attempts":attempts,"raw_ps_output":capture.stdout}
        time.sleep(a.poll_seconds)
    write_json(out / "compose-readiness.json", record)
    if not record or record["decision"] != "PASS": raise RuntimeError(f"Compose readiness timed out: {record}")
    container = resolve_container(a.run_id, a.compose)
    es_attempts=[]; es_ready=False; deadline=time.monotonic()+a.timeout_seconds
    while time.monotonic() < deadline:
        try:
            status,body=request(container,"GET","_cluster/health"); parsed=json.loads(body)
            es_attempts.append({"http_status":status,"cluster_status":parsed.get("status")})
            if status.startswith("2") and parsed.get("status") in {"yellow","green"}:
                es_ready=True
                break
        except Exception as exc: es_attempts.append({"error":str(exc)})
        time.sleep(a.poll_seconds)
    write_json(out/"elasticsearch-readiness.json",{"attempts":es_attempts,"ready":es_ready})
    if not es_ready: raise RuntimeError("Elasticsearch application readiness timed out")
    wait_log_structurer(a,out)
    wait_zone_detector(a,out)
    print("formal readiness: PASS")


def image_inventory(a):
    out = a.run_evidence / "environment" / "image-inventory.json"
    services = run(["docker", "compose", "-p", a.run_id, "-f", str(a.compose), "config", "--services"]).stdout.split()
    raw=run(["docker","compose","-p",a.run_id,"-f",str(a.compose),"images","--format","json"]).stdout
    (a.run_evidence/"environment"/"compose-images.json").write_text(raw,encoding="utf-8")
    image_rows=json_values(raw)
    rows = []
    for service in services:
        matches=[r for r in image_rows if r.get("Service")==service]
        if not matches:
            matches=[r for r in image_rows if service in str(r.get("ContainerName","")).replace("_","-").split("-")]
        if len(matches)!=1: raise RuntimeError(f"expected exactly one compose image row for {service}, got {len(matches)}")
        row=matches[0]; ref=row.get("ID") or (f"{row.get('Repository')}:{row.get('Tag')}" if row.get("Repository") and row.get("Tag") else None)
        if not ref: raise RuntimeError(f"image reference/ID missing for {service}")
        inspected=json.loads(run(["docker","image","inspect",ref]).stdout)
        if len(inspected)!=1 or not inspected[0].get("Id"): raise RuntimeError(f"immutable image Id missing for {service}")
        digests=sorted(inspected[0].get("RepoDigests") or [])
        rows.append({"service":service,"resolved_reference":ref,"image_id":inspected[0]["Id"],"repo_digests":digests,
                     "repo_digests_status":"present" if digests else "absent-local-build"})
    if len(rows)!=len(services): raise RuntimeError("image inventory is incomplete")
    write_json(out, {"schema": "study01-formal-image-inventory/1", "services": rows})
    print(f"formal image inventory: PASS ({len(rows)} services)")


def _scalar(v):
    return v[0] if isinstance(v, list) and len(v) == 1 else v


def _path(obj, dotted):
    for part in dotted.split("."):
        obj = obj[part]
    return _scalar(obj)


def _epoch_ns(value):
    return int(Decimal(str(value)) * Decimal(1_000_000_000))


def _iso_ns(value):
    dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    return int(Decimal(str(dt.timestamp())) * Decimal(1_000_000_000))


def robs05(a):
    out = a.run_evidence / "contract-output"
    out.mkdir(parents=True, exist_ok=True)
    start, end = t0_window(a.run_evidence)
    template = Path(__file__).parent / "study01" / "frozen" / "r-obs-05-query.template.json"
    body = template.read_text(encoding="utf-8").replace("<WINDOW_START>", start).replace("<WINDOW_END>", end)
    container = resolve_container(a.run_id, a.compose)
    mstatus, mbody = request(container, "GET", "ot-logs-dnp3-*/_mapping")
    write_text(out / "r-obs-05-mapping-response.json", mbody)
    if mstatus != "200":
        raise RuntimeError(f"R-OBS-05 mapping request returned HTTP {mstatus}")
    # Use the qualified stateless evidence checker, not the Shakedown lifecycle.
    # It enforces the exact field/type gate already exercised by K8-S2.
    qualified = Path(__file__).parents[4] / "shakedown" / "tools" / "k8_shakedown_evidence.py"
    mapping_gate = out / "r-obs-05-mapping-gate.json"
    run([sys.executable, str(qualified), "mapping-gate", "--mapping", str(out / "r-obs-05-mapping-response.json"), "--output", str(mapping_gate)])
    status, raw = request(container, "POST", "ot-logs-dnp3-*/_search", body)
    write_text(a.run_evidence / "environment" / "r-obs-05-query.json", body)
    write_text(out / "r-obs-05-response.json", raw)
    if status != "200":
        raise RuntimeError(f"R-OBS-05 search returned HTTP {status}")
    response = json.loads(raw)
    total = response.get("hits", {}).get("total", {})
    docs = response.get("hits", {}).get("hits", [])
    if total.get("relation") != "eq" or total.get("value") != len(docs) or len(docs) >= 10000:
        raise RuntimeError("R-OBS-05 response has an ambiguous/incomplete hit count")

    pcap = a.run_evidence / apparatus.AUXILIARY_CAPTURE_STAGES["robs05-liveness"]["artifact"]
    if not pcap.is_file():
        raise RuntimeError(f"R-OBS-05 liveness pcap missing: {pcap}")
    log_structurer = resolve_container(a.run_id, a.compose, "log_structurer")
    remote = f"/tmp/{a.run_id}-r-obs-05.pcap"
    run(["docker", "cp", str(pcap), f"{log_structurer}:{remote}"])
    display = "((ip.src==10.1.10.10 && ip.dst==10.1.40.10 && tcp.dstport==20000 && (dnp3.al.func==1 || dnp3.al.func==5) && dnp3.src==1 && dnp3.dst==20) || (ip.src==10.1.40.10 && ip.dst==10.1.10.10 && tcp.srcport==20000 && dnp3.al.func==129 && dnp3.src==20 && dnp3.dst==1))"
    fields = ["frame.number", "frame.time_epoch", "ip.src", "ip.dst", "tcp.srcport", "tcp.dstport", "dnp3.al.func", "dnp3.src", "dnp3.dst"]
    argv = ["docker", "exec", log_structurer, "tshark", "-r", remote, "-Y", display, "-T", "fields"]
    for f in fields: argv += ["-e", f]
    decoded = run(argv).stdout
    run(["docker", "exec", log_structurer, "rm", "-f", remote])
    write_text(out / "r-obs-05-liveness-decode.txt", decoded)
    frames = []
    for line in decoded.splitlines():
        c = line.split("\t")
        if len(c) != len(fields): raise RuntimeError(f"unexpected tshark row: {line}")
        frames.append(dict(zip(["frame_number","frame_time_epoch","ip_src","ip_dst","tcp_srcport","tcp_dstport","dnp3_al_func","dnp3_src","dnp3_dst"], c)))
    write_json(out / "r-obs-05-pcap-rows.json", frames)
    correlation = out / "r-obs-05-correlation.json"
    run([sys.executable, str(qualified), "r-obs-05", "--response", str(out / "r-obs-05-response.json"),
         "--frames", str(out / "r-obs-05-pcap-rows.json"), "--window-start", start, "--window-end", end,
         "--output", str(correlation)])
    print("R-OBS-05 mechanical observation: PASS")


def runtime_observation(a):
    root = a.run_evidence
    required = [
        "ground-truth/independent-capture/capture-lifecycle.json", "sensor-input/mirror-capture/capture-lifecycle.json",
        "collector-output/collector-response.json", "rule-output/rule-response.json",
    ]
    if a.range == "B": required += ["contract-output/r-obs-05-mapping-gate.json", "contract-output/r-obs-05-correlation.json"]
    ps_capture=run(["docker","compose","-p",a.run_id,"-f",str(a.compose),"ps","--all","--format","json"],check=False)
    write_text(root/"contract-output"/"runtime-compose-ps.json",ps_capture.stdout)
    if ps_capture.returncode: raise RuntimeError(f"runtime compose observation failed: {ps_capture.stderr}")
    services=json_values(ps_capture.stdout)
    if not services: raise RuntimeError("runtime compose observation returned no services")
    if a.range == "B":
        router=resolve_container(a.run_id,a.compose,"wan_router")
        addr=run(["docker","exec",router,"sh","-lc","ip -o -4 addr show"]).stdout
        matches=[line.split()[1] for line in addr.splitlines() if apparatus.GATEWAY_CIDR in line]
        if len(matches)!=1: raise RuntimeError(f"Range B gateway interface resolution returned {len(matches)} matches")
        iface=matches[0]
        qdisc=run(["docker","exec",router,"tc","qdisc","show","dev",iface]).stdout
        filters=run(["docker","exec",router,"tc","filter","show","dev",iface,"parent","ffff:"]).stdout
        write_text(root/"contract-output"/"qdisc-post-fault.txt",qdisc)
        write_text(root/"contract-output"/"unrelated-mirror-filters.txt",filters)
        zone=resolve_container(a.run_id,a.compose,"zone_detector")
        zone_running=run(["docker","inspect","--format","{{.State.Running}}",zone]).stdout.strip()
        write_json(root/"contract-output"/"range-b-nontriviality.json",{"gateway_interface":iface,"qdisc_output":qdisc,
                   "filter_output":filters,"zone_detector_container":zone,"zone_detector_running":zone_running})
        if zone_running != "true": raise RuntimeError("zone_detector is not running")
    rows = []
    for rel in required:
        path = root / rel
        rows.append({"path": rel, "present": path.is_file(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None})
    write_json(root / "contract-output" / "runtime-contract-observation.json",
               {"schema": "study01-runtime-contract-observation/1", "range": a.range, "artifacts": rows,
                "all_mechanical_inputs_present": all(x["present"] for x in rows),
                "verdict": None, "note": "Mechanical observation only; the operator authors the semantic verdict."})
    if not all(x["present"] for x in rows): raise RuntimeError("runtime-contract mechanical inputs are incomplete")
    print("runtime-contract mechanical observation retained; no verdict authored")


def finalize(a):
    script = Path(__file__).with_name("study01_collect.py")
    for command in ("validate-evidence", "finalize-evidence", "verify-integrity"):
        run([sys.executable, str(script), command, str(a.run_evidence)])
    manifest=a.run_evidence/"hashes.sha256"
    write_json(a.finalize_snapshot,{"schema":"k8shakedown-finalize-identity/1","run_id":a.run_evidence.name,
                                   "hashes_sha256_digest":hashlib.sha256(manifest.read_bytes()).hexdigest()})
    print("validate-evidence -> finalize-evidence -> verify-integrity: PASS")


def scoring_template(a):
    contract=Path(__file__).parents[4]/"shakedown"/"tools"/"k8_scoring_input_contract.py"
    run([sys.executable,str(contract),"emit-template","--range",a.range,"--output",str(a.output)])


def validate_scoring(a):
    contract=Path(__file__).parents[4]/"shakedown"/"tools"/"k8_scoring_input_contract.py"
    argv=[sys.executable,str(contract),"validate","--range",a.range,"--input",str(a.input),
          "--run-evidence",str(a.run_evidence),"--finalize-snapshot",str(a.finalize_snapshot)]
    if a.validation_report: argv += ["--output",str(a.validation_report)]
    run(argv)


def score(a):
    validate_scoring(a)
    script = Path(__file__).with_name("study01_score.py")
    run([sys.executable, str(script), str(a.input), "--run-evidence", str(a.run_evidence), "--output", str(a.output)])
    print(f"frozen scorer output retained: {a.output}")


def common(sub):
    sub.add_argument("--run-id", required=True); sub.add_argument("--compose", type=Path, required=True)
    sub.add_argument("--run-evidence", type=Path, required=True)


def main():
    p=argparse.ArgumentParser(); s=p.add_subparsers(dest="command",required=True)
    for name,func in (("readiness",readiness),("image-inventory",image_inventory),("r-obs-05",robs05)):
        q=s.add_parser(name); common(q); q.set_defaults(func=func)
        if name == "readiness": q.add_argument("--timeout-seconds",type=int,default=120); q.add_argument("--poll-seconds",type=int,default=3)
    q=s.add_parser("runtime-observation"); q.add_argument("--range",choices=("A","B"),required=True); q.add_argument("--run-id",required=True); q.add_argument("--compose",type=Path,required=True); q.add_argument("--run-evidence",type=Path,required=True); q.set_defaults(func=runtime_observation)
    q=s.add_parser("finalize"); q.add_argument("--run-evidence",type=Path,required=True); q.add_argument("--finalize-snapshot",type=Path,required=True); q.set_defaults(func=finalize)
    for name,func in (("scoring-template",scoring_template),("validate-scoring",validate_scoring),("score",score)):
        q=s.add_parser(name); q.add_argument("--range",choices=("A","B"),required=True); q.add_argument("--run-evidence",type=Path,required=True)
        if name != "scoring-template": q.add_argument("--input",type=Path,required=True)
        if name != "scoring-template": q.add_argument("--finalize-snapshot",type=Path,required=True)
        if name == "validate-scoring": q.add_argument("--validation-report",type=Path)
        else: q.set_defaults(validation_report=None)
        q.add_argument("--output",type=Path,required=name != "validate-scoring"); q.set_defaults(func=func)
    a=p.parse_args()
    try: a.func(a)
    except (RuntimeError, ValueError, KeyError, json.JSONDecodeError) as exc: p.error(str(exc))


if __name__ == "__main__": main()
