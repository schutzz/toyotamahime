# Deviations

None affecting the validation.

An initial derivation attempt asserted that the base manifest was LF-only and
aborted on that assertion before writing any file or invoking the validator. The
base manifest at the pinned commit is uniformly CRLF in the worktree, so the
derivation was corrected to detect and preserve the base manifest's own line
terminator. That attempt produced no retained artifact and no validator
invocation.

The recorded validation used the disposable worktree at the pinned commit and
the byte-preserving derivation described in `validation-command.md`.

The earlier K5 record `k5-range-c-20260824-001` was consulted for its retention
schema, and its committed bytes were checked from a fresh clone. Two of its eight
hash-manifest entries do not verify there, because its negative manifest and its
captured stderr were hashed as CRLF and normalized to LF on commit. That record is
historical and was not repaired, reinterpreted, or reused; the observation is noted
here only because it is why this validation retains its byte-exact artifacts under
an explicit `.gitattributes` pin.
