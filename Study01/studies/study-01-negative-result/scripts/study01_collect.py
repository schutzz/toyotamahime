#!/usr/bin/env python3
"""Evidence-tree integrity validator/finalizer; intentionally produces no score."""
import argparse, hashlib, json
from datetime import datetime
from pathlib import Path
from study01.capture_context import CaptureContextError, validate as validate_context
from study01.capture_lifecycle import CaptureLifecycleError, validate as validate_lifecycle
from study01.evidence_io import write_text
from study01.frozen import apparatus
from study01.procedure_conformance import ProcedureConformanceError, validate as validate_procedure

RUNTIME_DIRS = ("ground-truth", "sensor-input", "collector-output", "rule-output", "contract-output")
def files(root): return sorted(p for p in root.rglob("*") if p.is_file() and p.name != "hashes.sha256")
def validate(root, verify_hashes=False):
    missing = [x for x in RUNTIME_DIRS if not (root / x).is_dir()]
    if missing: raise ValueError("missing required evidence directories: " + ", ".join(missing))
    if not (root / "metadata.md").is_file() or not (root / "deviations.md").is_file():
        raise ValueError("metadata.md and deviations.md are required")
    procedure = root / "ground-truth" / "procedure-conformance.json"
    if not procedure.is_file():
        raise ValueError("ground-truth/procedure-conformance.json is required")
    try:
        conformance = validate_procedure(json.loads(procedure.read_text(encoding="utf-8")))
    except (json.JSONDecodeError, ProcedureConformanceError) as exc:
        raise ValueError(f"invalid procedure-conformance evidence: {exc}") from exc
    # T0 defines the frozen event window, so it is required as its own primary
    # artifact.  metadata.md prose is never parsed as a substitute for it.
    t0 = root / apparatus.T0_ARTIFACT
    if not t0.is_file():
        raise ValueError(f"{apparatus.T0_ARTIFACT} is required as a primary artifact")
    try:
        t0_value = datetime.fromisoformat(t0.read_text(encoding="utf-8").strip().replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"invalid {apparatus.T0_ARTIFACT}: not an RFC3339 timestamp") from exc
    if t0_value.tzinfo is None:
        raise ValueError(f"invalid {apparatus.T0_ARTIFACT}: must carry a UTC offset")
    # The frozen window is anchored to the sender's T0, so the standalone primary
    # artifact must be that same instant -- not merely a well-formed timestamp.
    invocations = conformance["sender_invocations"]
    if len(invocations) != 1:
        raise ValueError("a conformant run retains exactly one sender invocation")
    sent = datetime.fromisoformat(invocations[0]["timestamp"].replace("Z", "+00:00"))
    if sent.tzinfo is None:
        raise ValueError("the retained sender invocation timestamp must carry a UTC offset")
    if sent != t0_value:
        raise ValueError(
            f"{apparatus.T0_ARTIFACT} is not the sender invocation instant "
            f"({t0_value.isoformat()} != {sent.isoformat()})")
    # Capture procedure section 5 primary records, per stage.
    for stage, spec in apparatus.CAPTURE_STAGES.items():
        record = root / spec["lifecycle"]
        if not record.is_file():
            raise ValueError(f"{spec['lifecycle']} is required for the {stage} capture stage")
        context_path = root / spec["context"]
        if not context_path.is_file():
            raise ValueError(f"{spec['context']} is required for the {stage} capture stage")
        try:
            context = validate_context(json.loads(context_path.read_text(encoding="utf-8")), root.name)
        except (json.JSONDecodeError, CaptureContextError) as exc:
            raise ValueError(f"invalid {stage} capture-context evidence: {exc}") from exc
        try:
            retained = validate_lifecycle(json.loads(record.read_text(encoding="utf-8")), t0_value, context)
        except (json.JSONDecodeError, CaptureLifecycleError) as exc:
            raise ValueError(f"invalid {stage} capture-lifecycle evidence: {exc}") from exc
        if retained["run_id"] != root.name:
            raise ValueError(f"{spec['lifecycle']} run_id does not match the evidence directory")
        artifact = root / spec["artifact"]
        if not artifact.is_file():
            raise ValueError(f"{spec['artifact']} is required")
        actual = hashlib.sha256(artifact.read_bytes()).hexdigest()
        if actual != retained["pcap_sha256"]:
            raise ValueError(f"{spec['artifact']} does not match its retained capture-lifecycle sha256")
    for name in RUNTIME_DIRS:
        if not any(p.is_file() for p in (root / name).rglob("*")):
            raise ValueError(f"missing retained artifact in {name}")
    if verify_hashes:
        hashes=root / "hashes.sha256"
        if not hashes.is_file(): raise ValueError("hashes.sha256 is required after finalization")
        expected={}
        for line in hashes.read_text(encoding="utf-8").splitlines():
            digest, relative=line.split("  ", 1); expected[relative]=digest
        actual={f.relative_to(root).as_posix(): hashlib.sha256(f.read_bytes()).hexdigest() for f in files(root)}
        if expected != actual: raise ValueError("hashes.sha256 does not match retained evidence")
def main():
    p = argparse.ArgumentParser(); p.add_argument("command", choices=("validate-evidence", "finalize-evidence", "verify-integrity")); p.add_argument("run_dir", type=Path); a=p.parse_args()
    try: validate(a.run_dir, a.command == "verify-integrity")
    except ValueError as exc: p.error(str(exc))
    if a.command == "finalize-evidence":
        rows=[]
        for f in files(a.run_dir): rows.append(f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(a.run_dir).as_posix()}")
        write_text(a.run_dir / "hashes.sha256", "\n".join(rows))
    print("evidence completeness/integrity: PASS")
if __name__ == "__main__": main()
