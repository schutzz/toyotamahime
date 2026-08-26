"""The only sanctioned way to write text into a run evidence tree.

Run `013` finalized `hashes.sha256` over CRLF bytes produced by the host shell,
and `.gitattributes` (`* text=auto eol=lf`) normalized those files to LF on
commit, so `verify-integrity` failed against a clean checkout: 24 of 28 entries
mismatched.  One file was worse than a plain CRLF conversion because it had been
written with mixed endings.

Every text artifact is therefore written here with LF endings and a single
trailing newline, so the bytes that are hashed are the bytes the repository
retains.  Binary artifacts such as pcaps are copied byte-for-byte and never pass
through this module.
"""
from pathlib import Path


def write_text(path, text):
    """Write LF-only UTF-8 text with exactly one trailing newline."""
    body = text.replace("\r\n", "\n").replace("\r", "\n").rstrip("\n")
    Path(path).write_bytes((body + "\n").encode("utf-8"))


def write_lines(path, lines):
    """Write an iterable of lines under the same rules."""
    write_text(path, "\n".join(str(line).replace("\r\n", "\n").replace("\r", "\n") for line in lines))
