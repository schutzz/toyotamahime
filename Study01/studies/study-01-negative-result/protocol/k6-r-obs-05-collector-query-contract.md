# K6 R-OBS-05 Exact Collector Query Contract

**Status:** Pre-Main executable query contract; fixed before any K6 Main evidence exists.  
**Scope:** Range B R-OBS-05 unrelated-flow Collector liveness only. It does not replace or weaken the frozen target-event selector.

## 1. Meaning and boundary

R-OBS-05 already requires service health, an unrelated retained mirror filter/traffic, and nonempty applicable Collector evidence. This contract transcribes that existing requirement into one reproducible query and correlation decision.

The timestamp tolerance below does **not** change the meaning of R-OBS-05. It is an operational bound for executing the existing requirement that an unrelated frame and Collector document within the same frozen window describe the same flow event. It is fixed before Main evidence collection and may not be tuned after seeing K6 results.

This query produces liveness evidence only. Its hits may never satisfy the target-event Sensor/Collector stages, rule correlation, or target complete-selector query.

## 2. Fixed data source and mapping gate

| Item | Fixed value |
| --- | --- |
| Index pattern | `ot-logs-dnp3-*` |
| Event-time field | `layers.frame.frame_frame_time` (`date`) |
| Source IP | `layers.ip.ip_ip_src.keyword` |
| Destination IP | `layers.ip.ip_ip_dst.keyword` |
| TCP source/destination ports | `layers.tcp.tcp_tcp_srcport.keyword` / `layers.tcp.tcp_tcp_dstport.keyword` |
| DNP3 application function | `layers.dnp3.dnp3_dnp3_al_func.keyword` |
| DNP3 link source/destination | `layers.dnp3.dnp3_dnp3_src.keyword` / `layers.dnp3.dnp3_dnp3_dst.keyword` |
| Query window | `[T0 - 5 seconds, T0 + 15 seconds]`, inclusive |

Before the query, retain `GET ot-logs-dnp3-*/_mapping` and verify these actual fields/types. The K5 `003` mapping records `frame_frame_time` as `date` and selector fields as `text` with `keyword` subfields. Missing/type-drifted fields stop Range B interpretation; do not silently substitute a field or analyzer.

## 3. Exact bidirectional selector

The unrelated flow is the baseline DNP3 control traffic between `cc_scada_master` (`10.1.10.10`, link source `1`) and `sub_c_rtu` (`10.1.40.10`, link source `20`) over TCP/20000.

- Request direction: `10.1.10.10 -> 10.1.40.10`, TCP destination 20000, DNP3 function in `{1,5}`, link `1 -> 20`.
- Response direction: `10.1.40.10 -> 10.1.10.10`, TCP source 20000, DNP3 function `129`, link `20 -> 1`.

Instantiate `<WINDOW_START>` and `<WINDOW_END>` as RFC3339 UTC instants derived only from retained T0:

```json
{
  "size": 10000,
  "track_total_hits": true,
  "sort": [
    {"layers.frame.frame_frame_time": {"order": "asc"}}
  ],
  "query": {
    "bool": {
      "filter": [
        {
          "range": {
            "layers.frame.frame_frame_time": {
              "gte": "<WINDOW_START>",
              "lte": "<WINDOW_END>"
            }
          }
        },
        {
          "bool": {
            "minimum_should_match": 1,
            "should": [
              {
                "bool": {
                  "filter": [
                    {"term": {"layers.ip.ip_ip_src.keyword": "10.1.10.10"}},
                    {"term": {"layers.ip.ip_ip_dst.keyword": "10.1.40.10"}},
                    {"term": {"layers.tcp.tcp_tcp_dstport.keyword": "20000"}},
                    {"terms": {"layers.dnp3.dnp3_dnp3_al_func.keyword": ["1", "5"]}},
                    {"term": {"layers.dnp3.dnp3_dnp3_src.keyword": "1"}},
                    {"term": {"layers.dnp3.dnp3_dnp3_dst.keyword": "20"}}
                  ]
                }
              },
              {
                "bool": {
                  "filter": [
                    {"term": {"layers.ip.ip_ip_src.keyword": "10.1.40.10"}},
                    {"term": {"layers.ip.ip_ip_dst.keyword": "10.1.10.10"}},
                    {"term": {"layers.tcp.tcp_tcp_srcport.keyword": "20000"}},
                    {"term": {"layers.dnp3.dnp3_dnp3_al_func.keyword": "129"}},
                    {"term": {"layers.dnp3.dnp3_dnp3_src.keyword": "20"}},
                    {"term": {"layers.dnp3.dnp3_dnp3_dst.keyword": "1"}}
                  ]
                }
              }
            ]
          }
        }
      ]
    }
  }
}
```

Retain the instantiated request and full raw response. `hits.total.relation` must be `eq`, `hits.total.value` must equal the retained `hits` array length, and the value must be `1..9999`. The fixed background interval is 8 seconds, so fewer than four request/response cycles are expected in the 20-second window; 10000 is a deliberately non-binding ceiling. A zero total, `gte` relation, total/array mismatch, or total `>=10000` is `Unresolved`; do not choose a favorable page or invent ad hoc pagination.

## 4. Pcap-to-document correlation

At least one returned document must correlate to one decoded frame in the separate R-OBS-05 `tap_observer:eth0` liveness pcap:

1. both timestamps are inside the frozen window;
2. direction, source/destination IP, TCP service-port side, DNP3 function, and link source/destination are equal; and
3. the absolute difference between pcap `frame.time_epoch` and document `layers.frame.frame_frame_time` is **at most 1 millisecond**.

Use the embedded `frame_frame_time`, not the top-level `timestamp`, for correlation. Retain all candidate frames/documents and the computed differences; do not select one favorable item while omitting other hits.

The comparison is exact: parse both UTC timestamp decimals without binary floating point, normalize/pad the fractional component to integer nanoseconds, and evaluate `abs(pcap_ns - document_ns) <= 1_000_000`. Do not round either input or the delta. A delta of exactly 1,000,000 ns passes; 1,000,001 ns fails.

### Why ±1 ms

This value is fixed from pre-Main K5 evidence and stored precision, not from K6 outcomes:

- K5 Range A `016`: the target request is `1787648996.954202000` in the Sensor pcap and `1787648996.954199561` in the Collector document, a difference of approximately `0.002439 ms`.
- K5 Range B `003`: the same response packet is `1787650224.568185000` in the fixed Sensor pcap and `1787650224.568187000` in the auxiliary liveness pcap, a difference of `0.002 ms`.
- The Collector top-level `timestamp` is stored at millisecond precision, while the embedded frame time retains finer precision.

One millisecond is about 410 times the largest observed duplicate-capture/document delta, absorbs the known timestamp serialization/capture boundary, and remains orders of magnitude below the baseline 8-second poll interval. It is not a clock-skew allowance, ingestion-latency measurement, or permission to correlate different packets.

If no document/frame pair meets all three rules, R-OBS-05 is `Fail`; Amendment 002 normalizes Runtime Contract to `Unresolved` and the experiment to `Inconclusive experiment`. The tolerance must not be widened within that run.

## 5. Required retained artifacts

Under Range B `contract-output/`, retain:

- mapping response and mapping-gate decision;
- instantiated request JSON;
- full response JSON;
- decoded unrelated-flow pcap rows;
- correlation record listing every returned hit ID, matched/unmatched frame, compared fields, delta in milliseconds, and decision; and
- a contract SHA-256/reference identifying this exact file at the K6 start commit.

## 6. Amendment/rerun assessment

This prospective evidence/query envelope and numeric acceptance boundary are recorded as **AMEND-003**. Under `amendments.md`, the assigned category is **Rerun ASSESS / PARTIAL**. Assessment:

- K6 Main evidence count is zero, so there is no Main run to rerun, partially rerun, or reinterpret.
- K5 Pilot and candidate evidence remain historical apparatus/candidate records. This contract is not applied retroactively and none is rescored or promoted to Main evidence.
- The contract adds an executable query envelope and correlation record for an already-required R-OBS-05 fact. It does not change the unrelated flow, frozen window, target selector, Range B fault, R-OBS-05 meaning, scoring precedence, or classification.
- The concrete re-evaluation/partial-rerun set is empty because no K6 Main artifact exists. This outcome does not change the category to `Rerun NOT REQUIRED`.
- **Decision: AMEND-003 / Rerun ASSESS / PARTIAL; zero artifacts require actual rerun or partial rerun; prospective K6 use only.**
