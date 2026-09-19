"""Executable transcription only. See protocol/c2-dnp3-*.md.

Apparatus constants used by the Docker-free execution preflight.  They carry
no scoring semantics; ``semantics.py`` remains the sole scoring transcription.
"""

# c2-dnp3-range-derivation.md §1
AMENONUBOCO_COMMIT = "80e550ffeab8daa6583590add490433a0305bb53"
BASE_MANIFEST = "manifests/power-grid-reference.yaml"

# c2-dnp3-sender-procedure.md §1
SENDER_ASSET = "studies/study-01-negative-result/experiments/shared/traffic/send_direct_operate.py"
SENDER_ASSET_SHA256 = "093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B"
SENDER_CONTAINER_PATH = "/study/traffic/send_direct_operate.py"

# c2-dnp3-capture-procedure.md §2-§5.  Each stage fixes its namespace, capture
# device, in-container pcap path, and the schema destination it exports to.
CAPTURE_IMAGE = "corfr/tcpdump@sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b"
CAPTURE_FILTER = "host 10.1.20.11 and host 10.1.10.10 and tcp port 20000"
# k6-r-obs-05-collector-query-contract.md §3's already-frozen bidirectional
# selector, as a BPF expression: the unrelated baseline DNP3 flow between
# cc_scada_master (10.1.10.10) and sub_c_rtu (10.1.40.10) over TCP/20000.
# AMEND-006.  CAPTURE_FILTER requires host 10.1.20.11 -- the target sender --
# in every retained frame, so a pcap produced with it can never contain a frame
# of this unrelated flow.  That is why the R-OBS-05 liveness evidence the
# contract's §5 correlation requires ("the separate R-OBS-05 tap_observer:eth0
# liveness pcap", and the "auxiliary liveness pcap" its §7 example names) has
# its own stage below rather than being read out of the Sensor pcap.
ROBS05_LIVENESS_FILTER = "host 10.1.10.10 and host 10.1.40.10 and tcp port 20000"
# c2-dnp3-capture-procedure.md §3: the Ground Truth device is the unique
# interface carrying this address, never an ordinal.
GATEWAY_CIDR = "10.1.20.254/24"
# The target-event capture stages.  Every run that is validated retains all of
# these (study01_collect.validate walks exactly this mapping), so a stage added
# here becomes mandatory evidence for Range A and Range B alike.
CAPTURE_STAGES = {
    "ground-truth": {
        "service": "wan_router",
        "container_pcap": "/data/c2-original-path.pcap",
        "artifact": "ground-truth/independent-capture/c2-original-path.pcap",
        "lifecycle": "ground-truth/independent-capture/capture-lifecycle.json",
        "context": "ground-truth/independent-capture/capture-context.json",
        "interface": None,  # resolved at runtime from 10.1.20.254/24
        "filter": CAPTURE_FILTER,
    },
    "sensor": {
        "service": "tap_observer",
        "container_pcap": "/data/c2-mirror-sensor.pcap",
        "artifact": "sensor-input/mirror-capture/c2-mirror-sensor.pcap",
        "lifecycle": "sensor-input/mirror-capture/capture-lifecycle.json",
        "context": "sensor-input/mirror-capture/capture-context.json",
        "interface": "eth0",
        "filter": CAPTURE_FILTER,
    },
}
# Auxiliary stages are deliberately NOT in CAPTURE_STAGES.  R-OBS-05 is Range B
# only (k6-r-obs-05-collector-query-contract.md §1), so its liveness capture must
# not become a mandatory artifact of every validated run -- putting it in
# CAPTURE_STAGES would silently make Range A require it too, which would change
# Range A's evidence requirements.  The capture tooling resolves a stage by name
# from ALL_CAPTURE_STAGES; study01_collect and study01_k7_normalize keep walking
# CAPTURE_STAGES, so the target-event requirement set is bit-for-bit what it was.
# The observation point is the same frozen tap_observer:eth0 mirror the Sensor
# stage uses; only the filter and the destination artifact differ, and the
# artifacts land under contract-output/, which is already one of the eight
# schema directories.
AUXILIARY_CAPTURE_STAGES = {
    "robs05-liveness": {
        "service": "tap_observer",
        "container_pcap": "/data/c2-robs05-liveness.pcap",
        "artifact": "contract-output/c2-robs05-liveness.pcap",
        "lifecycle": "contract-output/robs05-liveness-capture-lifecycle.json",
        "context": "contract-output/robs05-liveness-capture-context.json",
        "interface": "eth0",
        "filter": ROBS05_LIVENESS_FILTER,
    },
}
ALL_CAPTURE_STAGES = {**CAPTURE_STAGES, **AUXILIARY_CAPTURE_STAGES}
# Unchanged by AMEND-006: only the two target-event stages' in-container paths
# are probed for host-shell rewriting, so preflight's frozen probe list and the
# README-documented --path-probe invocation are untouched.
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
