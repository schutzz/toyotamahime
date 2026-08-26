"""Executable transcription only. See protocol/scoring.md and amendments.md."""

# K3's Rule output is its own enum-valued field, not a Pass/Fail stage.
MANDATORY_STAGES = ("ground_truth", "sensor", "collector")
RANGES = {"A", "B", "C"}
STAGE_VALUES = {"Pass", "Fail", "Unresolved", "Invalid"}
RULE_VALUES = {"Alert", "No alert", "Error", "Unresolved", "Invalid"}
RUNTIME_VALUES = {"Pass", "Fail", "Unresolved", "Not applicable"}
CLASSIFICATIONS = {
    "Valid detection result", "Invalid negative result",
    "Inconclusive experiment", "Invalid run",
}
