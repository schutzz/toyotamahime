"""Machine-retained provenance for the runtime values a capture helper uses.

Binding the helper's argv to frozen constants still leaves the *runtime* values
inside it unproven.  Cross-review of `6bbe7bc` showed a lifecycle record could
name any namespace container ID and, for Ground Truth, any interface, and pass:
the three fields agreed with each other but nothing tied them to the resolutions
the procedure requires.

This module retains those resolutions as primary output instead of prose:

* `docker compose ... ps -q <service>` and the container ID it printed; and
* for Ground Truth, `ip -br addr` inside that container, the lines matching the
  frozen gateway address, the unique-match count, the selected token, and its
  `@peer` normalization.

The lifecycle record's `namespace_container_id` and `interface` must then equal
what these commands actually produced.
"""
import json

from .evidence_io import write_text
from .frozen import apparatus

SCHEMA_VERSION = 1


class CaptureContextError(ValueError):
    """A capture-context record is absent, invalid, or unproven."""


def compose_argv(run_id, compose, service):
    return ["docker", "compose", "-p", run_id, "-f", str(compose), "ps", "-q", service]


def interface_argv(container_id):
    return ["docker", "exec", container_id, "sh", "-lc", "ip -br addr"]


def matching_tokens(raw_output):
    """The `ip -br addr` lines carrying the frozen gateway address."""
    return [line for line in raw_output.splitlines() if apparatus.GATEWAY_CIDR in line]


def normalize_device(token):
    """`eth6@if5890` names capture device `eth6`; a bare token is unchanged."""
    return token.split("@", 1)[0]


def write(path, record):
    write_text(path, json.dumps(record, indent=2, sort_keys=True))


def _step(record, field, extra=()):
    step = record[field]
    if not isinstance(step, dict) or set(step) != {"argv", "output", "exit_code", *extra}:
        raise CaptureContextError(f"{field} fields are incomplete or unknown")
    if type(step["exit_code"]) is not int or step["exit_code"] != 0:
        raise CaptureContextError(f"{field} did not succeed")
    if not isinstance(step["argv"], list) or not isinstance(step["output"], str):
        raise CaptureContextError(f"{field} argv and output must be retained")
    return step


def validate(record, run_id=None):
    """Validate a retained capture-context record; unproven states fail closed."""
    required = {
        "schema_version", "run_id", "stage", "namespace_service",
        "namespace_resolution", "resolved_container_id",
        "interface_resolution", "normalized_interface",
    }
    if not isinstance(record, dict) or set(record) != required:
        raise CaptureContextError("capture-context fields are incomplete or unknown")
    if record["schema_version"] != SCHEMA_VERSION:
        raise CaptureContextError("unknown capture-context schema version")
    if record["stage"] not in apparatus.CAPTURE_STAGES:
        raise CaptureContextError("unknown capture stage")
    if run_id is not None and record["run_id"] != run_id:
        raise CaptureContextError("capture-context run ID does not match this run")
    spec = apparatus.CAPTURE_STAGES[record["stage"]]
    if record["namespace_service"] != spec["service"]:
        raise CaptureContextError("namespace service is not the frozen service for this stage")

    resolution = _step(record, "namespace_resolution")
    expected = compose_argv(record["run_id"], "<compose>", record["namespace_service"])
    argv = resolution["argv"]
    if len(argv) != len(expected) or argv[:4] != expected[:4] or argv[4] != "-f" or argv[6:] != expected[6:]:
        raise CaptureContextError("namespace resolution is not the frozen Compose service query")
    resolved = record["resolved_container_id"]
    if not isinstance(resolved, str) or not resolved.strip():
        raise CaptureContextError("resolved_container_id must be a non-empty string")
    # The ID must be what the command actually printed, not an independent claim.
    printed = [line.strip() for line in resolution["output"].strip().splitlines() if line.strip()]
    if printed != [resolved]:
        raise CaptureContextError("resolved_container_id is not the single ID the Compose query printed")

    device = record["normalized_interface"]
    if not isinstance(device, str) or not device.strip():
        raise CaptureContextError("normalized_interface must be a non-empty string")

    if spec["interface"] is not None:
        # This stage's device is frozen, so no runtime resolution may be claimed.
        if record["interface_resolution"] is not None:
            raise CaptureContextError("this stage's capture device is frozen and takes no resolution")
        if device != spec["interface"]:
            raise CaptureContextError(f"this stage's capture device is frozen as {spec['interface']}")
        return record

    interface = _step(record, "interface_resolution",
                      ("matching_tokens", "match_count", "selected_token"))
    if interface["argv"] != interface_argv(resolved):
        raise CaptureContextError("interface resolution was not run inside the resolved namespace container")
    # Every derived value must follow from the retained output, not stand beside it.
    found = matching_tokens(interface["output"])
    if interface["matching_tokens"] != found:
        raise CaptureContextError("retained matching tokens do not follow from the retained output")
    if interface["match_count"] != len(found):
        raise CaptureContextError("retained match count does not follow from the retained output")
    if len(found) != 1:
        raise CaptureContextError(
            f"the frozen gateway address matched {len(found)} interfaces; a unique match is required")
    token = found[0].split()[0] if found[0].split() else ""
    if interface["selected_token"] != token:
        raise CaptureContextError("selected token is not the one the unique match names")
    if device != normalize_device(token):
        raise CaptureContextError("normalized_interface is not this token's capture device")
    return record
