#!/usr/bin/env python3
"""Create one run's evidence tree, exactly as the preflight gate requires it.

The schema is `study01.evidence_tree.create` and nothing else: this wrapper
adds no directory of its own and hardcodes no name, so a directory the gate
requires can never be missing here while being present there.  Formal attempt
`k8-repro-20260918-001` was stopped by exactly that gap -- the two nested
capture-export destinations exist in `create()` and are checked by the gate,
but no published command created them, so they were hand-built from the
schema document's tree diagram and the gate failed 12/13.

Creating the tree is a pre-provisioning step, like the gate itself: it starts
no container, sends no event, and writes nothing outside the run's own
evidence root.  It refuses to touch an existing directory -- a fresh run ID
gets a fresh tree, and reusing one is a protocol violation the gate would
reject anyway (`not a fresh run`).
"""
import argparse
from pathlib import Path

from study01.evidence_tree import create


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--run-evidence", type=Path, required=True,
                   help="the run's evidence root, e.g. "
                        "<attempt>/evidence/main-runs/range-a/<run-id>")
    a = p.parse_args()

    try:
        created = create(a.run_evidence)
    except FileExistsError:
        p.error(f"{a.run_evidence} already exists; use a fresh run ID rather than reusing a tree")
    except OSError as exc:
        p.error(str(exc))

    for path in created:
        print(path)
    print(f"\n{len(created)} schema directories created under {a.run_evidence}")


if __name__ == "__main__":
    main()
