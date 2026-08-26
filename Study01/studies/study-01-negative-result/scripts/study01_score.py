#!/usr/bin/env python3
"""Score retained JSON evidence only; this command has no network or Docker client."""
import argparse, json
from pathlib import Path
from study01.scorer import score, UncoveredSemanticState

def main():
    p = argparse.ArgumentParser()
    p.add_argument("evidence", type=Path); p.add_argument("--run-evidence", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    try:
        scoring_input = json.loads(a.evidence.read_text(encoding="utf-8"))
        procedure_path = a.run_evidence / "ground-truth" / "procedure-conformance.json"
        procedure = json.loads(procedure_path.read_text(encoding="utf-8"))
        if "procedure_conformance" not in scoring_input:
            raise UncoveredSemanticState("scoring input lacks procedure_conformance")
        if scoring_input["procedure_conformance"] != procedure:
            raise UncoveredSemanticState("scoring-input procedure_conformance differs from retained evidence")
        result = score(scoring_input)
    except (OSError, json.JSONDecodeError, UncoveredSemanticState) as exc:
        p.error(str(exc))
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
if __name__ == "__main__": main()
