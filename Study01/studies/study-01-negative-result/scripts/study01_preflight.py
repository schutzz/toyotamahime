#!/usr/bin/env python3
"""The K5 execution-stack acceptance gate, run before `docker compose up`.

It starts no container and sends no event.  Every attempt from `006` onward
failed on host orchestration that was decidable at this point; a run may not
proceed until every check passes.
"""
import argparse
import sys
from pathlib import Path

from study01 import preflight
from study01.frozen import apparatus

SCRIPTS_ROOT = Path(__file__).resolve().parent


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--run-id", required=True)
    p.add_argument("--worktree", type=Path, required=True, help="the fixed Amenonuboco worktree root")
    p.add_argument("--compose", type=Path, required=True, help="the generated Range A/B Compose file")
    p.add_argument("--run-evidence", type=Path, required=True)
    p.add_argument("--project-name", required=True, help="the Compose project name for this run")
    p.add_argument("--teardown-target", required=True, help="the project name the run will tear down")
    p.add_argument("--shell-probe", required=True, help='pass "$($PSVersionTable.PSVersion)"')
    p.add_argument("--path-probe", nargs="+", required=True, metavar="PATH",
                   help="the frozen in-container paths, passed as literals: "
                        + " ".join(apparatus.CONTAINER_PATH_PROBES))
    p.add_argument("--repo-root", type=Path, default=SCRIPTS_ROOT.parents[2],
                   help="the Kakuriyo repository root (default: derived from this script)")
    a = p.parse_args()

    try:
        checks = preflight.run(
            run_id=a.run_id, project_name=a.project_name, teardown_target=a.teardown_target,
            worktree=a.worktree, compose=a.compose, run_evidence=a.run_evidence,
            repo_root=a.repo_root, scripts_root=SCRIPTS_ROOT,
            shell_probe=a.shell_probe, path_probes=a.path_probe,
        )
    except OSError as exc:
        p.error(str(exc))

    for check in checks:
        print(check)
    failed = [check for check in checks if not check.ok]
    print(f"\nK5 execution preflight: {len(checks) - len(failed)}/{len(checks)} PASS")
    sys.stdout.flush()
    if failed:
        print(f"run {a.run_id} must not be provisioned; correct the apparatus and use a fresh run ID",
              file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
