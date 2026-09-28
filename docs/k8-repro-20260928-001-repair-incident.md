# k8-repro-20260928-001 repair-session evidence-handling incident

## Scope

Self-reported process incident during post-failure repair activity for formal K8-3 attempt `k8-repro-20260928-001`. This is not a scientific, protocol, scorer, or bootstrap change, and is not an amendment under `amendments.md` (no research-significant condition is affected).

## Facts

- Attempt: `k8-repro-20260928-001`
- Attempt status: `FAILED` / `CLOSED` (unaffected by this incident; see below)
- Repair-session working location at the time: `C:\K8\attempts\k8-repro-20260928-001\toyotamahime\...` (the attempt's own retained clone) — this was a mistake; that path is the attempt's retained evidence tree, not a repair workspace.
- During documentation-repair work for the Range A decode-verification knowledge leak (see `docs/k8-packaging-certification.md` and the decode fix committed separately as `c408db6`), two tracked files inside that path were edited directly:
  - `Study01/README.md`
  - `Study01/studies/study-01-negative-result/protocol/c2-dnp3-capture-procedure.md`
- Effect: the live (unpacked) copies of those two files transiently diverged from the content `manifest.sha256` (part of the attempt's retained evidence) recorded for them. `manifest.sha256` verification for those two entries transiently reported `FAILED`.
- The attempt's already-created ZIP archive (`k8-repro-20260928-001.zip`, immutable, created at close time) was at no point opened, extracted into, or rewritten by this incident.

## Detection and restoration

1. Detected by re-running `sha256sum -c manifest.sha256` against the live directory.
2. Restored both files' working-tree content from the original commit `c726d34ac4f67f34b0b24927cc7856e6d57813ca` (`git checkout c726d34 -- <2 files>`), inside that same clone.
3. Re-ran `sha256sum -c manifest.sha256`: `611/611 PASS`.
4. Independently recomputed the archive's SHA-256; it matched the recorded value, confirming the ZIP was never touched.
5. Deleted the stray local branch/commit created in that clone during the mistaken edit, and returned `HEAD` to its original detached state at `c726d34`.
6. All subsequent repair work (documentation fix, this incident record) was moved to a separate clone, `C:\K8\repair\toyotamahime`, outside any attempt directory.

## Classification

| Field | Value |
| --- | --- |
| Incident class | retained-evidence handling / chain-of-custody process incident |
| Failed attempt working evidence tree transiently modified | YES |
| Modification persisted | NO |
| Manifest-covered contents restored | YES |
| Manifest re-verification | PASS, 611/611 |
| Formal ZIP archive modified | NO |
| Formal ZIP archive SHA-256 | `a9e8db8d8262163c1717424dd438b275450cc475dd71c94897b4d99ac0b229ea` (unchanged) |
| Formal attempt status impact | NONE — remains `FAILED` / `CLOSED`, unrepaired, unretried |
| Scientific/protocol/scorer/bootstrap change | NONE |

## Preventive control

`C:\K8\attempts\` must be treated as read-only during any future repair activity. Repair, documentation, and validation work belongs in a separate workspace under `C:\K8\repair\...`, never inside an attempt's own retained clone.
