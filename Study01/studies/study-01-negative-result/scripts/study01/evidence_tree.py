"""Create the frozen runtime evidence-directory skeleton without Docker."""
from pathlib import Path

RUNTIME_DIRS = ("environment", "ground-truth", "sensor-input", "collector-output", "rule-output", "contract-output")
NESTED_EXPORT_DIRS = ("ground-truth/independent-capture", "sensor-input/mirror-capture")

def create(root: Path) -> tuple[Path, ...]:
    """Create only schema-defined run directories; returns their exact paths."""
    root.mkdir(parents=True, exist_ok=False)
    paths = tuple(root / name for name in RUNTIME_DIRS + NESTED_EXPORT_DIRS)
    for path in paths:
        path.mkdir()
    return paths
