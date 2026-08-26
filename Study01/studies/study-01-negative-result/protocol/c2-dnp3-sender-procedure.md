# Study 01 — C2 DNP3 Canonical Sender Procedure

**Status:** K3 pre-freeze canonical procedure, with a formal K5 pre-Pilot executable correction for directory preparation

This is the single canonical procedure for sending the C2 event. It fixes packaging and invocation only; the C2 event semantics remain those demonstrated by the candidate evidence.

## 0. Canonical execution shell

| Field | Frozen value |
| --- | --- |
| Canonical execution shell | **PowerShell 7** |
| Unsupported for Pilot/Main | Git Bash / MSYS |

Every command block in this document is PowerShell. Git Bash and MSYS rewrite bare in-container paths such as `/study/traffic/send_direct_operate.py` into a Windows path before `docker` receives them. In attempt `k5-range-a-20260824-009` this produced a sender invocation that exited `2` without opening a socket, and the same-run retry that followed is what made that run an **Invalid run**. The [execution preflight](./c2-dnp3-range-derivation.md#23-execution-preflight-gate) probes this rewrite directly and refuses to let such a host provision a run.

## 1. Canonical asset and provenance

| Field | Frozen value |
| --- | --- |
| Kakuriyo asset | `studies/study-01-negative-result/experiments/shared/traffic/send_direct_operate.py` |
| Baseline source | `scenarios/legacy-power-grid-signals/dnp3_zone_attack.py` at Amenonuboco `78fc17746b5d663fafec9dffe563d79fe9ea02b7` |
| Baseline source SHA-256 | `B71D4F4985A97905E75762B40B533CF8F0F96C530D918A239D3F090A2F64B863` |
| Kakuriyo canonical-copy SHA-256 | `093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B` |
| Canonical copy relation | Retained, version-controlled Study-specific reproduction copy; it does not add a platform capability or an additional attack behavior. |
| Sender service | `sub_a_ied_02` |
| In-container placement | `/study/traffic/send_direct_operate.py` |

The asset’s copied frame construction and sender behavior are semantically equivalent to the listed baseline source: one TCP connection sends one DNP3 frame whose link addresses are destination `1` and source `1024`. The Study copy’s final informational stderr sentence is intentionally a local provenance clarification; the success line, socket behavior, payload construction, arguments, and exit behavior used as the sender predicate are unchanged.

## 2. Frozen event and invocation

For each run, create `T0` immediately before the command in the run metadata and execute exactly one event:

```text
python3 /study/traffic/send_direct_operate.py \
  --target-ip 10.1.10.10 \
  --target-port 20000 \
  --function-code 5 \
  --repeat 1
```

This means source `10.1.20.11` (`sub_a_ied_02`) → destination `10.1.10.10:20000` (`cc_scada_master`), DNP3 application function `5`, link source `1024`, link destination `1`, and one trigger event per run. A retry is a new run ID; it must not extend or overwrite the original run.

## 3. Reproducible placement and execution

### 3.1 Formal pre-Pilot correction basis — directory preparation

K5-3 attempt `k5-range-a-20260824-005` established that a fresh `sub_a_ied_02` container does not provide the frozen destination directory `/study/traffic`. Independent cross-review classified this as **B — sender-placement provenance / executable-procedure gap**, not a change to the selected event, Ground Truth definition, selector, event window, exactly-once rule, scoring, or Runtime Contract.

The candidate Step 1 record proves a prior exploratory execution of `dnp3_zone_attack.py` from `/tmp`; it does not prove that `/tmp` is the Pilot/Main canonical placement. Before the K3 freeze, this procedure intentionally fixed the version-controlled Kakuriyo asset, `docker cp`, and `/study/traffic/send_direct_operate.py`. Those frozen values remain unchanged. The missing step was only the directory preparation required to make that fixed destination available.

| Correction decision | Fixed outcome |
| --- | --- |
| Classification | Formal pre-Pilot executable correction; no research-semantic change |
| Canonical asset / SHA-256 | Unchanged asset and hash; corrected host source path: `studies/study-01-negative-result/experiments/shared/traffic/send_direct_operate.py` / `093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B` |
| Placement mechanism / destination | Unchanged: `docker cp` to `/study/traffic/send_direct_operate.py` |
| Added prerequisite | `mkdir -p /study/traffic` inside the Compose-resolved sender container |
| Amendment | Not required; this correction supplies an omitted execution precondition and does not alter research semantics |
| Researcher degrees of freedom | Closed: no alternate asset, path, placement mechanism, or argv is permitted |

### 3.1b Formal pre-Pilot correction basis — sender-record scope

K5-3 attempt `k5-range-a-20260825-012` passed the execution preflight 12/12, provisioned, resolved the gateway interface, and started both capture helpers, then stopped at this step. `study01_sender.py` required `--network-event-observed` as an argument supplied **before** it ran the sender command, but that value names the correlation of the retained original-path pcap against the frozen selector — a fact that cannot exist until after the send and after the `T0 + 15 s` settle window. The argument could not be supplied truthfully on a first invocation.

It was also not fail-safe. An optimistic `true` that proved wrong would record `procedure_invalid: false`, so a genuine correlation failure would reach the scorer as `Ground Truth = Fail` and classify as `Inconclusive experiment` rather than `Invalid run`.

| Correction decision | Fixed outcome |
| --- | --- |
| Classification | Formal pre-Pilot executable correction; no research-semantic change |
| Sender record scope | Limited to what the execution path establishes at send time: invocation count, exit code, same-run retry |
| Removed | The `--network-event-observed` argument, the per-invocation `network_event_observed` field, and the `sender_pcap_correlation_failure` reason (`procedure-conformance` schema version 1 → 2) |
| Event/correlation authority | Unchanged in substance and returned to its correct stage: the Ground Truth stage derives it from the retained pcap and the frozen selector, as §4 already requires |
| Exactly-once and retry rules | Unchanged; `009`'s shape (exit `2` → procedure Invalid → same-run reinvocation refused) is fully preserved without the removed field |
| Migration | None required: no retained run had produced a `procedure-conformance.json`, so no result-bearing evidence is reinterpreted |
| Amendment | Not required; the selected event, Ground Truth definition, exactly-once rule, fresh-run retry rule, and scoring precedence are all unchanged. Only which component records a fact, and when, has changed. |

### 3.2 Fixed placement, verification, and execution order

The generated Compose path and project name are supplied by the [Range derivation and cleanup procedure](./c2-dnp3-range-derivation.md). Before any capture or trigger, resolve the sender container through Compose rather than assuming a Docker-generated name:

```powershell
$sender = docker compose -p <run-id> -f <range-a-or-b-compose.yml> ps -q sub_a_ied_02
if ([string]::IsNullOrWhiteSpace($sender)) { throw 'sub_a_ied_02 container was not resolved' }
docker compose -p <run-id> -f <range-a-or-b-compose.yml> exec -T sub_a_ied_02 sh -lc 'mkdir -p /study/traffic'
if ($LASTEXITCODE -ne 0) { throw "sender directory preparation exited $LASTEXITCODE" }
docker cp studies/study-01-negative-result/experiments/shared/traffic/send_direct_operate.py "${sender}:/study/traffic/send_direct_operate.py"
if ($LASTEXITCODE -ne 0) { throw "sender placement exited $LASTEXITCODE" }
$inContainerSha = (docker compose -p <run-id> -f <range-a-or-b-compose.yml> exec -T sub_a_ied_02 sh -lc 'sha256sum /study/traffic/send_direct_operate.py').Split()[0].ToUpperInvariant()
if ($LASTEXITCODE -ne 0) { throw "sender hash verification exited $LASTEXITCODE" }
if ($inContainerSha -ne '093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B') { throw "sender hash mismatch: $inContainerSha" }
# Retain $inContainerSha before creating T0 immediately before the invocation below.
python studies/study-01-negative-result/scripts/study01_sender.py `
  --run-id <run-id> --run-evidence <run-evidence> -- `
  docker compose -p <run-id> -f <range-a-or-b-compose.yml> exec -T sub_a_ied_02 `
  python3 /study/traffic/send_direct_operate.py --target-ip 10.1.10.10 --target-port 20000 --function-code 5 --repeat 1
if ($LASTEXITCODE -ne 0) { throw "sender failed; retained Invalid run requires a fresh run ID" }
```

Record the container ID, directory-preparation command/exit code, placement command/exit code, verified in-container canonical asset SHA-256, invocation command, `T0`, and exit code in `<run-evidence>/metadata.md`. The fixed order is directory preparation → `docker cp` → in-container hash verification → `T0` → exactly-one invocation through `study01_sender.py`. That executable path writes both `ground-truth/sender-record.txt` and the structured `ground-truth/procedure-conformance.json`, and the structured record carries only send-time facts (see §3.1b). It refuses a pre-existing record or sender record, so no same-run sender reinvocation is executable through the canonical path; a failed invocation closes a retained Invalid run and requires a fresh run ID. `docker cp` is the only placement mechanism; no untracked host bind mount or ad hoc `/tmp` copy is permitted for Pilot or Main runs.

## 4. Sender predicate and failure handling

The sender stage passes only when all of the following are retained:

1. the command exits `0`;
2. `sender-record.txt` contains the success line matching `Sent DNP3 fc=5 frame (15 bytes) from 10.1.20.11 to 10.1.10.10:20000`; and
3. the independent original-path pcap satisfies the frozen Ground Truth selector in the [Freeze Decision Table](./freeze-decision-table.md).

The sender record alone is not Ground Truth. If placement, command execution, source address, output, or pcap correlation fails, preserve the record and classify the run under the frozen scoring rules; do not repair and reuse the run ID.

Conditions 1 and 2 are established at send time and are the sender record's responsibility. Condition 3 is established only after the settle window, from the retained capture, and is the Ground Truth stage's responsibility; it reaches the scorer through that stage rather than through the structured sender record. This division is what §3.1b fixed, and it changes neither the predicate above nor the requirement that a failure closes the run and forces a fresh run ID.

## 5. Cleanup and evidence retention

The sender leaves no intended persistent process or network change. Do not delete its record after a failed command. The run-level range cleanup is canonical in [C2 Range derivation and cleanup](./c2-dnp3-range-derivation.md): after evidence export and hashing, remove the whole Compose project and volumes to prevent sender, qdisc, index, or capture state from crossing into the next run.
