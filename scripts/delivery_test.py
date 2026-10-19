"""Adversarial delivery checks in disposable repositories; no model or network."""

import copy
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

import canary
from processes import run
import release_artifacts as artifacts

ROOT = Path(__file__).resolve().parent.parent


def command(*args, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=True)
    return result.stdout.strip()


class CanaryTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="canary-tests-")
        self.addCleanup(self.work.cleanup)
        self.path = Path(self.work.name) / "claude"
        modes = '"manual", "auto", "dontAsk", "acceptEdits", "bypassPermissions", "plan"'
        help_text = "\n".join(canary.FLAGS) + "\n--permission-mode " + modes
        self.path.write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
mode = os.environ.get('CANARY_FIXTURE_MODE', '')
if args == ['--version']:
    print('99.0.0 (fixture)')
elif args == ['--help']:
    print('HELP_TEXT')
    sys.exit(1 if mode == 'help-fails' else 0)
elif mode == 'unrelated':
    print('credential database is unavailable')
    sys.exit(1)
elif mode == 'reject-undocumented' and '--max-turns' in args:
    print("error: unknown option '--max-turns'")
    sys.exit(1)
else:
    print("error: unknown option '--definitely-not-a-real-flag-xyz'")
    sys.exit(1)
'''.replace("'HELP_TEXT'", repr(help_text)))
        self.path.chmod(0o755)

    def check(self, mode=""):
        with patch.dict(os.environ, CANARY_FIXTURE_MODE=mode):
            canary.check(ROOT, str(self.path), True)

    def test_missing_cli_only_skips_in_optional_mode(self):
        missing = str(self.path) + "-absent"
        canary.check(ROOT, missing, False)
        with self.assertRaisesRegex(ValueError, "cannot be skipped"):
            canary.check(ROOT, missing, True)

    def test_expected_unknown_option_proves_parser_reached_sentinel(self):
        self.check()

    def test_unrelated_probe_failure_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "sentinel"):
            self.check("unrelated")

    def test_rejected_undocumented_flag_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "sentinel"):
            self.check("reject-undocumented")

    def test_failed_help_is_rejected_even_if_it_prints_flags(self):
        with self.assertRaisesRegex(ValueError, "--help failed"):
            self.check("help-fails")

    def test_probe_timeout_is_a_failure(self):
        with patch.object(canary, "run", side_effect=subprocess.TimeoutExpired("fixture", 15)):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.check()


class ArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="release-tests-")
        cls.root = Path(cls.temporary.name) / "repo"
        cls.root.mkdir()
        # Test the actual package, including its build graph, in isolation.
        for name in ("build.zig", "build.zig.zon", "src", "examples", "tests", "bench", "LICENSE", "README.md", "SECURITY.md", "CHANGELOG.md", "CONTRIBUTING.md"):
            source = ROOT / name
            if source.is_dir():
                shutil.copytree(source, cls.root / name)
            else:
                shutil.copy2(source, cls.root / name)
        command("git", "init", "-q", str(cls.root))
        command("git", "-C", str(cls.root), "add", ".")
        command("git", "-C", str(cls.root), "-c", "user.name=Delivery fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        cls.commit = command("git", "-C", str(cls.root), "rev-parse", "HEAD")
        cls.version, _ = artifacts.manifest_values((cls.root / "build.zig.zon").read_text())
        cls.original = Path(cls.temporary.name) / "original"
        with patch.dict(os.environ, {"RELEASE_SIGNING_KEY": ""}):
            artifacts.create(cls.root, cls.original, cls.version)
        cls.keys = Path(cls.temporary.name) / "keys"
        cls.keys.mkdir()
        for name in ("trusted", "wrong"):
            command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(cls.keys / name))
        cls.signers = cls.keys / "allowed_signers"
        cls.signers.write_text("fixture " + (cls.keys / "trusted.pub").read_text())

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.temporary_case = tempfile.TemporaryDirectory(dir=self.temporary.name)
        self.addCleanup(self.temporary_case.cleanup)
        self.dist = Path(self.temporary_case.name) / "dist"
        shutil.copytree(self.original, self.dist)
        self.name, self.archive, self.bom = artifacts.names(self.version)
        self.trust = patch.dict(os.environ, {"RELEASE_ALLOWED_SIGNERS": "", "RELEASE_SIGNER_IDENTITY": ""})
        self.trust.start()
        self.addCleanup(self.trust.stop)

    def verify(self, *, consumer=False, signature=False):
        artifacts.validate(self.root, self.dist, self.version, self.commit, signature, consumer)

    def sums(self):
        (self.dist / "SHA256SUMS").write_text("".join(f"{artifacts.sha256(self.dist / file)}  {file}\n" for file in (self.archive, self.bom)))

    def rewrite_bom(self, mutate):
        bom = json.loads((self.dist / self.bom).read_text())
        mutate(bom)
        (self.dist / self.bom).write_text(json.dumps(bom))
        self.sums()

    def rewrite_archive(self, mutate):
        with tarfile.open(self.dist / self.archive) as source:
            entries = [(copy.copy(member), source.extractfile(member).read() if member.isfile() else None) for member in source]
        entries = mutate(entries)
        with tarfile.open(self.dist / self.archive, "w:gz") as target:
            for member, data in entries:
                target.addfile(member, io.BytesIO(data) if data is not None else None)
        self.rewrite_bom(lambda bom: bom["components"][0].update(hashes=[{"alg": "SHA-256", "content": artifacts.sha256(self.dist / self.archive)}]))

    def sign(self, name):
        command("ssh-keygen", "-Y", "sign", "-f", str(self.keys / name), "-n", "file", str(self.dist / "SHA256SUMS"))

    def test_valid_archive_builds_as_a_separate_dependency(self):
        self.verify(consumer=True)

    def test_tampered_artifact_fails_checksum(self):
        with (self.dist / self.archive).open("ab") as file:
            file.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.verify()

    def test_incomplete_checksum_manifest_is_rejected(self):
        (self.dist / "SHA256SUMS").write_text(f"{artifacts.sha256(self.dist / self.archive)}  {self.archive}\n")
        with self.assertRaisesRegex(ValueError, "exactly both"):
            self.verify()

    def test_checksum_paths_cannot_escape_dist(self):
        with (self.dist / "SHA256SUMS").open("a") as file:
            file.write("0" * 64 + "  ../secret\n")
        with self.assertRaisesRegex(ValueError, "entry"):
            self.verify()

    def test_duplicate_checksum_entries_are_rejected(self):
        path = self.dist / "SHA256SUMS"
        path.write_text(path.read_text() + path.read_text().splitlines()[0] + "\n")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.verify()

    def test_missing_source_file_is_rejected(self):
        self.rewrite_archive(lambda entries: [(member, data) for member, data in entries if member.name != f"{self.name}/LICENSE"])
        with self.assertRaisesRegex(ValueError, "missing committed"):
            self.verify()

    def test_later_unsafe_or_unexpected_archive_entries_are_rejected(self):
        for path, reason in ((f"{self.name}/../escape", "unsafe"), ("/absolute", "unsafe"), ("wrong-prefix/file", "prefix"), (f"{self.name}/unexpected", "unexpected")):
            with self.subTest(path=path):
                shutil.copy2(self.original / self.archive, self.dist / self.archive)
                def append(entries):
                    member = tarfile.TarInfo(path)
                    member.size = 1
                    return entries + [(member, b"x")]
                self.rewrite_archive(append)
                with self.assertRaisesRegex(ValueError, reason):
                    self.verify()

    def test_link_entries_are_rejected(self):
        def add_link(entries):
            link = tarfile.TarInfo(f"{self.name}/link")
            link.type = tarfile.SYMTYPE
            link.linkname = "/etc/passwd"
            return entries + [(link, None)]
        self.rewrite_archive(add_link)
        with self.assertRaisesRegex(ValueError, "unsupported archive entry"):
            self.verify()

    def test_rehashed_modified_source_still_fails_trusted_commit(self):
        def change_source(entries):
            for member, data in entries:
                if member.name == f"{self.name}/LICENSE":
                    data = b"modified source"
                    member.size = len(data)
                yield member, data
        self.rewrite_archive(lambda entries: list(change_source(entries)))
        with self.assertRaisesRegex(ValueError, "differs from trusted commit"):
            self.verify()

    def test_wrong_component_version_is_rejected(self):
        self.rewrite_bom(lambda bom: bom["components"][0].update(version="99.0.0"))
        with self.assertRaisesRegex(ValueError, "component mismatch"):
            self.verify()

    def test_rehashed_wrong_or_missing_license_is_rejected(self):
        for licenses in ([{"expression": "MIT"}], [], None):
            with self.subTest(licenses=licenses):
                def change_license(bom):
                    component = bom["components"][0]
                    if licenses is None:
                        component.pop("licenses")
                    else:
                        component["licenses"] = licenses
                shutil.copy2(self.original / self.bom, self.dist / self.bom)
                self.rewrite_bom(change_license)
                with self.assertRaisesRegex(ValueError, "license mismatch"):
                    self.verify()

    def test_wrong_toolchain_commit_or_hash_is_rejected(self):
        for index, value in ((0, "0.1.0"), (2, "0" * 40)):
            with self.subTest(index=index):
                shutil.copy2(self.original / self.bom, self.dist / self.bom)
                self.rewrite_bom(lambda bom: bom["components"][0]["properties"][index].update(value=value))
                with self.assertRaisesRegex(ValueError, "toolchain, commit"):
                    self.verify()

    def test_duplicate_json_keys_are_rejected(self):
        path = self.dist / self.bom
        path.write_text(path.read_text().replace('"bomFormat":', '"bomFormat":"fake", "bomFormat":', 1))
        self.sums()
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            self.verify()

    def test_unsigned_integrity_passes_but_authenticated_mode_fails(self):
        self.verify()
        with self.assertRaisesRegex(ValueError, "requires RELEASE_ALLOWED_SIGNERS"):
            self.verify(signature=True)
        with patch.dict(os.environ, RELEASE_ALLOWED_SIGNERS=str(self.signers), RELEASE_SIGNER_IDENTITY="fixture"):
            with self.assertRaisesRegex(ValueError, "signature missing"):
                self.verify(signature=True)

    def test_trusted_signer_is_authenticated(self):
        self.sign("trusted")
        with patch.dict(os.environ, RELEASE_ALLOWED_SIGNERS=str(self.signers), RELEASE_SIGNER_IDENTITY="fixture"):
            self.verify(signature=True)

    def test_wrong_signer_is_rejected(self):
        self.sign("wrong")
        with patch.dict(os.environ, RELEASE_ALLOWED_SIGNERS=str(self.signers), RELEASE_SIGNER_IDENTITY="fixture"):
            with self.assertRaisesRegex(ValueError, "signature verification failed"):
                self.verify(signature=True)

    def test_comma_separated_principals_choose_a_single_default_identity(self):
        self.sign("trusted")
        signers = self.dist / "comma-allowed-signers"
        signers.write_text("fixture,other " + (self.keys / "trusted.pub").read_text())
        with patch.dict(os.environ, RELEASE_ALLOWED_SIGNERS=str(signers), RELEASE_SIGNER_IDENTITY=""):
            self.verify(signature=True)


class SupervisorTests(unittest.TestCase):
    def test_timeout_kills_descendants(self):
        with tempfile.TemporaryDirectory(prefix="supervisor-test-") as temporary:
            marker = Path(temporary) / "orphan"
            script = f"import subprocess,time; subprocess.Popen(['python3','-c',\"import pathlib,time; time.sleep(.5); pathlib.Path({str(marker)!r}).touch()\"]); time.sleep(10)"
            with self.assertRaises(subprocess.TimeoutExpired):
                run(["python3", "-c", script], timeout=.15)
            time.sleep(.7)
            self.assertFalse(marker.exists(), "timed-out command left a live descendant")


    def test_completed_leader_descendants_are_cleaned_before_reap(self):
        with tempfile.TemporaryDirectory(prefix="supervisor-test-") as temporary:
            marker = Path(temporary) / "orphan"
            script = f"import subprocess; subprocess.Popen(['python3','-c',\"import pathlib,time; time.sleep(.5); pathlib.Path({str(marker)!r}).touch()\"])"
            code, _ = run(["python3", "-c", script], timeout=2)
            self.assertEqual(code, 0)
            time.sleep(.7)
            self.assertFalse(marker.exists())

    def test_output_flood_is_stopped_before_deadline(self):
        start = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "exceeds 1 MiB"):
            run(["python3", "-c", "import os; b=b'x'*65536;\nwhile True: os.write(1,b)"], timeout=10)
        self.assertLess(time.monotonic() - start, 3)


class LiveConsentTests(unittest.TestCase):
    def test_live_model_use_requires_explicit_opt_in(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/live-compatibility.py")], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires explicit --allow-model-use", result.stderr)

    def test_excessive_or_invalid_live_budgets_fail_before_model_use(self):
        for option, value in (("--max-budget-usd", "1"), ("--max-budget-usd", "NaN"), ("--max-budget-usd", "0"), ("--timeout-seconds", "61"), ("--timeout-seconds", "nan")):
            with self.subTest(option=option, value=value):
                result = subprocess.run(["python3", str(ROOT / "scripts/live-compatibility.py"), "--allow-model-use", option, value], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)


class HookTests(unittest.TestCase):
    def test_distinct_ref_tips_only_and_cleanup_on_failure(self):
        with tempfile.TemporaryDirectory(prefix="hook-tests-") as temporary:
            work = Path(temporary)
            root = work / "repo"
            root.mkdir()
            command("git", "init", "-q", str(root))
            for value in ("first", "second", "third"):
                (root / "value").write_text(value)
                command("git", "-C", str(root), "add", ".")
                command("git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-qm", value)
                if value == "first":
                    first = command("git", "-C", str(root), "rev-parse", "HEAD")
            tip = command("git", "-C", str(root), "rev-parse", "HEAD")
            bin_dir = work / "bin"
            bin_dir.mkdir()
            log = work / "log"
            just = bin_dir / "just"
            just.write_text('#!/bin/sh\nsha=$(git rev-parse HEAD)\nprintf "%s\\n" "$sha" >> "$HOOK_LOG"\n[ "$sha" != "${FAIL_SHA:-}" ]\n')
            just.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"], HOOK_LOG=str(log))
            refs = f"refs/heads/main {tip} refs/heads/main {first}\nrefs/tags/test {tip} refs/tags/test {'0' * 40}\nrefs/heads/deleted {'0' * 40} refs/heads/deleted {first}\n"
            hook = ROOT / ".githooks/pre-push"
            result = subprocess.run(["sh", str(hook)], cwd=root, env=env, input=refs, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(log.read_text().splitlines(), [tip])
            self.assertEqual(command("git", "-C", str(root), "worktree", "list", "--porcelain").count("worktree "), 1)
            log.write_text("")
            result = subprocess.run(["sh", str(hook)], cwd=root, env=dict(env, FAIL_SHA=tip), input=refs, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(log.read_text().splitlines(), [tip])
            self.assertEqual(command("git", "-C", str(root), "worktree", "list", "--porcelain").count("worktree "), 1)


if __name__ == "__main__":
    unittest.main()
