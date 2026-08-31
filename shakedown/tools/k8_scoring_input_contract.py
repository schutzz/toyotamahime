#!/usr/bin/env python3
"""C-3 scoring-input structural contract: ONE source of truth for the
template, the validator, and the tests.

WHY A SINGLE SOURCE (K8-S2 Batch 2, C3-R0)
------------------------------------------
The frozen apparatus does NOT contain this contract.  `study01/frozen/
semantics.py` is an executable transcription of the VALUE domains only --
MANDATORY_STAGES, STAGE_VALUES, RULE_VALUES, RUNTIME_VALUES.  It says
nothing about which fields must be present for which Range, which fields
need a recorded derivation, or how a derivation addresses a field.  Those
are Batch 2 STRUCTURAL additions.

Hardcoding them separately in a template generator and again in a
validator would recreate exactly the two-list divergence C-6 exists to
prevent.  So: the value domains are IMPORTED from the frozen module, the
structural additions live in CONTRACT below, and template / validator /
tests are all derived from that one object.  `describe` exists so the
regression suite can audit the derivation instead of restating it.

WHAT THIS IS NOT
----------------
This never scores anything.  It checks that a human-authored scoring
input is STRUCTURALLY complete and internally consistent with the
retained evidence:

  * every field the frozen scorer will read is present for this Range;
  * every value is inside the frozen (or contract-fixed) token domain;
  * every such field records WHICH artifact it was read from and WHAT
    value was read;
  * that artifact exists, is inside the run evidence, is covered by the
    finalized integrity manifest, still hashes to what the manifest says,
    and the manifest itself is the one that actually passed
    verify-integrity (see --finalize-snapshot).

Whether the operator READ THE ARTIFACT CORRECTLY is not checked and
cannot be: that is the human judgment README SS6.2 reserves.  This tool
never opens `expected/`, never derives Pass/Fail/Alert/No alert, and
never fills a value in.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Placeholders.  Both are deliberately outside every token domain, so a
# template that still contains one fails BOTH this validator and the frozen
# scorer (C3-R2b).  They are never "empty" or "null" values a careless
# reader could mistake for a decision.
# ---------------------------------------------------------------------------
PLACEHOLDER = "<FILL-IN>"
PROCEDURE_PLACEHOLDER = "<COPY ground-truth/procedure-conformance.json HERE>"
PLACEHOLDERS = (PLACEHOLDER, PROCEDURE_PLACEHOLDER)

TEMPLATE_SCHEMA = "k8shakedown-scoring-input-template/1"
FINALIZE_IDENTITY_SCHEMA = "k8shakedown-finalize-identity/1"


def frozen_semantics(scripts_dir: Path):
    """Import the frozen value domains.  Never copied, never re-declared."""
    scripts_dir = scripts_dir.resolve()
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))
    from study01.frozen import semantics  # noqa: E402  (path set above)
    return semantics


def default_scripts_dir() -> Path:
    # <repo>/shakedown/tools/this-file -> <repo>/Study01/.../scripts
    return (Path(__file__).resolve().parents[2]
            / "Study01" / "studies" / "study-01-negative-result" / "scripts")


BOOL_DOMAIN = "strict-bool"


class Field:
    """One field the frozen scorer reads, plus its Batch 2 structural rules."""

    def __init__(self, address, ranges, required, domain, why):
        self.address = address      # dotted address into the scoring input
        self.ranges = ranges        # subset of "ab"
        self.required = required    # required, or optional-but-derived-if-present
        self.domain = domain        # frozen semantics attribute name, or a literal set
        self.why = why              # the frozen source that fixes this rule

    def applies_to(self, range_key):
        return range_key in self.ranges


# ---------------------------------------------------------------------------
# THE CONTRACT.  `domain` is either the NAME of a frozen semantics constant
# (resolved at run time -- never copied here) or a literal token set whose
# `why` names the frozen source that fixes it.
#
# `r_obs_05` accepts Pass and Fail ONLY.  The R-OBS-05 query contract also
# defines an `Unresolved` OUTCOME (SS3: "A zero total ... is `Unresolved`"),
# but that is an outcome of the QUERY OBSERVATION.  No frozen source fixes
# what `"r_obs_05": "Unresolved"` would do to the SCORE: the frozen scorer
# special-cases `== "Fail"` and nothing else, so such an input would look
# structurally valid here while the scorer silently ignored it -- the exact
# hidden-semantics class C3-R6 exists to stop.  Inventing a propagation rule
# is equally forbidden.  It is therefore refused here with an explicit
# message, and retained instead in the C-5 observer record, where it is an
# observation rather than a scoring token.
# ---------------------------------------------------------------------------
CONTRACT = (
    Field("stages.ground_truth", "ab", True, "STAGE_VALUES",
          "frozen scorer: set(stages) must equal MANDATORY_STAGES"),
    Field("stages.sensor", "ab", True, "STAGE_VALUES",
          "frozen scorer: set(stages) must equal MANDATORY_STAGES"),
    Field("stages.collector", "ab", True, "STAGE_VALUES",
          "frozen scorer: set(stages) must equal MANDATORY_STAGES"),
    Field("rule_output", "ab", True, "RULE_VALUES",
          "frozen scorer: _need(record, 'rule_output')"),
    Field("runtime_contract", "ab", True, "RUNTIME_VALUES",
          "frozen scorer: _need(record, 'runtime_contract')"),
    Field("evidence_correlatable", "ab", True, BOOL_DOMAIN,
          "AMEND-002 Part A (5); frozen scorer reads it with a default of True, "
          "so an ABSENT field is silently a decision -- it must be written down"),
    Field("r_obs_05", "b", True, frozenset({"Pass", "Fail"}),
          "'Fail': contract SS4 ('R-OBS-05 is Fail') + AMEND-002 Part B (4) fix its "
          "scoring propagation. 'Pass': the frozen Range B expected result records it. "
          "No frozen source fixes the propagation of any other token"),
    Field("target_observation_absent", "ab", False, BOOL_DOMAIN,
          "scoring.md SS2/SS3; frozen scorer reads it with `is True`"),
    Field("sensor_capture", "ab", False, frozenset({"empty"}),
          "frozen scorer gives meaning to `== 'empty'` and to nothing else; "
          "a non-empty sensor capture is expressed by OMITTING the field"),
    Field("sensor_liveness", "ab", False, BOOL_DOMAIN,
          "AMEND-002 Part B (6); frozen scorer reads it with `not record.get(...)`"),
)

# `procedure_conformance` is excluded from derivation coverage on purpose: it
# is not a transcribed judgment but a verbatim copy of a machine-written
# artifact, and the frozen procedure_conformance.validate() already checks it
# field by field with an exact key set.
DERIVATION_EXCLUDED = ("procedure_conformance", "range")


def resolve_domain(field, semantics):
    if isinstance(field.domain, str) and field.domain != BOOL_DOMAIN:
        return frozenset(getattr(semantics, field.domain))
    return field.domain


def describe(semantics, range_key=None):
    """The contract as data.  Tests read THIS; they never restate it."""
    rows = []
    for field in CONTRACT:
        if range_key is not None and not field.applies_to(range_key):
            continue
        domain = resolve_domain(field, semantics)
        rows.append({
            "address": field.address,
            "ranges": field.ranges,
            "required": field.required,
            "domain": (BOOL_DOMAIN if domain == BOOL_DOMAIN
                       else sorted(domain)),
            "domain_source": (field.domain if isinstance(field.domain, str)
                              else "batch-2 structural addition"),
            "why": field.why,
        })
    return {
        "contract": "k8shakedown-scoring-input-contract/1",
        "placeholders": list(PLACEHOLDERS),
        "derivation_excluded": list(DERIVATION_EXCLUDED),
        "mandatory_stages": list(semantics.MANDATORY_STAGES),
        "fields": rows,
    }


# ---------------------------------------------------------------------------
# Dotted addressing (C3-R4 (2)).  `stages.ground_truth`, never a bare
# `ground_truth` -- a bare name is ambiguous the moment a second nested
# block exists, and the historical run that used bare names is exactly why
# this is fixed.
# ---------------------------------------------------------------------------
_MISSING = object()


def get_address(record, address):
    current = record
    for part in address.split("."):
        if not isinstance(current, dict) or part not in current:
            return _MISSING
        current = current[part]
    return current


def set_address(record, address, value):
    parts = address.split(".")
    current = record
    for part in parts[:-1]:
        current = current.setdefault(part, {})
    current[parts[-1]] = value


def same_value(left, right):
    """Strict equality.  Python's `True == 1`, so compare bool-ness too."""
    if isinstance(left, bool) != isinstance(right, bool):
        return False
    return left == right


def contains_placeholder(value):
    if isinstance(value, str):
        return value in PLACEHOLDERS
    if isinstance(value, dict):
        return any(contains_placeholder(v) for v in value.values())
    if isinstance(value, list):
        return any(contains_placeholder(v) for v in value)
    return False


def placeholder_addresses(value, prefix=""):
    found = []
    if isinstance(value, dict):
        for key, item in value.items():
            found.extend(placeholder_addresses(item, f"{prefix}{key}."))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(placeholder_addresses(item, f"{prefix}[{index}]."))
    elif isinstance(value, str) and value in PLACEHOLDERS:
        found.append(prefix.rstrip("."))
    return found


# ---------------------------------------------------------------------------
# Template (C3-R1 / C3-R2 / C3-R2b)
# ---------------------------------------------------------------------------
def build_template(semantics, range_key):
    """An INTENTIONALLY INCOMPLETE input.  It must fail the frozen scorer AND
    this validator: every judgment slot holds a placeholder, so nothing here
    can be mistaken for a default the tooling chose."""
    record = {
        "range": range_key.upper(),
        "_README": (
            "Template only. Fill every " + PLACEHOLDER + " by hand from the "
            "retained run evidence, BEFORE opening Study01/expected/. Record in "
            "`derivation` which artifact each value was read from. This file is "
            "intentionally not scorable as-is."
        ),
        "procedure_conformance": PROCEDURE_PLACEHOLDER,
    }
    derivation = {}
    for field in CONTRACT:
        if not field.applies_to(range_key):
            continue
        if field.required:
            set_address(record, field.address, PLACEHOLDER)
            derivation[field.address] = {
                "artifact": PLACEHOLDER,
                "value": PLACEHOLDER,
            }
    record["derivation"] = derivation
    record["_optional_fields"] = {
        field.address: field.why
        for field in CONTRACT
        if field.applies_to(range_key) and not field.required
    }
    return record


# ---------------------------------------------------------------------------
# Artifact resolution (C3-R4 (4))
# ---------------------------------------------------------------------------
def parse_manifest(manifest_path: Path):
    entries = {}
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        digest, _, relative = line.partition("  ")
        if not relative:
            raise ValueError(f"unparsable hashes.sha256 line: {line!r}")
        entries[relative] = digest
    return entries


def normalize_artifact(raw):
    """Return the run-relative POSIX path, or raise for anything unsafe."""
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError("artifact must be a non-empty string")
    candidate = raw.replace("\\", "/").strip()
    if candidate.startswith("/") or (len(candidate) > 1 and candidate[1] == ":"):
        raise ValueError(f"artifact must be run-relative, not absolute: {raw!r}")
    parts = [p for p in candidate.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise ValueError(f"artifact escapes the run evidence root: {raw!r}")
    if not parts:
        raise ValueError(f"artifact resolves to the run evidence root itself: {raw!r}")
    return "/".join(parts)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ---------------------------------------------------------------------------
# Validation (C3-R3: shape only, no semantic judgment)
# ---------------------------------------------------------------------------
def validate_record(record, range_key, semantics, run_evidence: Path,
                    finalize_snapshot: Path):
    problems = []

    for address in placeholder_addresses(record):
        problems.append(
            f"{address or '<root>'}: still holds a template placeholder. A template is "
            "intentionally not a completed scoring input.")

    declared = record.get("range")
    if declared != range_key.upper():
        problems.append(
            f"range: scoring input declares {declared!r} but was validated as "
            f"Range {range_key.upper()}")

    if "procedure_conformance" not in record:
        problems.append(
            "procedure_conformance: required -- the frozen scorer calls "
            "_need(record, 'procedure_conformance')")

    derivation = record.get("derivation")
    if not isinstance(derivation, dict) or not derivation:
        problems.append(
            "derivation: a non-empty object is required. An empty `derivation` "
            "records nothing and is refused.")
        derivation = {}

    expected_addresses = set()
    for field in CONTRACT:
        if not field.applies_to(range_key):
            continue
        value = get_address(record, field.address)
        domain = resolve_domain(field, semantics)

        if value is _MISSING:
            if field.required:
                problems.append(f"{field.address}: required for Range "
                                f"{range_key.upper()} -- {field.why}")
            continue

        expected_addresses.add(field.address)

        if domain == BOOL_DOMAIN:
            if not isinstance(value, bool):
                problems.append(
                    f"{field.address}: must be a JSON boolean, got {value!r}")
        elif value not in domain:
            extra = ""
            if field.address == "r_obs_05" and value == "Unresolved":
                extra = (" 'Unresolved' is a valid R-OBS-05 QUERY OUTCOME (contract SS3), "
                         "but no frozen source fixes what it propagates to in scoring: the "
                         "frozen scorer special-cases only == 'Fail'. Retain it in the C-5 "
                         "observer record and resolve the scoring value by hand.")
            problems.append(
                f"{field.address}: {value!r} is outside the accepted token domain "
                f"{sorted(domain)}.{extra}")

    for address in sorted(expected_addresses):
        if address in derivation:
            continue
        problems.append(
            f"derivation.{address}: missing. Every scored field must record the "
            "artifact it was read from and the value that was read.")

    for address in sorted(set(derivation) - expected_addresses):
        if address in DERIVATION_EXCLUDED:
            problems.append(
                f"derivation.{address}: {address} is excluded from derivation coverage "
                "(it is a verbatim machine-written record, not a transcribed judgment).")
        else:
            problems.append(
                f"derivation.{address}: addresses a field that is not part of the "
                f"Range {range_key.upper()} contract, or is not present in this input.")

    manifest = None
    manifest_path = run_evidence / "hashes.sha256"
    if not manifest_path.is_file():
        problems.append(
            f"hashes.sha256: not found at {manifest_path}. A scoring input is "
            "validated against a FINALIZED run, never a live one.")
    else:
        try:
            manifest = parse_manifest(manifest_path)
        except ValueError as exc:
            problems.append(f"hashes.sha256: {exc}")

    # The manifest identity check.  finalize-evidence can regenerate a manifest
    # from whatever the tree currently holds, so "listed in hashes.sha256" alone
    # cannot tell a genuinely retained artifact from one added later and
    # re-manifested.  The control-plane snapshot pins the manifest that actually
    # passed verify-integrity, so this reads "was in the FINALIZED manifest",
    # not merely "is in today's manifest".
    if manifest is not None:
        if not finalize_snapshot.is_file():
            problems.append(
                f"finalize identity snapshot: not found at {finalize_snapshot}. "
                "Without it the manifest cannot be shown to be the one that passed "
                "verify-integrity.")
        else:
            try:
                snapshot = json.loads(finalize_snapshot.read_text(encoding="utf-8-sig"))
            except json.JSONDecodeError as exc:
                snapshot = None
                problems.append(f"finalize identity snapshot: unparsable JSON ({exc})")
            if snapshot is not None:
                if snapshot.get("schema") != FINALIZE_IDENTITY_SCHEMA:
                    problems.append(
                        "finalize identity snapshot: unexpected schema "
                        f"{snapshot.get('schema')!r}")
                if snapshot.get("run_id") != run_evidence.name:
                    problems.append(
                        f"finalize identity snapshot: names run {snapshot.get('run_id')!r} "
                        f"but the evidence directory is {run_evidence.name!r}")
                actual_manifest_digest = sha256_file(manifest_path)
                if snapshot.get("hashes_sha256_digest") != actual_manifest_digest:
                    problems.append(
                        "finalize identity snapshot: hashes.sha256 has changed since "
                        "verify-integrity passed (snapshot "
                        f"{snapshot.get('hashes_sha256_digest')}, now "
                        f"{actual_manifest_digest}). The manifest this input is being "
                        "checked against is not the finalized one.")

    for address in sorted(expected_addresses & set(derivation)):
        entry = derivation[address]
        if not isinstance(entry, dict) or set(entry) != {"artifact", "value"}:
            problems.append(
                f"derivation.{address}: must be exactly "
                '{"artifact": ..., "value": ...}')
            continue
        recorded = entry["value"]
        actual = get_address(record, address)
        if not same_value(recorded, actual):
            problems.append(
                f"derivation.{address}: records value {recorded!r} but the scoring "
                f"input carries {actual!r}")
        try:
            relative = normalize_artifact(entry["artifact"])
        except ValueError as exc:
            problems.append(f"derivation.{address}: {exc}")
            continue
        target = run_evidence / relative
        if not target.is_file():
            problems.append(
                f"derivation.{address}: artifact {relative!r} does not exist under "
                f"{run_evidence}")
            continue
        if manifest is None:
            continue
        if relative not in manifest:
            problems.append(
                f"derivation.{address}: artifact {relative!r} is not covered by "
                "hashes.sha256, so it was not part of the finalized evidence.")
            continue
        digest = sha256_file(target)
        if digest != manifest[relative]:
            problems.append(
                f"derivation.{address}: artifact {relative!r} no longer hashes to its "
                f"manifest digest (manifest {manifest[relative]}, now {digest}).")

    return problems


def cmd_describe(args):
    semantics = frozen_semantics(args.scripts_dir)
    payload = describe(semantics, args.range.lower() if args.range else None)
    text = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)


def cmd_template(args):
    semantics = frozen_semantics(args.scripts_dir)
    record = build_template(semantics, args.range.lower())
    record["_schema"] = TEMPLATE_SCHEMA
    Path(args.output).write_text(
        json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"scoring-input template (Range {args.range.upper()}) written: {args.output}")
    print("It is intentionally NOT scorable: every judgment slot holds "
          f"{PLACEHOLDER}.")


def cmd_validate(args):
    semantics = frozen_semantics(args.scripts_dir)
    run_evidence = Path(args.run_evidence).resolve()
    snapshot = Path(args.finalize_snapshot).resolve()
    try:
        record = json.loads(Path(args.input).read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        print(f"scoring-input structural contract FAIL: unparsable JSON ({exc})",
              file=sys.stderr)
        return 1
    if not isinstance(record, dict):
        print("scoring-input structural contract FAIL: top level must be an object",
              file=sys.stderr)
        return 1

    problems = validate_record(record, args.range.lower(), semantics,
                               run_evidence, snapshot)
    report = {
        "contract": "k8shakedown-scoring-input-contract/1",
        "range": args.range.upper(),
        "input": str(Path(args.input).resolve()),
        "run_evidence": str(run_evidence),
        "structural_contract_pass": not problems,
        "problems": problems,
    }
    if args.output:
        Path(args.output).write_text(
            json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if problems:
        print(f"scoring-input structural contract FAIL ({len(problems)} problem(s)):",
              file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("scoring-input structural contract: PASS (shape and derivation only -- "
          "no scientific judgment was made or checked here)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scripts-dir", type=Path, default=default_scripts_dir(),
                        help="frozen Study01 scripts directory (value domains)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("describe", help="emit the contract as data")
    p.add_argument("--range", choices=("a", "b", "A", "B"))
    p.add_argument("--output")
    p.set_defaults(func=cmd_describe)

    p = sub.add_parser("emit-template", help="write an intentionally incomplete template")
    p.add_argument("--range", required=True, choices=("a", "b", "A", "B"))
    p.add_argument("--output", required=True)
    p.set_defaults(func=cmd_template)

    p = sub.add_parser("validate", help="check a completed scoring input's shape")
    p.add_argument("--range", required=True, choices=("a", "b", "A", "B"))
    p.add_argument("--input", required=True)
    p.add_argument("--run-evidence", required=True)
    p.add_argument("--finalize-snapshot", required=True)
    p.add_argument("--output")
    p.set_defaults(func=cmd_validate)

    args = parser.parse_args()
    result = args.func(args)
    sys.exit(result or 0)


if __name__ == "__main__":
    main()
