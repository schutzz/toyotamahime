"""Docker-free acceptance checks for the K5 Pilot/Main execution stack.

Every check here is a pure function of retained host state.  None of them
starts Docker, provisions a range, or sends the selected event.  They exist
because attempts `006`, `008`, `009`, and `010` each failed on host-side
orchestration that was statically decidable before `docker compose up`.

A parse that finds nothing where the frozen apparatus requires something is a
failure, never a pass; the gate must not be satisfiable by an unreadable file.
"""
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

from .evidence_tree import NESTED_EXPORT_DIRS, RUNTIME_DIRS
from .frozen import apparatus

# The generated Compose file is machine-written with stable formatting.  Both
# the short and the long build form are accepted; an unparseable file fails.
_BUILD_SHORT = re.compile(r"^[ \t]+build:[ \t]+(\S[^\n]*?)[ \t]*$", re.M)
_BUILD_CONTEXT = re.compile(r"^[ \t]+context:[ \t]+(\S[^\n]*?)[ \t]*$", re.M)
# A bind mount whose source is a host path: `- <abs-or-relative>:<container>[:mode]`.
_BIND = re.compile(
    r"^[ \t]+-[ \t]+((?:[A-Za-z]:[\\/]|\.{1,2}[\\/])[^\n]*?):(/[^\n:]*)(?::[A-Za-z,]+)?[ \t]*$",
    re.M,
)


class Check:
    """One acceptance check outcome."""

    def __init__(self, name, ok, detail):
        self.name, self.ok, self.detail = name, ok, detail

    def __repr__(self):
        # ASCII only: this runs on consoles whose code page is not UTF-8.
        return f"[{'PASS' if self.ok else 'FAIL'}] {self.name}: {self.detail}"


def canonical_shell(shell_probe, environ=None):
    """The run must execute under PowerShell 7; MSYS must not be interposed."""
    environ = os.environ if environ is None else environ
    msystem = environ.get("MSYSTEM")
    if msystem:
        return Check("canonical shell", False,
                     f"MSYSTEM={msystem}; Git Bash/MSYS is unsupported, use {apparatus.CANONICAL_SHELL}")
    major = shell_probe.strip().split(".")[0]
    if major != str(apparatus.CANONICAL_SHELL_MAJOR):
        return Check("canonical shell", False,
                     f"shell probe reported {shell_probe!r}; {apparatus.CANONICAL_SHELL} is required")
    return Check("canonical shell", True, f"{apparatus.CANONICAL_SHELL} ({shell_probe.strip()})")


def container_path_probes(received):
    """Every in-container path must reach argv byte-identical.

    Attempt `009` lost its first sender invocation and both capture helpers to
    MSYS rewriting bare paths such as `/study/traffic/...` into a Windows path
    before `docker` ever saw them.  This probes that rewrite directly.
    """
    expected = list(apparatus.CONTAINER_PATH_PROBES)
    if list(received) != expected:
        return Check("container path probes", False,
                     f"host shell rewrote in-container paths: expected {expected}, received {list(received)}")
    return Check("container path probes", True, f"{len(expected)} paths reached argv unmodified")


def worktree_git(worktree):
    """`git` must be usable in the worktree, at the frozen commit, and clean."""
    def git(*args):
        return subprocess.run(("git", "-C", str(worktree)) + args, capture_output=True, text=True)

    head = git("rev-parse", "HEAD")
    if head.returncode != 0:
        return Check("worktree git usable", False, head.stderr.strip().splitlines()[0] if head.stderr.strip() else "git rev-parse failed")
    revision = head.stdout.strip()
    if revision != apparatus.AMENONUBOCO_COMMIT:
        return Check("worktree git usable", False,
                     f"worktree is at {revision}, frozen baseline is {apparatus.AMENONUBOCO_COMMIT}")
    status = git("status", "--porcelain")
    if status.returncode != 0:
        return Check("worktree git usable", False, "git status failed in the worktree")
    if status.stdout.strip():
        return Check("worktree git usable", False,
                     f"worktree is not clean ({len(status.stdout.strip().splitlines())} entries)")
    return Check("worktree git usable", True, f"clean at {revision}")


def run_workspace_placement(compose, worktree):
    """The generated Compose file's hardcoded `../` build contexts fix its depth."""
    try:
        relative = compose.resolve().parent.relative_to(worktree.resolve())
    except ValueError:
        return Check("run workspace placement", False, f"{compose} is not inside the worktree {worktree}")
    depth = len(relative.parts)
    if depth != apparatus.RUN_WORKSPACE_DEPTH:
        return Check("run workspace placement", False,
                     f"Compose sits {depth} level(s) below the worktree root ({relative.as_posix()}); "
                     f"the generated build contexts require exactly {apparatus.RUN_WORKSPACE_DEPTH}")
    return Check("run workspace placement", True, f"{relative.as_posix()}/ (depth {depth})")


def compose_build_contexts(compose):
    """Every build context must resolve, from the Compose file's own directory.

    A generated Range A/B Compose file always declares local protocol-image
    builds, so extracting none of them means the file is empty, truncated, or
    otherwise unreadable rather than build-free.  That is a failure: an
    unparseable file must not be able to satisfy this gate.
    """
    text = compose.read_text(encoding="utf-8")
    contexts = _BUILD_SHORT.findall(text) + _BUILD_CONTEXT.findall(text)
    if not contexts:
        return Check("compose build contexts", False,
                     "no build context could be parsed; a generated Range A/B Compose file always declares them")
    missing = [c for c in contexts if not (compose.parent / c).resolve().is_dir()]
    if missing:
        shown = ", ".join(f"{c} -> {(compose.parent / c).resolve()}" for c in sorted(set(missing)))
        return Check("compose build contexts", False, f"{len(missing)} unresolved: {shown}")
    return Check("compose build contexts", True, f"{len(contexts)} contexts resolve")


def compose_bind_sources(compose):
    """Every host-path bind-mount source must exist before provisioning."""
    text = compose.read_text(encoding="utf-8")
    sources = [s for s, _ in _BIND.findall(text)]
    missing = [s for s in sources if not (compose.parent / s).exists()]
    if missing:
        return Check("compose bind sources", False,
                     f"{len(missing)} missing: {', '.join(sorted(set(missing)))}")
    return Check("compose bind sources", True, f"{len(sources)} bind sources exist")


def sender_asset(repo_root):
    """The canonical sender asset must be present and match the frozen hash."""
    asset = repo_root / apparatus.SENDER_ASSET
    if not asset.is_file():
        return Check("sender asset", False, f"missing canonical asset {apparatus.SENDER_ASSET}")
    digest = hashlib.sha256(asset.read_bytes()).hexdigest().upper()
    if digest != apparatus.SENDER_ASSET_SHA256:
        return Check("sender asset", False, f"hash mismatch: {digest}")
    return Check("sender asset", True, f"{digest} matches the frozen value")


def evidence_tree(run_evidence):
    """The complete schema tree, including nested export destinations, must exist empty.

    Attempt `006` mis-built these paths and `008` omitted the nested capture
    export destinations, which only surfaced as a failed `docker cp` after the
    one permitted trigger had already been spent.
    """
    required = RUNTIME_DIRS + NESTED_EXPORT_DIRS
    missing = [name for name in required if not (run_evidence / name).is_dir()]
    if missing:
        return Check("evidence tree", False, f"missing {', '.join(missing)}")
    occupied = [name for name in required if any(p.is_file() for p in (run_evidence / name).rglob("*"))]
    if occupied:
        return Check("evidence tree", False, f"not a fresh run; artifacts already present in {', '.join(occupied)}")
    return Check("evidence tree", True, f"{len(required)} schema directories present and empty")


def _cli_offers(script, *options):
    # sys.executable, not "python": a venv or the py launcher can put a
    # different interpreter on PATH than the one running this gate.
    result = subprocess.run((sys.executable, str(script), "--help"), capture_output=True, text=True)
    return result.returncode == 0 and all(option in result.stdout for option in options)


def sender_wrapper(scripts_root):
    """The mandatory sender execution path must be runnable and still guarded."""
    script = scripts_root / "study01_sender.py"
    if not script.is_file():
        return Check("sender wrapper", False, "scripts/study01_sender.py is missing")
    if not _cli_offers(script, "--run-id", "--run-evidence"):
        return Check("sender wrapper", False, "study01_sender.py does not expose its required options")
    return Check("sender wrapper", True, "study01_sender.py is executable with its guarded interface")


def capture_wrapper(scripts_root):
    """The capture lifecycle must be executable through its retaining path."""
    script = scripts_root / "study01_capture.py"
    if not script.is_file():
        return Check("capture wrapper", False, "scripts/study01_capture.py is missing")
    if not _cli_offers(script, "resolve", "start", "stop-export"):
        return Check("capture wrapper", False, "study01_capture.py does not expose its lifecycle subcommands")
    return Check("capture wrapper", True, "study01_capture.py retains the helper lifecycle")


def scorer_wiring(scripts_root):
    """Offline scoring must still require the retained-evidence binding."""
    script = scripts_root / "study01_score.py"
    if not script.is_file():
        return Check("scorer wiring", False, "scripts/study01_score.py is missing")
    if not _cli_offers(script, "--run-evidence", "--output"):
        return Check("scorer wiring", False, "study01_score.py does not require --run-evidence")
    return Check("scorer wiring", True, "study01_score.py requires --run-evidence")


def project_name_binding(run_id, project_name, teardown_target, run_evidence):
    """One run ID names the project, the teardown target, and the evidence root."""
    mismatches = [f"{label}={value!r}" for label, value in
                  (("project", project_name), ("teardown", teardown_target), ("evidence", run_evidence.name))
                  if value != run_id]
    if mismatches:
        return Check("project name binding", False, f"run ID is {run_id!r} but {', '.join(mismatches)}")
    return Check("project name binding", True, f"project, teardown target, and evidence root all equal {run_id}")


def compose_integrity(compose):
    """Record the generated Compose hash; never gate cross-run equality on it.

    The generated file embeds absolute host bind-mount paths, so its SHA-256 is
    a function of the worktree's location.  It is a within-run integrity record.
    Reproducibility is carried by the structural checks above instead.
    """
    digest = hashlib.sha256(compose.read_bytes()).hexdigest().upper()
    return Check("compose integrity (record only)", True, f"SHA-256 {digest}")


def run(*, run_id, project_name, teardown_target, worktree, compose, run_evidence,
        repo_root, scripts_root, shell_probe, path_probes):
    """Return every check in fixed order.  The caller decides the exit status."""
    return [
        canonical_shell(shell_probe),
        container_path_probes(path_probes),
        worktree_git(worktree),
        run_workspace_placement(compose, worktree),
        compose_build_contexts(compose),
        compose_bind_sources(compose),
        sender_asset(repo_root),
        evidence_tree(run_evidence),
        sender_wrapper(scripts_root),
        capture_wrapper(scripts_root),
        scorer_wiring(scripts_root),
        project_name_binding(run_id, project_name, teardown_target, run_evidence),
        compose_integrity(compose),
    ]
