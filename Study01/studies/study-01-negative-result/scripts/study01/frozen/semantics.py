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

# Range B R-OBS-05 observations that normalize Runtime contract to Unresolved.
# "Fail" comes from AMEND-002 Part B (4); "Unresolved" from AMEND-004. They stay
# distinct observations -- scoring.md section 20 defines them differently, and
# the retained record keeps whichever was observed. This set says only that both
# reach the same Runtime contract value, which is what AMEND-004 fixes.
#
# It is NOT the accepted token domain for the r_obs_05 field: "Pass" is a valid
# observation and is absent here because it normalizes nothing.
R_OBS_05_TO_RUNTIME_UNRESOLVED = {"Fail", "Unresolved"}
