"""Machine-retained capture-helper lifecycle records.

Capture procedure §5 requires retaining the helper digest and container ID, the
target namespace ID, the interface resolution, and the command/log output.  Runs
up to and including `013` recorded those as operator prose in `verification.md`
while the primary output was never retained -- a gap present in `009` as well,
so it survived several cross-reviews.

Prose cannot be audited, and asking an operator to remember one more file has
already failed repeatedly on this class.  Every command below is therefore run
through this module, which stores the exact argv, exit code, stdout/stderr, and
UTC timestamp of each lifecycle step as structured evidence.
"""
import hashlib
import json
import os
import subprocess
from datetime import datetime, timedelta, timezone

from .evidence_io import write_text
from .frozen import apparatus

SCHEMA_VERSION = 1
STEPS = ("start", "listening-check", "window-end-liveness-check", "stop", "export", "remove")

# freeze-decision-table.md §3: the capture must cover [T0 - 5 s, T0 + 15 s].
WINDOW_LEAD = timedelta(seconds=5)
WINDOW_TAIL = timedelta(seconds=15)


class CaptureLifecycleError(ValueError):
    """A lifecycle step failed, or its retained record is absent or invalid."""


def _now():
    return datetime.now(timezone.utc).isoformat()


def run_step(name, argv):
    """Run one lifecycle command and return its fully retained record."""
    if name not in STEPS:
        raise CaptureLifecycleError(f"unknown lifecycle step: {name}")
    started = _now()
    completed = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    # Both ends are retained because they prove different things.  A step's
    # output only exists once the command returns, so evidence read from that
    # output must be timed by `completed_at`.  For `docker stop`, `timestamp` is
    # the point the stop was issued, which is the conservative end of that step.
    return {
        "step": name,
        "argv": list(argv),
        "timestamp": started,
        "completed_at": _now(),
        "exit_code": completed.returncode,
        "output": completed.stdout,
    }


def normalize_root(path):
    """One canonical spelling for a host path, so comparisons are exact."""
    return os.path.normcase(os.path.normpath(str(path)))


def export_destination(record):
    """The one destination `docker cp` may write, from the executing run root.

    This is execution provenance, not the verifier's location.  The retained
    `execution_run_root` is the tree the export actually wrote into, so the
    destination can be bound exactly without tying the record to wherever the
    evidence is checked out later.
    """
    return normalize_root(os.path.join(record["execution_run_root"], *record["artifact"].split("/")))


def expected_argv(record, step):
    """The frozen command for a step, derived from the record's own fields.

    Retaining an argv proves nothing unless it is bound to what the procedure
    fixes.  Every step is therefore reconstructed here and compared, so a record
    cannot claim a lifecycle it did not actually execute against this helper,
    this namespace, this interface, these frozen paths, and this evidence root.
    """
    name, pcap = record["helper_name"], record["container_pcap"]
    export = ["docker", "cp", f"{name}:{pcap}", export_destination(record)]
    return {
        "start": ["docker", "run", "-d", "--name", name,
                  "--network", f"container:{record['namespace_container_id']}",
                  "--cap-add", "NET_RAW", record["helper_image"],
                  "-i", record["interface"], "-nn", "-s", "0", "-w", pcap, record["filter"]],
        "listening-check": ["docker", "logs", name],
        "window-end-liveness-check": ["docker", "inspect", "--format", "{{.State.Running}}", name],
        "stop": ["docker", "stop", name],
        "export": export,
        "remove": ["docker", "container", "rm", name],
    }[step]


def new_record(run_id, stage, namespace_container, interface, run_root):
    stage_spec = apparatus.CAPTURE_STAGES[stage]
    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "execution_run_root": normalize_root(run_root),
        "stage": stage,
        "helper_name": f"{run_id}-{stage}-capture",
        "helper_image": apparatus.CAPTURE_IMAGE,
        "helper_container_id": None,
        "namespace_service": stage_spec["service"],
        "namespace_container_id": namespace_container,
        "interface": interface,
        "filter": apparatus.CAPTURE_FILTER,
        "container_pcap": stage_spec["container_pcap"],
        "artifact": stage_spec["artifact"],
        "pcap_sha256": None,
        "steps": [],
    }


def write(path, record):
    write_text(path, json.dumps(record, indent=2, sort_keys=True))


def pcap_sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(record, t0=None, context=None):
    """Validate a retained lifecycle record; unknown or partial states fail.

    When ``t0`` is supplied the retained timestamps must also prove the frozen
    event window was covered, rather than merely being well-formed.
    """
    required = {
        "schema_version", "run_id", "execution_run_root", "stage", "helper_name", "helper_image",
        "helper_container_id", "namespace_service", "namespace_container_id",
        "interface", "filter", "container_pcap", "artifact", "pcap_sha256", "steps",
    }
    if not isinstance(record, dict) or set(record) != required:
        raise CaptureLifecycleError("capture-lifecycle fields are incomplete or unknown")
    if record["schema_version"] != SCHEMA_VERSION:
        raise CaptureLifecycleError("unknown capture-lifecycle schema version")
    if record["stage"] not in apparatus.CAPTURE_STAGES:
        raise CaptureLifecycleError("unknown capture stage")
    spec = apparatus.CAPTURE_STAGES[record["stage"]]
    if record["helper_name"] != f"{record['run_id']}-{record['stage']}-capture":
        raise CaptureLifecycleError("helper name is not derived from this run ID and stage")
    if record["namespace_service"] != spec["service"]:
        raise CaptureLifecycleError("namespace service is not the frozen service for this stage")
    if record["container_pcap"] != spec["container_pcap"] or record["artifact"] != spec["artifact"]:
        raise CaptureLifecycleError("capture paths are not the frozen paths for this stage")
    if spec["interface"] is not None and record["interface"] != spec["interface"]:
        raise CaptureLifecycleError(f"this stage's capture device is frozen as {spec['interface']}")
    root = record["execution_run_root"]
    if isinstance(root, str) and root.strip():
        if not os.path.isabs(root):
            raise CaptureLifecycleError("execution_run_root must be an absolute host path")
        if normalize_root(root) != root:
            raise CaptureLifecycleError("execution_run_root is not in its canonical spelling")
        if os.path.basename(root) != normalize_root(record["run_id"]):
            raise CaptureLifecycleError("execution_run_root does not end in this run ID")
    if record["helper_image"] != apparatus.CAPTURE_IMAGE:
        raise CaptureLifecycleError("capture helper image is not the frozen digest")
    if record["filter"] != apparatus.CAPTURE_FILTER:
        raise CaptureLifecycleError("capture filter is not the frozen filter")
    for field in ("helper_container_id", "namespace_container_id", "interface", "pcap_sha256", "execution_run_root"):
        value = record[field]
        if not isinstance(value, str) or not value.strip():
            raise CaptureLifecycleError(f"{field} must be a non-empty string")

    steps = record["steps"]
    if not isinstance(steps, list) or [s.get("step") for s in steps if isinstance(s, dict)] != list(STEPS):
        raise CaptureLifecycleError("every lifecycle step must be retained exactly once, in order")
    at, done = {}, {}
    for step in steps:
        if set(step) != {"step", "argv", "timestamp", "completed_at", "exit_code", "output"}:
            raise CaptureLifecycleError("lifecycle step fields are incomplete or unknown")
        if not isinstance(step["argv"], list) or not step["argv"]:
            raise CaptureLifecycleError("lifecycle step argv must be retained")
        if type(step["exit_code"]) is not int or step["exit_code"] != 0:
            raise CaptureLifecycleError(f"lifecycle step {step['step']} did not succeed")
        if not isinstance(step["output"], str):
            raise CaptureLifecycleError("lifecycle step output must be retained")
        try:
            at[step["step"]] = datetime.fromisoformat(step["timestamp"].replace("Z", "+00:00"))
            done[step["step"]] = datetime.fromisoformat(step["completed_at"].replace("Z", "+00:00"))
        except (AttributeError, ValueError) as exc:
            raise CaptureLifecycleError("lifecycle step timestamp is not RFC3339") from exc
        if done[step["step"]] < at[step["step"]]:
            raise CaptureLifecycleError(f"lifecycle step {step['step']} completed before it started")

        # Every step, export included, must be exactly the frozen command.  The
        # export destination is bound to the retained `execution_run_root`, which
        # is execution provenance rather than the verifier's location, so this
        # stays true after a fresh checkout somewhere else.
        if step["argv"] != expected_argv(record, step["step"]):
            raise CaptureLifecycleError(f"retained {step['step']} argv is not the frozen command")

    # The helper ID must be what `docker run -d` printed, not an independent claim.
    started = next(s for s in steps if s["step"] == "start")
    printed = [line.strip() for line in started["output"].strip().splitlines() if line.strip()]
    if printed != [record["helper_container_id"]]:
        raise CaptureLifecycleError("helper_container_id is not the single ID the start command printed")

    listening = next(s for s in steps if s["step"] == "listening-check")
    if f"listening on {record['interface']}" not in listening["output"]:
        raise CaptureLifecycleError("retained output does not confirm the helper was listening")

    # A stop issued after the window closed only shows the capture was not asked
    # to stop early; it cannot exclude a helper that died inside the window.  The
    # liveness check is the primary record that closes that gap.
    liveness = next(s for s in steps if s["step"] == "window-end-liveness-check")
    if liveness["output"].strip() != "true":
        raise CaptureLifecycleError("retained output does not show the helper still running at the window end")
    if at["stop"] < done["window-end-liveness-check"]:
        raise CaptureLifecycleError("the helper was stopped before its liveness was confirmed")

    # JSON array order does not prove execution order; the retained instants must
    # describe a sequence that could actually have happened.
    for earlier, later in zip(STEPS, STEPS[1:]):
        if done[earlier] > at[later]:
            raise CaptureLifecycleError(
                f"{later} is timestamped before {earlier} completed "
                f"({at[later].isoformat()} < {done[earlier].isoformat()})")

    if t0 is not None:
        # Coverage is decided from retained timestamps, not from narrative prose.
        window_start, window_end = t0 - WINDOW_LEAD, t0 + WINDOW_TAIL
        # The listening line only exists once `docker logs` returned, so the
        # completion timestamp is the earliest moment that evidence is known.
        if done["listening-check"] > window_start:
            raise CaptureLifecycleError(
                f"capture was not confirmed listening before the window opened "
                f"({done['listening-check'].isoformat()} > {window_start.isoformat()})")
        # The window's far end is proven by observing the helper still running
        # at or after it, not by inferring from when the stop was issued.
        if at["window-end-liveness-check"] < window_end:
            raise CaptureLifecycleError(
                f"helper liveness was not observed at or after the window end "
                f"({at['window-end-liveness-check'].isoformat()} < {window_end.isoformat()})")

    if context is not None:
        # The runtime values inside the frozen argv must come from the retained
        # resolutions, not merely agree with one another.
        if context.get("run_id") != record["run_id"] or context.get("stage") != record["stage"]:
            raise CaptureLifecycleError("capture-context does not belong to this run and stage")
        if context.get("resolved_container_id") != record["namespace_container_id"]:
            raise CaptureLifecycleError("namespace container ID is not the one the Compose query resolved")
        if context.get("normalized_interface") != record["interface"]:
            raise CaptureLifecycleError("capture device is not the one the interface resolution selected")
    return record
