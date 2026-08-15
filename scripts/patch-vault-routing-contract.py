#!/usr/bin/env python3
"""Insert or refresh the versioned routing-contract section of a Markdown index.

The target index is a live, dirty working file. This script therefore owns
exactly the bytes from the start marker through the end marker and nothing
else: the prefix, the suffix, the byte-order-mark state, and the line-ending
style of the target are all preserved verbatim. Anything ambiguous — duplicate,
nested, reversed, or unbalanced markers — is refused without writing.

Exit codes:

* ``0`` — ``--check`` found exactly one exact section, or ``--apply`` succeeded.
* ``1`` — ``--check`` found the section absent or stale.
* ``2`` — malformed markers, unusable arguments, or an unreadable file.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

START = b"<!-- hongs-vault-routing-contract:start -->"
END = b"<!-- hongs-vault-routing-contract:end -->"
BOM = b"\xef\xbb\xbf"

EXIT_OK = 0
EXIT_OUT_OF_SYNC = 1
EXIT_REFUSED = 2


class Refused(Exception):
    """The target or the contract cannot be patched unambiguously."""


def count(data: bytes, needle: bytes) -> int:
    return data.count(needle)


def locate_section(data: bytes, label: str):
    """Return ``(start, end)`` byte offsets, or ``None`` when absent."""
    starts = count(data, START)
    ends = count(data, END)
    if starts == 0 and ends == 0:
        return None
    if starts != 1 or ends != 1:
        raise Refused(
            "%s has %d start and %d end markers; exactly one balanced section is required"
            % (label, starts, ends)
        )
    start = data.index(START)
    end = data.index(END) + len(END)
    if start >= end - len(END):
        raise Refused("%s has the end marker before the start marker" % label)
    return start, end


def to_lf(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n")


def detect_eol(data: bytes) -> bytes:
    return b"\r\n" if b"\r\n" in data else b"\n"


def read_contract(path: Path) -> bytes:
    data = to_lf(path.read_bytes())
    if data.startswith(BOM):
        data = data[len(BOM):]
    bounds = locate_section(data, "contract file")
    if bounds is None:
        raise Refused("contract file has no routing contract section")
    start, end = bounds
    return data[start:end]


def frontmatter_end(body: bytes, eol: bytes) -> int:
    """Offset just past the closing frontmatter line, or 0 when there is none."""
    opener = b"---" + eol
    if not body.startswith(opener):
        return 0
    position = len(opener)
    while position < len(body):
        newline = body.find(eol, position)
        if newline == -1:
            return 0
        if body[position:newline].strip() in (b"---", b"..."):
            return newline + len(eol)
        position = newline + len(eol)
    return 0


def patched_bytes(data: bytes, section_lf: bytes):
    """Return ``(new_bytes, section_present)`` for the target file bytes."""
    bom = BOM if data.startswith(BOM) else b""
    body = data[len(bom):]
    eol = detect_eol(body)
    section = section_lf.replace(b"\n", eol)

    bounds = locate_section(body, "index")
    if bounds is None:
        offset = frontmatter_end(body, eol)
        new_body = body[:offset] + section + eol + body[offset:]
        return bom + new_body, False
    start, end = bounds
    return bom + body[:start] + section + body[end:], True


def section_is_current(data: bytes, section_lf: bytes) -> bool:
    body = data[len(BOM):] if data.startswith(BOM) else data
    bounds = locate_section(body, "index")
    if bounds is None:
        return False
    start, end = bounds
    return to_lf(body[start:end]) == section_lf


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--index", required=True, type=Path, help="Markdown index to patch")
    parser.add_argument(
        "--contract", required=True, type=Path, help="versioned contract source file"
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="verify only; never writes")
    mode.add_argument("--apply", action="store_true", help="insert or replace the section")
    args = parser.parse_args(argv)

    try:
        section_lf = read_contract(args.contract)
        data = args.index.read_bytes()
    except (Refused, OSError) as error:
        print("error: %s" % error, file=sys.stderr)
        return EXIT_REFUSED

    try:
        if args.check:
            if section_is_current(data, section_lf):
                print("in sync: %s" % args.index)
                return EXIT_OK
            print("error: %s is missing or stale" % args.index, file=sys.stderr)
            return EXIT_OUT_OF_SYNC

        new_data, present = patched_bytes(data, section_lf)
    except Refused as error:
        print("error: %s" % error, file=sys.stderr)
        return EXIT_REFUSED

    if new_data == data:
        print("unchanged: %s" % args.index)
        return EXIT_OK
    try:
        args.index.write_bytes(new_data)
    except OSError as error:
        print("error: %s" % error, file=sys.stderr)
        return EXIT_REFUSED
    print("%s: %s" % ("replaced" if present else "inserted", args.index))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
