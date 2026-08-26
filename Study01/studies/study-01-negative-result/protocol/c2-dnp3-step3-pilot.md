# C2 DNP3 Step 3 — Rule Feasibility and Positive-Control Pilot

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation  
**Candidate:** C2 — DNP3  
**Status:** Pre-execution procedure  
**Prerequisites:** C2 Step 1 `Pass`; C2 Step 2 retry Ground Truth / sensor / collector `Pass`  
**Common procedure:** [Common Candidate Validation Procedure](./candidate-validation-common-procedure.md)  
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Purpose and boundary

This pilot tests whether C2 can preserve a rule-output artifact distinct from Ground Truth, sensor input, and collector output. It uses one positive control only. It does not establish a Study 01 Range A/B result, select C2, or interpret an alert absence.

```text
predeclared DNP3 event
  → Ground Truth
  → sensor input
  → collector document
  → zone-violation rule output
```

## 2. Fixed rule and positive control

| Item | Value |
| --- | --- |
| Rule identifier | `signal-1-zone-violation` |
| Rule source / loader | `scenarios/legacy-power-grid-signals/zone_violation.py`, mounted into `zone_detector` as `/app/plugins/signal-1-zone-violation.py` by the generated Compose file |
| Rule input | Newly observed DNP3 documents from `ot-logs-dnp3-*`, limited by the plugin to documents whose `layers.frame.frame_frame_protocols` contains `dnp3` |
| Rule condition | Alert when `layers.ip.ip_ip_src` is not in `ALLOWED_DNP3_SOURCES` |
| Fixed allowlist | `10.1.10.10,10.1.40.10` |
| Rule output | `ot-signals-zone-violation-*`; fields include `signal`, `src_ip`, `dst_ip`, `allowed_sources`, and `source_dnp3_doc_id` |
| Positive-control Host X / Asset Y | `sub_a_ied_02` (`10.1.20.11`) → `cc_scada_master` (`10.1.10.10`) |
| Positive-control event | One DNP3/TCP function-5 Direct Operate; link source `1024`, destination `1`; TCP `20000` |
| Positive-control rationale | `10.1.20.11` is not in the fixed allowlist, so the event is expected to produce a zone-violation document after the collector receives it. |

## 3. Required preserved artifacts

1. sender record plus original-path capture, using a `wan_router` interface resolved before capture from `10.1.20.254/24`;
2. `tap_observer` mirror-side sensor capture;
3. a collector query/response identifying the event by host pair, DNP3 function `5`, link source `1024`, and destination `1`;
4. `zone_detector` startup/log evidence showing the loaded allowlist and any emitted alert; and
5. a rule-output query/response identifying `signal-1-zone-violation`, source `10.1.20.11`, destination `10.1.10.10`, and the collector document identifier when present.

The exact original-path interface is runtime-specific. Resolve it by expected gateway IP, commit the result-free registration, and only then begin capture or trigger traffic.

## 4. Decision rules

| Stage | `Pass` | `Fail` / `Unresolved` |
| --- | --- | --- |
| Ground Truth | Sender record and original-path pcap match the predeclared request. | Required original-path evidence is absent, conflicting, or invalid. |
| Sensor input | Mirror-side pcap identifies the same request. | No matching sensor artifact. |
| Collector output | Preserved actual-schema response identifies the matching DNP3 document. | No matching collector document after the bounded settle window. |
| Rule output / positive control | Preserved output query identifies a zone-violation document for the event, and the rule artifact identifies the source document or an unambiguous matching tuple. | No output after the settle window, a nonmatching output, or output whose input cannot be tied to the collector artifact. |

Wait at least 15 seconds after the trigger before the final output query, because the sidecar polls at a five-second interval. Preserve an explicit query showing zero results if the expected rule output is absent; do not call an absent output a Study 01 negative result in this pilot.
