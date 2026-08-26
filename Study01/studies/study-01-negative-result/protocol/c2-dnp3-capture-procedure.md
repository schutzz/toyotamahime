# Study 01 — C2 DNP3 Capture Procedure

**Status:** Canonical executable transcription of an existing frozen/proven procedure; no new research condition.

**Canonical execution shell: PowerShell 7.** Git Bash / MSYS is unsupported for Pilot and Main runs: it rewrites the bare in-container capture paths `/data/c2-original-path.pcap` and `/data/c2-mirror-sensor.pcap` before `docker run` receives them, which is how both capture helpers failed on their first attempt in `k5-range-a-20260824-009`. See [sender procedure §0](./c2-dnp3-sender-procedure.md#0-canonical-execution-shell) and the [execution preflight](./c2-dnp3-range-derivation.md#23-execution-preflight-gate).

## 1. Normative and proven basis

`study-01-protocol-v1.0` / `9d57d1e63d6cf16dcc37e8f60d560d30da5f4835` remains normative.  Its Freeze Decision Table fixes Ground Truth as sender record plus an independent original-path pcap on the gateway interface resolved by `10.1.20.254/24`; it fixes the mirror-side `tap_observer` pcap as a separate Sensor artifact.  The event, selector, frozen window `[T0 - 5 seconds, T0 + 15 seconds]`, sender, scoring, and Runtime Contract are unchanged.

This procedure restores the primary-record-proven capture mechanism: a digest-recorded helper joins the existing `wan_router` or `tap_observer` network namespace only to write a pcap.  It neither adds `tcpdump` to an apparatus container nor uses the mirror path as Ground Truth.

| Cross-review basis | Resolution |
| --- | --- |
| Classification | A — executable transcription of a Frozen Protocol procedure |
| Semantic impact | **NO CHANGE** |
| Apparatus dependency | **EXISTING FROZEN/PROVEN DEPENDENCY** |
| Amendment | **NOT REQUIRED** |
| Researcher degrees of freedom | **CLOSED** |
| Discovery | `k5-range-a-20260824-003` found the transcription gap before trigger. |

## 2. Fixed helper and capture locations

```text
corfr/tcpdump@sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b
```

The helper's locally inspected entrypoint is `/usr/sbin/tcpdump`.  Each helper is a separately named short-lived container with `NET_RAW`, joining the existing target namespace only through `--network container:<container-id>`.

| Stage | Namespace | Interface | Retained raw artifact |
| --- | --- | --- | --- |
| Ground Truth | `wan_router` | §3's resolved interface | `ground-truth/independent-capture/c2-original-path.pcap` |
| Sensor input | `tap_observer` | `eth0` | `sensor-input/mirror-capture/c2-mirror-sensor.pcap` |

The router-side helper is independent from `mirror_link`, `tap_observer`, `log_structurer`, Elasticsearch, and the rule path.  The observer-side helper is Sensor input only.

## 3. Pre-trigger resolution and guard

After the fresh run-ID project is healthy, but before either capture or sender, preserve this output in `contract-output/`:

```powershell
$router = docker compose -p <run-id> -f <range-a-compose.yml> ps -q wan_router
$observer = docker compose -p <run-id> -f <range-a-compose.yml> ps -q tap_observer
docker exec $router sh -lc 'ip -br addr'
```

Count interfaces containing exactly `10.1.20.254/24`; select its interface token only if it is the unique match. `ip -br addr` can render that token as `<device>@<peer-ifindex>` (for example, `eth6@if5890`). The tcpdump capture device is the substring before the first `@` (`eth6`); a token without `@` is unchanged. This normalization changes neither the IP-based selection rule nor its unique-match requirement.

```powershell
$resolvedGatewayIf = ($selectedInterfaceToken -split '@', 2)[0]
if ([string]::IsNullOrWhiteSpace($resolvedGatewayIf)) { throw 'capture device name was not resolved' }
```

If either container ID is empty or there is a zero or multiple match, do not start a helper and do not trigger. Retain the output and deviation; never substitute an ordinal or the mirror capture.

## 4. Canonical ordering

`<filter>` is the fixed BPF host/port filter; it does not replace the frozen decoded selector.

Each stage first retains the runtime values its helper will use, so they are proven rather than asserted:

```powershell
python studies/study-01-negative-result/scripts/study01_capture.py resolve `
  --run-id <run-id> --run-evidence <run-evidence> --stage ground-truth --compose <range-a-compose.yml>
if ($LASTEXITCODE -ne 0) { throw 'ground-truth capture context was not resolved; do not trigger' }
python studies/study-01-negative-result/scripts/study01_capture.py resolve `
  --run-id <run-id> --run-evidence <run-evidence> --stage sensor --compose <range-a-compose.yml>
if ($LASTEXITCODE -ne 0) { throw 'sensor capture context was not resolved; do not trigger' }
```

`resolve` runs the Compose service query and, for Ground Truth, `ip -br addr` inside the resolved container, and writes `capture-context.json` holding each command's argv, output, and exit code, the container ID the query printed, the lines matching `10.1.20.254/24`, the match count, the selected token, and its normalized capture device. A zero or multiple match fails closed.

Both helpers are then started through the mandatory `study01_capture.py` execution path, which issues the frozen `docker run` and retains its argv, exit code, output, and timestamp, then confirms the helper is listening and refuses to continue if it is not:

```powershell
python studies/study-01-negative-result/scripts/study01_capture.py start `
  --run-id <run-id> --run-evidence <run-evidence> --stage ground-truth
if ($LASTEXITCODE -ne 0) { throw 'ground-truth capture helper did not start; do not trigger' }
python studies/study-01-negative-result/scripts/study01_capture.py start `
  --run-id <run-id> --run-evidence <run-evidence> --stage sensor
if ($LASTEXITCODE -ne 0) { throw 'sensor capture helper did not start; do not trigger' }
```

The helper image digest, BPF filter, in-container pcap path, and export destination are frozen constants transcribed in `scripts/study01/frozen/apparatus.py`; the operator supplies only the run ID, evidence root, stage, and Compose file; the namespace container and capture device come from the retained resolutions rather than from anything typed by hand.

Confirm both helpers run before copying or invoking the sender.  Follow the frozen [sender procedure](./c2-dnp3-sender-procedure.md) exactly: record `T0` immediately before invocation and invoke it exactly once.  Both captures must cover `[T0 - 5 seconds, T0 + 15 seconds]`; they may start earlier but must not stop before `T0 + 15 seconds`.

## 5. Stop, export, and cleanup

After full window coverage, stop and export before removal:

```powershell
python studies/study-01-negative-result/scripts/study01_capture.py stop-export `
  --run-id <run-id> --run-evidence <run-evidence> --stage ground-truth
if ($LASTEXITCODE -ne 0) { throw 'ground-truth capture stop/export failed' }
python studies/study-01-negative-result/scripts/study01_capture.py stop-export `
  --run-id <run-id> --run-evidence <run-evidence> --stage sensor
if ($LASTEXITCODE -ne 0) { throw 'sensor capture stop/export failed' }
```

Retain helper digest/container ID, target namespace ID, interface resolution, command/log output, pcap SHA-256, and decoded verification with the appropriate stage artifact.

### 5.1 Formal pre-Pilot correction basis — machine-retained lifecycle records

Through run `k5-range-a-20260825-013` these records were written as operator prose in `verification.md` while the primary output was never retained. Independent acceptance review found the raw helper start, listening confirmation, stop, export, and remove output absent, along with any record directly evidencing capture start and stop times. The same gap is present in `k5-range-a-20260824-009`, so it survived several cross-reviews: the requirement had never been executed as written.

Prose cannot be audited, and adding another file for an operator to remember has already failed repeatedly on this class. The retention is therefore mechanical. `study01_capture.py` writes `capture-lifecycle.json` beside each stage's pcap, containing the helper name and container ID, the frozen image digest, the namespace service and container ID, the resolved interface, the frozen filter, the exported pcap's SHA-256, and — for each of the six lifecycle steps — the exact argv, exit code, output, and both the start and completion UTC timestamps.

Retention alone is not enough, so further bindings are enforced.

**The runtime values inside the frozen command must be proven.** `helper_container_id` must be the single ID the `docker run -d` step printed, and the lifecycle record's `namespace_container_id` and `interface` must equal what the retained `capture-context.json` resolutions produced. Every derived value in that context must follow from its own retained output: the container ID from the Compose query's output, and the matching tokens, match count, selected token, and normalized device from the `ip -br addr` output. Mutually agreeing but independently asserted values no longer pass.

**The retained instants must describe a sequence that could have happened.** Array order does not prove execution order, so each step's completion must precede the next step's start. `T0` must additionally be the instant of the sender invocation itself: the standalone `metadata-t0.txt` and the structured record's single invocation timestamp are compared as UTC instants, and a run retaining more than one invocation cannot anchor a window at all.

**The retained argv must be the frozen command.** Each step's argv is reconstructed from the record's own fields and compared, so a record cannot claim a lifecycle it did not execute against this helper, this namespace, this interface, this image digest, this filter, and these in-container paths. The helper name must derive from the run ID and stage, the namespace service must be the stage's frozen service, and the sensor stage's capture device is fixed at `eth0` while the Ground Truth device stays runtime-resolved. `study01_capture.py` issues each command from the same function validation checks against, so the two cannot drift apart.

The export step is bound the same way, through the retained `execution_run_root`. That field records the absolute evidence tree the export actually wrote into, so the destination is checked to be exactly `execution_run_root` plus the stage's schema artifact. Execution provenance is deliberately separated from the verifier's location: the retained argv is checked against the root the run used, while the current checkout is checked by hashing the artifact it holds against `pcap_sha256`. A record therefore stays verifiable after a fresh checkout at a different absolute path, without weakening the destination to a suffix that any similarly-named tree could satisfy. `execution_run_root` must be absolute, canonically spelled, and end in this run's ID, and the CLI refuses to export if the evidence tree has moved since the helper started.

**Window coverage is decided from the retained timestamps.** Each step retains both the moment its command began and the moment it returned, because the two prove different things. The listening line only exists once `docker logs` has returned, so coverage is judged from that step's **completion** timestamp, which must be at or before `T0 - 5 s`; timing it from the command's start would let a helper that only became ready during the call appear to have been confirmed earlier than it was. The window's far end is proven by observation rather than inference. Before stopping the helper, `stop-export` runs a **window-end liveness check** (`docker inspect --format {{.State.Running}}`) and retains its argv, output, exit code, and both timestamps. Validation requires that check to be timestamped at or after `T0 + 15 s`, to have reported `true`, and to precede the stop. Timing alone could not establish this: a stop issued after the window closed shows only that the capture was never asked to stop early, and cannot exclude a helper that died at, say, `T0 + 10 s`. That is the difference between *the operator did not stop it* and *the capture actually covered the window*, and after run `013` was withheld for exactly this class of prose-versus-evidence gap, the far end is now a primary record too. A helper found not running fails closed: the capture did not cover the window, and the run closes rather than exporting. Run `013` asserted a `35.18 s` settle delta in prose that could not be recomputed from evidence; coverage is now a property of the retained record rather than of the narrative.

`study01_collect.py` requires a valid record for both stages, requires the listening confirmation to appear in the retained output, requires each pcap to match the SHA-256 its own lifecycle record carries, and requires each record's run ID to match the evidence directory. A missing or malformed record fails closed, and `metadata.md` prose is never parsed as a substitute.

This correction changes no frozen event, selector, window, evidence schema path, or scoring rule. It fixes only which component records these facts, and requires no Protocol Amendment.  `hashes.sha256` and `down -v --remove-orphans` remain governed by the evidence schema and Range derivation procedure.  Helpers must be removed before range teardown.

## 6. Failures and retry

An unresolved helper start, export failure, missing pcap, capture-placement ambiguity, or incomplete event-window coverage forbids a Ground Truth substitute.  Preserve the run's metadata and deviations; never overwrite evidence or reuse its project.  Retry equals a fresh run ID and fresh Compose project only.

Historical unretained command lines are not represented as observed facts. This is the canonical K5 executable transcription of the primary-record-proven image, namespace placement, IP selection, artifacts, and ordering. The display-token normalization was recorded after `k5-range-a-20260824-004` stopped at the pre-trigger helper guard; it is an executable-transcription correction with semantic impact **NO CHANGE** and requires no Protocol Amendment.
