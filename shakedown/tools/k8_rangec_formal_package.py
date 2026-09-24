#!/usr/bin/env python3
"""Range C formal-shape packaging: a NON-EVIDENTIARY qualification artifact.

WHAT THIS IS
------------
A producer-side packaging step that renders an already-completed Range C run
into the shape `protocol/evidence-schema.md` SS1 fixes for a static-validation
package.  It runs AFTER the run, from that run's retained records, and it never
re-runs the validator: re-running would be a different observation.

WHAT THIS IS NOT
----------------
It does not produce formal K8 evidence.  K8-S2 is a Shakedown, Shakedown output
is NON-EVIDENTIARY, and this refuses to write into
`evidence/static-validations/range-c/` -- the canonical path for formal
evidence.  What is checked here is that the tooling CAN produce the shape, not
that the output IS evidence.

It is also a separate step from the run on purpose.  A packaging failure must
not be attributable to the observation, and must be re-runnable without
touching it: the observation is already retained and is never re-executed.

WHERE EACH FIELD COMES FROM
---------------------------
Every value is rendered from a named typed source, and a missing one is a STOP
rather than an omission.  Nothing is recovered by parsing prose logs, by reading
a version out of a stderr URL, by using a requirements.txt declaration in place
of a resolved version, or by re-observing the current environment and calling it
the run's.  Those four recovery routes are named because each is a way to make
the package look complete while describing a different environment.

`environment/versions.json` keeps the accepted K6 instance's field shape
exactly.  The producer record carries more determinacy -- observation instants,
per-field phase, both worktrees -- and that stays on the producer side: the
frozen schema says nothing about Range C's `environment/`, so a shape differing
from the accepted instance in an unregulated place could not be told apart from
an invention.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

ENVIRONMENT_SCHEMA = "k8shakedown-range-c-environment/1"
CANDIDATE_SCHEMA = "k8shakedown-deviation-candidates/1"

# The canonical path formal K8 evidence lives at. A Shakedown-produced package
# must never be written here; doing so would relabel NON-EVIDENTIARY output as
# formal evidence.
FORMAL_EVIDENCE_PATH_FRAGMENT = ("evidence", "static-validations", "range-c")

# evidence-schema.md SS1. `environment/` is not in this list -- it is present in
# the accepted K6 instance and in frozen Study01/expected/range-c/, which is the
# comparison target and the reason the values must be renderable at all.
REQUIRED_ENTRIES = (
    "metadata.md",
    "negative-manifest",
    "validation-command.md",
    "validator-output",
    "hashes.sha256",
    "deviations.md",
)

# SS54: Range C is non-provisioned and has no runtime stage directories.
FORBIDDEN_RUNTIME_DIRS = (
    "ground-truth", "sensor-input", "collector-output", "rule-output", "contract-output",
)

HUMAN_AUTHORED = ("validation-command.md", "deviations.md", "metadata.md")


class PackagingError(RuntimeError):
    """A STOP. The package is not written, and nothing partial is left behind."""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path, what: str):
    if not path.is_file():
        raise PackagingError(f"{what} is missing at {path}. Not proceeding -- this package "
                             f"renders retained records and does not reconstruct them.")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise PackagingError(f"{what} at {path} is not valid JSON: {exc}") from exc


def assert_not_canonical_evidence_path(destination: Path) -> None:
    """Refuse the formal-evidence path outright.

    Checked on the resolved path and on every ancestor, so a relative walk or a
    symlink cannot slip a Shakedown package into the tree where formal K8
    evidence lives.
    """
    parts = tuple(p.lower() for p in destination.resolve().parts)
    needle = FORMAL_EVIDENCE_PATH_FRAGMENT
    for i in range(len(parts) - len(needle) + 1):
        if parts[i:i + len(needle)] == needle:
            raise PackagingError(
                f"Refusing to write to {destination}: that is under the canonical formal "
                f"K8 evidence path {'/'.join(needle)}. K8-S2 is a Shakedown and its output "
                f"is a NON-EVIDENTIARY qualification artifact; writing it there would "
                f"relabel Shakedown output as formal evidence.")


def render_versions_json(environment: dict, observation: dict) -> dict:
    """The formal `environment/versions.json`, field by field, from typed sources.

    Field shape is exactly the accepted K6 instance's: `argv`, `versions` with
    four keys, `worktree_clean`, `worktree_head`. No field is added.
    """
    if environment.get("schema") != ENVIRONMENT_SCHEMA:
        raise PackagingError(
            f"the environment record has schema {environment.get('schema')!r}, "
            f"not {ENVIRONMENT_SCHEMA!r}.")

    by_name = {}
    for entry in environment.get("versions") or []:
        by_name[entry.get("name")] = entry

    versions = {}
    unavailable = []
    for name in ("git", "python", "pydantic", "pyyaml"):
        entry = by_name.get(name)
        if entry is None:
            unavailable.append(f"{name}: no entry in the environment record")
            continue
        if entry.get("status") != "succeeded":
            # Named rather than dropped. A silently omitted field would make an
            # incomplete package look complete.
            unavailable.append(f"{name}: status {entry.get('status')!r} "
                               f"({entry.get('value')!r})")
            continue
        versions[name] = entry.get("value")
    if unavailable:
        raise PackagingError(
            "STOP: these formal environment/versions.json fields have no observed value: "
            + "; ".join(unavailable)
            + ". The package is not written. This is a PACKAGING failure and leaves the "
              "run's observations untouched; re-run the packaging step after the values "
              "are observed. They are never recovered by re-observing the current "
              "environment, by reading a version out of the stderr URL, or from "
              "requirements.txt -- each of those would describe a different environment.")

    worktree = environment.get("worktree") or {}
    disposable = worktree.get("disposable") or {}
    head = disposable.get("head")
    clean = disposable.get("clean")
    if not isinstance(head, str) or len(head) != 40:
        raise PackagingError(
            f"STOP: the disposable worktree HEAD was not observed as a 40-hex commit "
            f"(got {head!r}). It is rendered from the OBSERVED value, never from the "
            f"pinned constant -- 'the assertion passed' and 'the observed value is this' "
            f"are different facts.")
    expected_pin = (environment.get("validator_source") or {}).get("pinned_commit")
    if expected_pin and head != expected_pin:
        raise PackagingError(
            f"STOP: the observed disposable worktree HEAD {head} does not equal the pinned "
            f"commit {expected_pin}. Not repaired here.")
    if not isinstance(clean, bool):
        raise PackagingError(
            f"STOP: the disposable worktree clean state was not observed as a boolean "
            f"(got {clean!r}). It is never re-observed at packaging time: the state that "
            f"matters is the one at validator start.")

    argv = (observation.get("observations") or [{}])[0].get("argv")
    if not argv:
        raise PackagingError("STOP: the C-4 observation carries no argv.")

    return {
        "argv": list(argv),
        "versions": versions,
        "worktree_clean": clean,
        "worktree_head": head,
    }


def assert_candidate_citation_coverage(candidates: dict, deviations_text: str) -> None:
    """Every surfaced candidate id must appear in the human's deviations.md.

    What this proves and what it does not, stated rather than left implied:

      provable      every candidate_id is cited by the human document
      NOT provable  that the citation actually answers the candidate

    The second is content, and content is the human's. So this is a coverage
    check, never a substitute for the judgment.
    """
    if candidates.get("schema") != CANDIDATE_SCHEMA:
        raise PackagingError(
            f"the candidate record has schema {candidates.get('schema')!r}, "
            f"not {CANDIDATE_SCHEMA!r}.")
    missing = [c["candidate_id"] for c in candidates.get("candidates") or []
               if c.get("candidate_id") not in deviations_text]
    if missing:
        raise PackagingError(
            "STOP: deviations.md does not cite these machine-surfaced candidate ids: "
            + ", ".join(missing)
            + ". This is the mechanical fact that the human authoring is not finished. It "
              "is NOT a judgment that a deviation exists -- and citing an id is not "
              "evidence that it was answered, only that it was referenced.")


def build(run_evidence: Path, run_records: Path, destination: Path,
          validation_id: str, human_dir: Path) -> dict:
    assert_not_canonical_evidence_path(destination)
    if destination.exists() and any(destination.iterdir()):
        raise PackagingError(
            f"{destination} already exists and is not empty. A previous attempt is never "
            f"overwritten or cleaned up automatically; retained records are not deleted "
            f"to make a retry succeed.")

    observation = load_json(run_evidence / "validate.observation.json", "the C-4 observation")
    environment = load_json(run_records / "range-c-environment.json", "the environment record")
    candidates = load_json(run_records / "deviation-candidates.json", "the candidate record")

    obs = (observation.get("observations") or [{}])[0]
    versions_json = render_versions_json(environment, observation)

    # The three human-authored files. Their EXISTENCE is required; their content
    # is never inspected, beyond the candidate-id coverage check.
    for name in HUMAN_AUTHORED:
        if not (human_dir / name).is_file():
            raise PackagingError(
                f"STOP: {name} was not supplied in {human_dir}. It carries human judgment "
                f"and is not machine-generated: a generated 'None affecting the validation' "
                f"would hide the observations that should have been written down.")
    assert_candidate_citation_coverage(
        candidates, (human_dir / "deviations.md").read_text(encoding="utf-8"))

    destination.mkdir(parents=True, exist_ok=True)
    (destination / "negative-manifest").mkdir(exist_ok=True)
    (destination / "validator-output").mkdir(exist_ok=True)
    (destination / "environment").mkdir(exist_ok=True)

    # Bytes are COPIED from what the run retained -- the manifest the validator
    # actually read (retained at patch-apply), and the streams cmd.exe itself
    # wrote. Nothing is regenerated.
    shutil.copyfile(run_evidence / "power-grid-reference.range-c-negative.yaml",
                    destination / "negative-manifest" / "power-grid-reference.range-c-negative.yaml")
    shutil.copyfile(run_evidence / "range-c-derived.patch",
                    destination / "negative-manifest" / "range-c-derived.patch")
    shutil.copyfile(run_evidence / "validate.stdout.txt",
                    destination / "validator-output" / "validate.stdout")
    shutil.copyfile(run_evidence / "validate.stderr.txt",
                    destination / "validator-output" / "validate.stderr")
    for name in HUMAN_AUTHORED:
        shutil.copyfile(human_dir / name, destination / name)

    # exit-code.txt is RENDERED from the observation, never obtained by running
    # the validator again.
    (destination / "validator-output" / "exit-code.txt").write_text(
        f"{obs['exit_code']}\n", encoding="utf-8", newline="\n")
    (destination / "environment" / "versions.json").write_text(
        json.dumps(versions_json, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8", newline="\n")

    # The retained streams must still be the observed ones.
    for stream, packaged in (("stdout", "validate.stdout"), ("stderr", "validate.stderr")):
        described = obs[stream]
        actual = destination / "validator-output" / packaged
        if actual.stat().st_size != described["bytes"] or sha256_file(actual) != described["sha256"]:
            raise PackagingError(
                f"STOP: the packaged {packaged} does not match the C-4 observation "
                f"({described['bytes']} bytes, sha256 {described['sha256']}).")

    # hashes.sha256 covers every file except itself -- the accepted K6 instance's
    # own precedent (9 of its 10 files).
    files = sorted(p for p in destination.rglob("*") if p.is_file())
    lines = [f"{sha256_file(p)}  {p.relative_to(destination).as_posix()}\n" for p in files]
    (destination / "hashes.sha256").write_text("".join(lines), encoding="utf-8", newline="\n")

    return {
        "validation_id": validation_id,
        "destination": str(destination),
        "evidentiary_status": "NON-EVIDENTIARY qualification artifact (K8-S2 Shakedown). "
                              "This is not formal K8 evidence and is not placed under the "
                              "canonical formal evidence path.",
        "covered_files": len(files),
        "environment_versions": versions_json["versions"],
        "candidates_surfaced": len(candidates.get("candidates") or []),
    }


def verify(destination: Path, run_evidence: Path, run_records: Path) -> list:
    """Checks the placed package. Returns problems; empty means it holds."""
    problems = []
    for entry in REQUIRED_ENTRIES:
        if not (destination / entry).exists():
            problems.append(f"required entry missing: {entry}")
    for forbidden in FORBIDDEN_RUNTIME_DIRS:
        if (destination / forbidden).exists():
            problems.append(f"runtime stage directory present: {forbidden} "
                            f"(evidence-schema.md SS54: Range C has none)")

    manifest = destination / "hashes.sha256"
    if manifest.is_file():
        covered = {}
        for line in manifest.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            digest, _, rel = line.partition("  ")
            covered[rel] = digest
        if "hashes.sha256" in covered:
            problems.append("hashes.sha256 covers itself; the K6 instance does not")
        on_disk = {p.relative_to(destination).as_posix()
                   for p in destination.rglob("*") if p.is_file()} - {"hashes.sha256"}
        for missing in sorted(on_disk - set(covered)):
            problems.append(f"file not covered by hashes.sha256: {missing}")
        for rel, digest in sorted(covered.items()):
            path = destination / rel
            if not path.is_file():
                problems.append(f"hashes.sha256 names a missing file: {rel}")
            elif sha256_file(path) != digest:
                problems.append(f"digest mismatch: {rel}")

    try:
        observation = load_json(run_evidence / "validate.observation.json", "the C-4 observation")
        environment = load_json(run_records / "range-c-environment.json", "the environment record")
    except PackagingError as exc:
        problems.append(str(exc))
        return problems

    obs = (observation.get("observations") or [{}])[0]
    exit_file = destination / "validator-output" / "exit-code.txt"
    if exit_file.is_file() and exit_file.read_text(encoding="utf-8").strip() != str(obs["exit_code"]):
        problems.append("exit-code.txt disagrees with the C-4 observation")

    manifest_bytes = destination / "negative-manifest" / "power-grid-reference.range-c-negative.yaml"
    retained = run_evidence / "power-grid-reference.range-c-negative.yaml"
    if manifest_bytes.is_file() and retained.is_file():
        if sha256_file(manifest_bytes) != sha256_file(retained):
            problems.append("the packaged negative manifest is not the bytes the validator read")

    versions_path = destination / "environment" / "versions.json"
    if versions_path.is_file():
        placed = json.loads(versions_path.read_text(encoding="utf-8"))
        expected = render_versions_json(environment, observation)
        if set(placed) != set(expected):
            problems.append(f"environment/versions.json key set {sorted(placed)} does not match "
                            f"the accepted K6 instance shape {sorted(expected)}")
        elif placed != expected:
            problems.append("environment/versions.json does not match its typed sources")
        if placed.get("argv") != obs.get("argv"):
            problems.append("environment/versions.json argv disagrees with the C-4 observation")
    return problems


def cmd_build(args):
    result = build(args.run_evidence.resolve(), args.run_records.resolve(),
                   args.destination.resolve(), args.validation_id, args.human_dir.resolve())
    print(json.dumps(result, indent=2, ensure_ascii=False))


def cmd_verify(args):
    problems = verify(args.destination.resolve(), args.run_evidence.resolve(),
                      args.run_records.resolve())
    if problems:
        for p in problems:
            print(f"FAIL  {p}", file=sys.stderr)
        raise SystemExit(1)
    print("Range C formal-shape package verification: PASS "
          "(a NON-EVIDENTIARY qualification artifact, not formal K8 evidence)")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name, fn in (("build", cmd_build), ("verify", cmd_verify)):
        p = sub.add_parser(name)
        p.add_argument("--run-evidence", type=Path, required=True)
        p.add_argument("--run-records", type=Path, required=True)
        p.add_argument("--destination", type=Path, required=True)
        if name == "build":
            p.add_argument("--validation-id", required=True)
            p.add_argument("--human-dir", type=Path, required=True)
        p.set_defaults(func=fn)
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except PackagingError as exc:
        print(f"STOP: {exc}", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
