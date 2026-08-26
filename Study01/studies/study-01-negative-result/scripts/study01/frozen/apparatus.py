"""Executable transcription only. See protocol/c2-dnp3-*.md.

Apparatus constants used by the Docker-free execution preflight.  They carry
no scoring semantics; ``semantics.py`` remains the sole scoring transcription.
"""

# c2-dnp3-range-derivation.md §1
AMENONUBOCO_COMMIT = "78fc17746b5d663fafec9dffe563d79fe9ea02b7"
BASE_MANIFEST = "manifests/power-grid-reference.yaml"

# c2-dnp3-sender-procedure.md §1
SENDER_ASSET = "studies/study-01-negative-result/experiments/shared/traffic/send_direct_operate.py"
SENDER_ASSET_SHA256 = "093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B"
SENDER_CONTAINER_PATH = "/study/traffic/send_direct_operate.py"

# c2-dnp3-capture-procedure.md §2-§5.  Each stage fixes its namespace, capture
# device, in-container pcap path, and the schema destination it exports to.
CAPTURE_IMAGE = "corfr/tcpdump@sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b"
CAPTURE_FILTER = "host 10.1.20.11 and host 10.1.10.10 and tcp port 20000"
# c2-dnp3-capture-procedure.md §3: the Ground Truth device is the unique
# interface carrying this address, never an ordinal.
GATEWAY_CIDR = "10.1.20.254/24"
CAPTURE_STAGES = {
    "ground-truth": {
        "service": "wan_router",
        "container_pcap": "/data/c2-original-path.pcap",
        "artifact": "ground-truth/independent-capture/c2-original-path.pcap",
        "lifecycle": "ground-truth/independent-capture/capture-lifecycle.json",
        "context": "ground-truth/independent-capture/capture-context.json",
        "interface": None,  # resolved at runtime from 10.1.20.254/24
    },
    "sensor": {
        "service": "tap_observer",
        "container_pcap": "/data/c2-mirror-sensor.pcap",
        "artifact": "sensor-input/mirror-capture/c2-mirror-sensor.pcap",
        "lifecycle": "sensor-input/mirror-capture/capture-lifecycle.json",
        "context": "sensor-input/mirror-capture/capture-context.json",
        "interface": "eth0",
    },
}
CAPTURE_CONTAINER_PATHS = tuple(s["container_pcap"] for s in CAPTURE_STAGES.values())

# c2-dnp3-sender-procedure.md §3.2.  `T0` defines the frozen event window, so it
# is retained as its own primary artifact rather than only as metadata prose.
T0_ARTIFACT = "metadata-t0.txt"

# Every in-container path the canonical procedures pass through the host shell.
# A host shell that rewrites any of them cannot execute a Pilot or Main run.
CONTAINER_PATH_PROBES = (SENDER_CONTAINER_PATH,) + CAPTURE_CONTAINER_PATHS

# K5 execution-stack correction.  The generated Compose file hardcodes
# `../protocol-images/<protocol>` build contexts, so the directory holding it
# must sit exactly one level below the fixed worktree root.  Attempt `010`
# placed it two levels below and Buildx resolved `runs/protocol-images/dnp3`.
RUN_WORKSPACE_DEPTH = 1

# The canonical procedures are written as PowerShell.  Git Bash / MSYS rewrites
# bare in-container paths and is unsupported for Pilot and Main execution.
CANONICAL_SHELL = "PowerShell 7"
CANONICAL_SHELL_MAJOR = 7
