# Study 01 — C2 Range A/B/C Derivation and Cleanup

**Status:** K3 pre-freeze canonical procedure

This document fixes how the selected C2 scenario is derived. It does not execute a Pilot or a Main Experiment, and it does not change the pre-existing Range A/B/C research semantics.

## 1. Fixed sources and generated outputs

| Item | Canonical path / value |
| --- | --- |
| Amenonuboco worktree | A clean worktree at `78fc17746b5d663fafec9dffe563d79fe9ea02b7` (`v0.12.0`) |
| Base manifest | `manifests/power-grid-reference.yaml` |
| Range A manifest | The unmodified canonical base manifest |
| Range B manifest | The same unmodified canonical base manifest as Range A |
| Range C patch | `experiments/range-c-negative-manifest/power-grid-reference.range-c-negative.patch` |
| Range A/B Compose output | `<run-workspace>/power-grid-reference.<range>.docker-compose.yml` |
| Range C derived manifest | `<static-validation-workspace>/manifests/power-grid-reference.range-c-negative.yaml` |
| Run workspace | A directory **exactly one level below the fixed worktree root**, e.g. `manifests/`. See §2.1. |
| Generated-artifact integrity | SHA-256 of the manifest, patch (Range C), generated Compose/derived manifest, and validation output are recorded in the run/validation `hashes.sha256`. The generated Compose SHA-256 is a **within-run integrity record only**; see §2.2. |

Each Range A or B run receives a fresh Compose project name equal to its run ID. Never reuse a Compose project, generated Compose file, container, volume, index, or capture from another run.

## 2. Range A derivation and provisioning

From the clean fixed Amenonuboco worktree, generate the Compose file into the run workspace; do not edit the generated file:

```powershell
python platform/cli.py provision manifests/power-grid-reference.yaml `
  -o <run-workspace>/power-grid-reference.range-a.docker-compose.yml
Get-FileHash <run-workspace>/power-grid-reference.range-a.docker-compose.yml -Algorithm SHA256
# The execution preflight below is a gate: do not run `up` until it exits 0.
docker compose -p <run-id> -f <run-workspace>/power-grid-reference.range-a.docker-compose.yml up -d --build
```

Range A uses normal instrumentation and injects no runtime observation fault. Before the sender procedure begins, record `docker compose ps`, resolved gateway interface evidence, image inventory, and capture setup in the run evidence tree.

### 2.1 Run workspace placement is load-bearing

The generator emits local build contexts as the fixed relative path `../protocol-images/<protocol>`, which Docker resolves **relative to the generated Compose file's own directory**. The run workspace is therefore not a free parameter: it must sit exactly one level below the fixed worktree root.

Attempt `k5-range-a-20260824-010` generated the file into `runs/<run-id>/`, two levels below the root. Buildx resolved `runs/protocol-images/dnp3`, which does not exist, and the run failed before any container was created. Attempt `009`, which provisioned successfully, used `manifests/`.

### 2.2 The generated Compose hash is not a cross-run reproducibility check

The generated file embeds **absolute host paths** for its bind-mount sources, so its SHA-256 is a function of the worktree's location on the executing host. Two byte-identical worktrees at different paths produce different hashes.

That hash is therefore retained as a within-run integrity record and **must not** be used as evidence that one run reproduced another. Cross-run reproducibility is carried by the structural conditions in §2.1 and by the [execution preflight](#23-execution-preflight-gate), which check what the hash was previously assumed to prove.

### 2.3 Execution preflight gate

Every Range A/B run must pass the Docker-free acceptance gate before provisioning. It starts no container and sends no event:

```powershell
python studies/study-01-negative-result/scripts/study01_preflight.py `
  --run-id <run-id> --worktree <amenonuboco-worktree> `
  --compose <run-workspace>/power-grid-reference.range-a.docker-compose.yml `
  --run-evidence <run-evidence> --project-name <run-id> --teardown-target <run-id> `
  --shell-probe "$($PSVersionTable.PSVersion)" `
  --path-probe /study/traffic/send_direct_operate.py /data/c2-original-path.pcap /data/c2-mirror-sensor.pcap
if ($LASTEXITCODE -ne 0) { throw "execution preflight failed; do not provision this run ID" }
```

The fixed order is: create the run evidence tree → generate the Compose file per §2 → run this gate → `docker compose up`. The gate reads both the evidence tree and the generated Compose file, so it cannot run before either exists. Retain the preflight output as `<run-evidence>/environment/preflight.txt`. A failing gate is not a deviation to record and continue past: correct the apparatus and start a fresh run ID.

## 3. Range B derivation, fault injection, and verification

Range B repeats the exact Range A derivation and provisioning procedure with only the run ID and generated output filename changed:

```powershell
python platform/cli.py provision manifests/power-grid-reference.yaml `
  -o <run-workspace>/power-grid-reference.range-b.docker-compose.yml
docker compose -p <run-id> -f <run-workspace>/power-grid-reference.range-b.docker-compose.yml up -d --build
```

After the environment is healthy and before capture/trigger, resolve the unique gateway interface by its IP address rather than by an ordinal such as `eth5`:

```powershell
$router = docker compose -p <run-id> -f <range-b-compose.yml> ps -q wan_router
$gatewayIf = docker exec $router sh -lc 'ip -o -4 addr show | awk ''/10.1.20.254\/24/ {print $2}'' | head -n 1'
if ([string]::IsNullOrWhiteSpace($gatewayIf)) { throw 'sub_a_l2_lan gateway interface was not resolved' }
docker exec $router tc qdisc show dev $gatewayIf
docker exec $router tc filter show dev $gatewayIf parent ffff:
docker exec $router tc qdisc del dev $gatewayIf ingress
docker exec $router tc filter show dev $gatewayIf parent ffff:
```

The sole permitted fault is deletion of this ingress qdisc. Do not modify routing, IP forwarding, the mirror-link egress rewrite, another gateway ingress qdisc, a container service, or the base manifest. Preserve pre/post command output and the resolved interface in `contract-output/`. Verify an unrelated observed-segment mirror filter and unrelated mirror traffic remain available, as required by the frozen Range B conditions.

## 4. Range C derivation and validation boundary

Range C is a non-provisioned static asset. In a disposable worktree copied from the fixed baseline, first copy the base manifest under the negative-manifest filename. Derive a temporary path-adjusted patch from the retained canonical patch, then apply it and generate only static artifacts:

```powershell
Copy-Item -Recurse -Force <amenonuboco-fixed-worktree> <static-validation-workspace>
Set-Location <static-validation-workspace>
Copy-Item manifests/power-grid-reference.yaml manifests/power-grid-reference.range-c-negative.yaml
$patch = Get-Content -Raw <kakuriyo-repo>/studies/study-01-negative-result/experiments/range-c-negative-manifest/power-grid-reference.range-c-negative.patch
$derivedPatch = <static-validation-workspace>/range-c-derived.patch
$patch.Replace('power-grid-reference.yaml', 'power-grid-reference.range-c-negative.yaml') | Set-Content -NoNewline $derivedPatch
git apply --ignore-space-change --check $derivedPatch
git apply --ignore-space-change $derivedPatch
python platform/cli.py provision manifests/power-grid-reference.range-c-negative.yaml `
  -o <static-validation-workspace>/power-grid-reference.range-c-negative.docker-compose.yml
```

The pinned v0.12.0 baseline may provision this static contradiction; retain that as the preserved pre-K4 behavior only. Do not call `docker compose up` for Range C. After K4 is separately version-pinned, its `validate` command must reject the same segment-level observation precondition/blind spot before provisioning. The concrete DNP3 event is not a static-validator input.

The path retargeting uses a string replacement against the fixed patch’s current filename. This is a known maintenance limitation, not a second patch mechanism: it was executed successfully against the fixed baseline during the pre-freeze check in §6. It does not add a freeze blocker or change the Range C semantic condition. A later maintenance improvement must not silently substitute a different negative-manifest meaning.

## 5. Cleanup and carry-over prevention

### 5.1 Candidate-validation history versus Pilot/Main policy

Some preserved candidate-validation runs used `docker compose down` without `-v`. Those were exploratory/diagnostic runs, and retaining their volumes enabled post-run investigation. They remain candidate evidence in their original state; Study 01 does not reinterpret them as having followed the Pilot/Main procedure, and this policy does not rewrite or invalidate their recorded cleanup.

Pilot and Main runs instead prioritize clean-run independence. Only after every required artifact has been exported and hashed, they remove the project and volumes so that project, volume, index, capture, and Range B fault state cannot cross into a later run. This is an intentional research-stage distinction, not a contradiction in the candidate evidence.

### 5.2 Pilot/Main cleanup

For Range A and B, first stop capture helpers, export and hash all required evidence, and record cleanup outcome in `metadata.md` and `deviations.md`. Then destroy the project, including volumes, to avoid state carry-over:

```powershell
docker compose -p <run-id> -f <range-a-or-b-compose.yml> down -v --remove-orphans
docker compose -p <run-id> -f <range-a-or-b-compose.yml> ps
```

The final `ps` result and any cleanup exception are retained. Range B does not require manual qdisc restoration when the complete range is destroyed; a later run must use a new project and re-resolve the interface. If destruction cannot complete, classify the cleanup as a deviation and do not reuse the project for another run.

For Range C, remove only the disposable derived worktree and generated static artifacts after their hashes and validator output have been retained. No Docker runtime cleanup is applicable because Range C is never provisioned.

## 6. Pre-freeze reproducibility check

On 2026-08-23, the K3 review generated a Range A Compose file from the fixed base manifest using §2 (SHA-256 `02B54B823CF5C4F0315C32706DB7C1A511D0E45FBF5D17FD160E872B5F33D641`). It also completed the §4 disposable Range C derivation: patch check/application succeeded, the derived manifest SHA-256 was `5314507108CE86E36A0898EA3C1FD5D162C86FDE95CBE8FC15F1D99A96FFEE7D`, and the generated static Compose SHA-256 was `BB74E5E795E625957167BE9AD8A22F153DB94837D3B44AB095E36B09A20B982B`. The existing Step 4 evidence separately confirms the IP-based qdisc preparation in §3. These are procedure-executability checks, not a Pilot, Main Experiment, or new Study 01 result.

**Correction note (K5, post-`010`).** The Range A Compose SHA-256 recorded above is retained unchanged as the historical record of that check, but it does **not** establish cross-run reproducibility, for the reason given in §2.2: the value is bound to the worktree path used on 2026-08-23. Attempt `009` reported the identical hash because it reused that same worktree directory, not because the generation was path-independent; attempt `010` created a fresh worktree and necessarily produced a different hash. No prior run's retained evidence is modified by this note; the reproducibility claim it previously carried is now carried by §2.1 and §2.3 instead.
