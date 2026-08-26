"""Pure, offline Study 01 scorer."""
from .frozen.semantics import MANDATORY_STAGES, RANGES, RULE_VALUES, RUNTIME_VALUES, STAGE_VALUES
from .procedure_conformance import ProcedureConformanceError, validate as validate_procedure

class UncoveredSemanticState(ValueError):
    """The retained evidence reaches a state not decided by K3 + AMEND-002."""

def _need(record, key):
    if key not in record:
        raise UncoveredSemanticState(f"missing required retained field: {key}")
    return record[key]

def score(record):
    """Return a deterministic field score. Never queries a live system."""
    range_name = _need(record, "range")
    if range_name not in RANGES:
        raise UncoveredSemanticState("unknown range")
    if range_name == "C":
        return {"range": "C", "experiment_classification": None,
                "static_contract": _need(record, "static_contract"),
                "validator_result": _need(record, "validator_result")}

    try:
        procedure = validate_procedure(_need(record, "procedure_conformance"))
    except ProcedureConformanceError as exc:
        raise UncoveredSemanticState(f"invalid procedure-conformance input: {exc}") from exc

    stages = _need(record, "stages")
    if set(stages) != set(MANDATORY_STAGES):
        raise UncoveredSemanticState("mandatory stages must be complete")
    if any(stages[x] not in STAGE_VALUES for x in MANDATORY_STAGES):
        raise UncoveredSemanticState("unknown stage value")
    rule = _need(record, "rule_output")
    runtime = _need(record, "runtime_contract")
    if rule not in RULE_VALUES or runtime not in RUNTIME_VALUES:
        raise UncoveredSemanticState("unknown rule or runtime value")

    # AMEND-002 #4 and #6 normalize evidence before precedence is applied.
    out_stages = dict(stages)
    out_runtime = runtime
    if range_name == "B" and record.get("r_obs_05") == "Fail":
        out_runtime = "Unresolved"
    if range_name == "A" and record.get("sensor_capture") == "empty" and not record.get("sensor_liveness"):
        out_stages["sensor"] = "Unresolved"

    # AMEND-002 #1: Invalid > Inconclusive > R1/R2.
    if procedure["procedure_invalid"] or any(out_stages[x] == "Invalid" for x in MANDATORY_STAGES) or rule == "Invalid":
        classification = "Invalid run"
    elif (any(out_stages[x] == "Unresolved" for x in MANDATORY_STAGES)
          or rule in {"Unresolved", "Error"}  # #2
          or out_runtime == "Unresolved"
          or out_stages["ground_truth"] == "Fail"
          or not record.get("evidence_correlatable", True)):  # #5
        classification = "Inconclusive experiment"
    elif (out_stages["ground_truth"] == "Pass" and out_stages["sensor"] == "Pass"
          and out_stages["collector"] == "Pass" and out_runtime == "Pass"
          and rule in {"Alert", "No alert"}):
        classification = "Valid detection result"
    elif (out_stages["ground_truth"] == "Pass" and rule == "No alert"
          and out_runtime == "Fail" and record.get("target_observation_absent") is True):
        classification = "Invalid negative result"
    else:
        raise UncoveredSemanticState("K3 + AMEND-002 do not classify this retained state")
    return {"range": range_name, "stages": out_stages, "rule_output": rule,
            "procedure_invalid": procedure["procedure_invalid"],
            "runtime_contract": out_runtime, "experiment_classification": classification}
