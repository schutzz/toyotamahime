# C2 Range C — Negative Manifest Asset

This directory contains the non-provisioned static counterpart to C2 Step 4. Apply the patch in a disposable worktree; it transforms that worktree's `manifests/power-grid-reference.yaml` into the negative manifest. On the present Windows baseline use `git apply --ignore-space-change` because the checked-out YAML uses CRLF. Never provision it.

The patch deliberately declares both:

- `sub_a_l2_lan` is required observable for the Study's C2 source request; and
- `sub_a_l2_lan` is excluded from instrumentation mirroring.

Against the pre-K4 Amenonuboco `v0.12.0` baseline (`78fc17746b5d663fafec9dffe563d79fe9ea02b7`), this manifest is accepted because no Observability Contract schema/validator exists yet to parse `observability_contract` at all. Against the K4-pinned Amenonuboco `v0.13.0` release (`0378f8a32701b481e030f3db3d5f66ea471a4675`), `platform/cli.py validate` rejects it before provisioning, naming the requirement (`observability_contract.required_segments`) and the segment (`sub_a_l2_lan`). This asset must not be provisioned in either case; only `validate` is run against it.

## Revision note (K4-8 static integration verification)

The `observability_contract` shape in this patch was originally written before Amenonuboco's K4-2 schema was implemented, as a placeholder representation: a list of objects (`id`/`segment`/`mirror_to` keys). The Amenonuboco `v0.13.0` schema that was actually implemented and released is a flat list of segment-name strings (`required_segments: list[str]`; see `docs/manifest-schema-guide.md` section 3.1 in Amenonuboco). Applying the original object-shaped patch against `v0.13.0` did still produce `exit_code=1`, but for the wrong reason — a Pydantic schema type error (`observability_contract.required_segments.0 — Input should be a valid string`) raised before the manifest ever reached `validate_observability_contract()`, not the intended contract-violation error. This patch was corrected to the real `list[str]` shape so that Range C static integration verification exercises the actual frozen invariant (required segment excluded from the computed observed-segment set), not an unrelated parse failure that happens to also exit non-zero. See [K4-8 static integration verification](../../platform-acceptance/k4-observability-contract/kakuriyo-pin/k4-8-static-integration-verification.md) for the full before/after evidence.

See [C2 Step 5 procedure](../../protocol/c2-dnp3-step5-range-c-static-correspondence.md).
