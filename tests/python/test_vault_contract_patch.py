"""Byte-preservation tests for the versioned routing-section patcher.

The live index is a dirty working file: it holds unrelated uncommitted notes
before and after the owned section. The patcher therefore owns only the bytes
between its two markers, and every test here asserts that the prefix and suffix
bytes, the BOM state, and the line-ending style survive untouched.

No test writes outside the system temp directory, so the live Vault is never a
patch target here.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent.parent
PATCHER = REPO_ROOT / "scripts" / "patch-vault-routing-contract.py"
CONTRACT_PATH = REPO_ROOT / "contracts" / "vault-query-routing-contract.md"

# ``contracts/`` is not pinned in .gitattributes, so a Windows checkout with
# ``core.autocrlf=true`` may hold the source contract as CRLF. The patcher
# rewrites the section to the *target's* line-ending style either way, so the
# expected bytes are normalized here rather than assumed.
CONTRACT_LF = CONTRACT_PATH.read_bytes().replace(b"\r\n", b"\n")

START = b"<!-- hongs-vault-routing-contract:start -->"
END = b"<!-- hongs-vault-routing-contract:end -->"

PREFIX_LF = b"---\ntitle: index\ntags: [wiki]\n---\n"
SUFFIX_LF = b"\n# Index\n\n- uncommitted note kept verbatim\n- [[Niagara]]\n"


def to_crlf(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


class PatcherTestCase(unittest.TestCase):
    def setUp(self):
        import shutil

        self.tmp = Path(tempfile.mkdtemp(prefix="vault-patch-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.index = self.tmp / "index.md"

    def write_index(self, data: bytes) -> None:
        self.index.write_bytes(data)

    def run_patcher(self, *flags):
        return subprocess.run(
            [sys.executable, str(PATCHER), "--index", str(self.index),
             "--contract", str(CONTRACT_PATH), *flags],
            capture_output=True,
            text=True,
            timeout=120,
        )

    def apply(self):
        result = self.run_patcher("--apply")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        return self.index.read_bytes()

    def check(self):
        return self.run_patcher("--check")


class InsertionTests(PatcherTestCase):
    def test_inserts_after_frontmatter_and_preserves_surrounding_bytes(self):
        self.write_index(PREFIX_LF + SUFFIX_LF)
        patched = self.apply()

        self.assertTrue(patched.startswith(PREFIX_LF))
        self.assertTrue(patched.endswith(SUFFIX_LF))
        self.assertIn(CONTRACT_LF.strip(b"\n"), patched)
        self.assertEqual(1, patched.count(START))
        self.assertEqual(1, patched.count(END))
        self.assertLess(patched.index(START), patched.index(END))

    def test_inserts_at_top_when_there_is_no_frontmatter(self):
        body = b"# Index\n\n- note\n"
        self.write_index(body)
        patched = self.apply()
        self.assertTrue(patched.startswith(START))
        self.assertTrue(patched.endswith(body))

    def test_preserves_crlf_line_endings(self):
        self.write_index(to_crlf(PREFIX_LF) + to_crlf(SUFFIX_LF))
        patched = self.apply()

        self.assertNotIn(b"\n", patched.replace(b"\r\n", b""))
        self.assertIn(to_crlf(CONTRACT_LF).strip(b"\r\n"), patched)
        self.assertTrue(patched.startswith(to_crlf(PREFIX_LF)))
        self.assertTrue(patched.endswith(to_crlf(SUFFIX_LF)))

    def test_preserves_utf8_bom(self):
        self.write_index(b"\xef\xbb\xbf" + PREFIX_LF + SUFFIX_LF)
        patched = self.apply()
        self.assertTrue(patched.startswith(b"\xef\xbb\xbf" + PREFIX_LF))
        self.assertEqual(1, patched.count(b"\xef\xbb\xbf"))

    def test_preserves_non_ascii_neighbour_bytes(self):
        suffix = "\n메모: 커밋되지 않은 줄\n\n## 나머지\n- 유지되어야 함\n".encode("utf-8")
        self.write_index(PREFIX_LF + suffix)
        patched = self.apply()
        self.assertTrue(patched.startswith(PREFIX_LF))
        self.assertTrue(patched.endswith(suffix))

    def test_apply_is_idempotent(self):
        self.write_index(PREFIX_LF + SUFFIX_LF)
        once = self.apply()
        twice = self.apply()
        self.assertEqual(once, twice)


class ReplacementTests(PatcherTestCase):
    def stale_index(self) -> bytes:
        stale = START + b"\n## Query routing contract\n- contract-version: 0\n" + END
        return PREFIX_LF + b"\n" + stale + b"\n" + SUFFIX_LF

    def test_replaces_only_the_marked_section(self):
        self.write_index(self.stale_index())
        patched = self.apply()

        self.assertNotIn(b"contract-version: 0", patched)
        self.assertIn(b"contract-version: 1", patched)
        self.assertTrue(patched.startswith(PREFIX_LF + b"\n"))
        self.assertTrue(patched.endswith(b"\n" + SUFFIX_LF))
        self.assertEqual(1, patched.count(START))

    def test_replacement_is_idempotent(self):
        self.write_index(self.stale_index())
        once = self.apply()
        twice = self.apply()
        self.assertEqual(once, twice)


class CheckTests(PatcherTestCase):
    def test_check_fails_when_section_is_absent(self):
        self.write_index(PREFIX_LF + SUFFIX_LF)
        self.assertEqual(1, self.check().returncode)

    def test_check_fails_when_section_is_stale(self):
        stale = START + b"\n- contract-version: 0\n" + END
        self.write_index(PREFIX_LF + stale + SUFFIX_LF)
        self.assertEqual(1, self.check().returncode)

    def test_check_passes_after_apply(self):
        self.write_index(PREFIX_LF + SUFFIX_LF)
        self.apply()
        self.assertEqual(0, self.check().returncode)

    def test_check_passes_on_crlf_index(self):
        self.write_index(to_crlf(PREFIX_LF) + to_crlf(SUFFIX_LF))
        self.apply()
        self.assertEqual(0, self.check().returncode)

    def test_check_never_writes(self):
        self.write_index(PREFIX_LF + SUFFIX_LF)
        before = self.index.read_bytes()
        self.check()
        self.assertEqual(before, self.index.read_bytes())


class MalformedMarkerTests(PatcherTestCase):
    def assertRefused(self, data: bytes):
        self.write_index(data)
        for flag in ("--check", "--apply"):
            result = self.run_patcher(flag)
            self.assertEqual(2, result.returncode, flag)
            self.assertEqual(data, self.index.read_bytes())
            self.assertTrue(result.stderr.strip())

    def test_duplicate_sections_are_refused(self):
        section = START + b"\n- contract-version: 1\n" + END + b"\n"
        self.assertRefused(PREFIX_LF + section + section + SUFFIX_LF)

    def test_nested_markers_are_refused(self):
        self.assertRefused(
            PREFIX_LF + START + b"\n" + START + b"\n" + END + b"\n" + END + SUFFIX_LF
        )

    def test_missing_end_marker_is_refused(self):
        self.assertRefused(PREFIX_LF + START + b"\n- contract-version: 1\n" + SUFFIX_LF)

    def test_missing_start_marker_is_refused(self):
        self.assertRefused(PREFIX_LF + b"- contract-version: 1\n" + END + SUFFIX_LF)

    def test_reversed_markers_are_refused(self):
        self.assertRefused(PREFIX_LF + END + b"\n- x\n" + START + SUFFIX_LF)


class CliContractTests(PatcherTestCase):
    def test_requires_exactly_one_mode(self):
        self.write_index(PREFIX_LF + SUFFIX_LF)
        self.assertNotEqual(0, self.run_patcher().returncode)
        self.assertNotEqual(0, self.run_patcher("--check", "--apply").returncode)

    def test_missing_index_is_an_error(self):
        result = self.run_patcher("--check")
        self.assertEqual(2, result.returncode)


if __name__ == "__main__":
    unittest.main()
