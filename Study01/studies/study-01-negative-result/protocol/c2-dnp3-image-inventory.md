# Study 01 — C2 DNP3 Selected-Scenario Image Inventory

**Status:** K3 pre-freeze inventory

This is the authoritative inventory for semantically relevant C2 Range A/B runtime images. It is intentionally narrower than every service in the power-grid reference manifest: a listed role is needed to generate, observe, structure, retain, or positively evaluate the selected event, including the unrelated DNP3 traffic required to show that the Range B fault is target-segment-specific.

## 1. Image inventory

| Logical role | Service / use | Reference observed in fixed generated scenario | Immutable image identity | Provenance and freeze rule |
| --- | --- | --- | --- | --- |
| Sender endpoint | `sub_a_ied_02` | `python:3.10-slim` | `python@sha256:c1e4e6c01eb489c422288b2de34b0761ca316f7a2d98e2c33f47659a73ed108a` | Pulled image inspected locally. The Study sender is copied at runtime from Kakuriyo; its SHA-256 is fixed in the sender procedure. |
| Destination/master | `cc_scada_master` | local `build: ../protocol-images/dnp3` | Candidate-run image ID `sha256:c8a383be3bfa952f1fb728e93faf3cc08b5ef75f8a12b8268c7b4522d47a7f21` | Local build, not an upstream registry digest. Build context is fixed by Amenonuboco commit `78fc177...`; `protocol-images/dnp3/Dockerfile` SHA-256 `928E67DB5D08531AD0307DCC7EF239FAE4318A9311C6E5F5E3A20E16E4B9F8D4`, `run.py` SHA-256 `4FA48B709401DB59C5F6D039491851458F1E0E30193D41EE5DECCCC33491FC9D`, and base image digest listed above. The actual local image ID for every Pilot/Main run must be captured before trigger. |
| Unrelated DNP3 control traffic | `sub_c_rtu` | local `build: ../protocol-images/dnp3` | Candidate-run image ID `sha256:ad55069f42b64bb5d6d760035194cbd2a310def8d85475da4eaa98c9e2477c20` | Same pinned build context as `cc_scada_master`; required only for the frozen Range B nontriviality check. Capture the actual run image ID before trigger. |
| Gateway/router | `wan_router` | `debian:bullseye-slim` | `debian@sha256:cba95a21c96c1f5fc2470081829363eed57706634f7dc26e8c6712934303d57a` | Pulled image inspected locally; generated startup command installs and uses `iproute2` to configure routing/mirroring. |
| Tap observer | `tap_observer` | `debian:bullseye-slim` | `debian@sha256:cba95a21c96c1f5fc2470081829363eed57706634f7dc26e8c6712934303d57a` | Pulled image inspected locally; generated startup command installs `tcpdump`. |
| Log structurer | `log_structurer` | `debian:bullseye-slim` | `debian@sha256:cba95a21c96c1f5fc2470081829363eed57706634f7dc26e8c6712934303d57a` | Pulled image inspected locally; generated startup command installs `tshark` and runs the baseline `bulk_loader.py` (SHA-256 `1806499E3D74724029D6FDCDD09898ED486EA1A578A4B97B591D113D43411A65`). |
| Elasticsearch collector | `elasticsearch` | `docker.elastic.co/elasticsearch/elasticsearch:8.12.0` | `docker.elastic.co/elasticsearch/elasticsearch@sha256:ec72548cf833e58578d8ff40df44346a49480b2c88a4e73a91e1b85ec7ef0d44` | Pulled image inspected locally. |
| Rule sidecar | `zone_detector` | `python:3.11-slim` | `python@sha256:90744cff8f32887f075c47d747a173ff333e9e98801667af93c357fa9f5e28ff` | Pulled image inspected locally; generated command installs `requests` then runs `zone_violation.py` from fixed baseline (SHA-256 `3441080F4AA469CB48A3794113ABCD7F3E877EAF9CB61F22EE00B108593A9D4E`). The script’s runtime package installation is retained as generated-baseline provenance, not misrepresented as a separately pinned package image. |
| Independent capture helper | C2 original-path capture helper | `corfr/tcpdump:latest` in candidate run procedures | `corfr/tcpdump@sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b` | Pulled image inspected locally. `latest` is recorded only as the observed tag; the digest is the frozen identity. |

## 2. Build-input / provenance freeze model

Study 01 does **not** require one locally built DNP3 binary image artifact to be created at K3 and reused forever across every Pilot/Main run. Instead, its K3 reproducibility boundary is a **build-input / provenance freeze model**:

- K3 fixes the Amenonuboco commit, DNP3 Dockerfile and `run.py`, their hashes, the base-image reference/digest where available, the build procedure, and each role’s semantic purpose.
- Before the trigger of every Pilot/Main run, retain the actual local image ID, effective image references, fixed build-context hashes, and relevant build provenance.
- A matching mutable Compose tag alone never establishes image equivalence. Different local image IDs across runs are retained as an identity difference, not silently called the same environment.
- When a build identity difference could affect semantic behavior or the runtime evidence chain, apply the dependency/equivalence assessment and the `Rerun REQUIRED` or `Rerun ASSESS / PARTIAL` rule in [Amendments](./amendments.md).

Accordingly, Study 01 limits its reproducibility claim to fixed build inputs/provenance plus preservation of the actual artifact identity used by each run. It does not claim that an unchanged Dockerfile produces a bit-identical local image: the DNP3 build depends on `python:3.10-slim` and the package-repository state consulted by `apt-get`.

## 3. Completeness and limits

The fixed generated base manifest itself has SHA-256 `013EB4B09B35F4D73C2D1A2C06F8BD49622A15685E42C65FD8E5CF451382E0B2` at Amenonuboco commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`. The inventory does not elevate unrelated base-manifest assets (for example, Grafana, Node-RED, OPC UA, SNMP, Caldera, or Vector) into selected-scenario semantics.

For local DNP3 builds, a Compose project can assign a run-specific mutable tag. The immutable local image ID above identifies actual C2 Step 3 replication images; the frozen execution procedure therefore requires each Pilot/Main run to retain the newly built image ID and build-context hashes before the sender trigger. A future local build must not be called identical solely from a matching mutable tag.

**K4 pin (added by [Amendment 001](./amendments.md#amendment-001--initial-k4-dependency-pin)):** the generic Observability Contract capability is now pinned at Amenonuboco `v0.13.0` / commit `0378f8a32701b481e030f3db3d5f66ea471a4675` (see [`dependencies.md` §2.1](./dependencies.md#21-k4-generic-observability-contract-pin)). It introduces **no new runtime container image** — it is a pure `platform/` CLI and schema change exercised through `python platform/cli.py validate`, which runs on the host/CI process, not inside any provisioned range container. Every image role in §1 above, and the Range A/B build provenance, is unchanged by this pin. The only new provenance element is the pinned commit itself, which governs `validate`'s behavior for the C2 Range C static check (see [K4-8 static integration verification](../platform-acceptance/k4-observability-contract/kakuriyo-pin/k4-8-static-integration-verification.md)).

## 4. Collection command

Before a Pilot or Main trigger, preserve the effective image references and IDs for the active Compose project:

```powershell
docker compose -p <run-id> -f <range-a-or-b-compose.yml> images --format json
docker image inspect <resolved-image-reference-or-id> --format '{{.Id}} {{json .RepoDigests}}'
```

Store the command output under `<run-evidence>/environment/` and include the resolved values in `metadata.md`. This collection rule complements, rather than replaces, the immutable values above.
