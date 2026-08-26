# Validation Command

Executed from a disposable worktree detached at
`0378f8a32701b481e030f3db3d5f66ea471a4675`, with the worktree clean before
derivation and no tracked file modified by it:

```text
python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml
```

Working directory: the worktree root. Exit code `1`, retained as
`validator-output/exit-code.txt`. Standard output and standard error were
captured as raw bytes without newline translation and are retained under
`validator-output/`.

`validate` was the only command invoked against the manifest. No `docker compose
up`, no provisioning, and no container execution of any kind occurred; the
derived asset is rejected before deployment by design.

The negative asset was produced by byte-level substitution on the pinned base
manifest rather than by applying a stored patch, so that the retained patch
describes the derivation that actually happened. The substitution anchor was
required to occur exactly once, the base manifest was required to have uniform
line terminators, and the base was required not to declare an
`observability_contract` already; any of those failing aborts before a file is
written.

Tool versions are retained in `environment/versions.json`.
