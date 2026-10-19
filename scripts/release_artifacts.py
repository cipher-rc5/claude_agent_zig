#!/usr/bin/env python3
"""Create and validate local release artifacts using only the Python stdlib."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import tempfile
import uuid

from processes import run

MAX_ARCHIVE_BYTES = 64 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args]).decode().strip()


def manifest_values(data):
    def field(name):
        found = re.findall(r'^\s*\.' + name + r'\s*=\s*"([^"\n]+)"', data, re.M)
        require(len(found) == 1, f"manifest must have exactly one .{name}")
        return found[0]
    require(re.search(r'\.dependencies\s*=\s*\.\{\s*\}', data), "manifest has dependencies absent from SBOM")
    return field("version"), field("minimum_zig_version")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def names(version):
    require(re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", version), "invalid version")
    name = f"claude_agent_zig-{version}"
    return name, f"{name}.tar.gz", f"{name}.cdx.json"


def create(root, dist, version):
    name, archive_name, bom_name = names(version)
    manifest_version, toolchain = manifest_values((root / "build.zig.zon").read_text())
    require(manifest_version == version, "manifest version mismatch")
    require(git(root, "status", "--porcelain") == "", "working tree must be clean")
    code, actual_zig = run(["zig", "version"], cwd=root)
    require(code == 0 and actual_zig.strip() == toolchain, "Zig toolchain mismatch")
    commit = git(root, "rev-parse", "HEAD")
    dist.mkdir(parents=True, exist_ok=True)
    archive = dist / archive_name
    subprocess.run(["git", "-C", str(root), "archive", "--format=tar.gz", f"--prefix={name}/", "-o", str(archive.resolve()), commit], check=True)
    ref = f"pkg:github/cipher-rc5/claude_agent_zig@v{version}"
    bom = {
        "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tools": [{"name": "scripts/release.sh", "version": commit}],
            "component": {"type": "library", "name": "claude_agent_zig", "version": version},
        },
        "components": [{
            "type": "library", "bom-ref": ref, "name": "claude_agent_zig", "version": version,
            "purl": ref, "licenses": [{"expression": "LicenseRef-Proprietary"}],
            "hashes": [{"alg": "SHA-256", "content": sha256(archive)}],
            "properties": [{"name": key, "value": value} for key, value in (
                ("zig:version", toolchain), ("zig:minimum_zig_version", toolchain),
                ("git:commit", commit), ("dependencies", "none"),
            )],
        }],
        "dependencies": [{"ref": ref, "dependsOn": []}],
    }
    (dist / bom_name).write_text(json.dumps(bom, indent=2) + "\n")
    (dist / "SHA256SUMS").write_text("".join(f"{sha256(dist / file)}  {file}\n" for file in (archive_name, bom_name)))
    (dist / "SHA256SUMS.sig").unlink(missing_ok=True)
    if key := os.environ.get("RELEASE_SIGNING_KEY"):
        code, output = run(["ssh-keygen", "-Y", "sign", "-f", key, "-n", "file", str(dist / "SHA256SUMS")], cwd=root)
        require(code == 0, f"signing failed: {output}")
    print(f"release: artifacts written to {dist}; commit {commit}")


def load_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result
    require(path.stat().st_size <= 1024 * 1024, "SBOM exceeds 1 MiB")
    return json.loads(path.read_text(), object_pairs_hook=unique)


def validate(root, dist, version, expected_commit, require_signature=False, consumer=True):
    name, archive_name, bom_name = names(version)
    for file in (archive_name, bom_name, "SHA256SUMS"):
        require((dist / file).is_file() and not (dist / file).is_symlink(), f"missing or linked artifact: {file}")
    require((dist / "SHA256SUMS").stat().st_size <= 4096, "checksum manifest exceeds 4 KiB")
    require((dist / archive_name).stat().st_size <= MAX_ARCHIVE_BYTES, "compressed archive exceeds size limit")
    require((dist / bom_name).stat().st_size <= 1024 * 1024, "SBOM exceeds 1 MiB")
    sums = (dist / "SHA256SUMS").read_text()
    expected = {}
    for line in sums.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\s]+)", line)
        require(match is not None, "invalid checksum manifest entry")
        digest, file = match.groups()
        require(file not in expected, f"duplicate checksum entry: {file}")
        expected[file] = digest
    require(set(expected) == {archive_name, bom_name}, "checksum manifest must cover exactly both artifacts")
    for file, digest in expected.items():
        require(sha256(dist / file) == digest, f"checksum mismatch: {file}")
    require(re.fullmatch(r"[0-9a-f]{40,64}", expected_commit), "expected commit must be a full object id")
    require(git(root, "rev-parse", f"{expected_commit}^{{commit}}") == expected_commit, "expected commit unavailable")
    # Source membership comes from the explicitly trusted commit, not the tarball.
    tree = subprocess.check_output(["git", "-C", str(root), "ls-tree", "-rz", expected_commit]).decode()
    blobs = {}
    for record in tree.split("\0"):
        if not record:
            continue
        header, path = record.split("\t", 1)
        mode, kind, digest = header.split()
        require(kind == "blob" and mode in ("100644", "100755"), f"unsupported committed file: {path}")
        blobs[path] = (mode, digest)
    tracked = set(blobs)
    dirs = {str(parent) for path in tracked for parent in PurePosixPath(path).parents if str(parent) != "."}
    seen_files, seen_dirs = set(), set()
    with tarfile.open(dist / archive_name, "r:gz") as archive:
        total = 0
        for index, member in enumerate(archive):
            require(index < 10000, "too many archive entries")
            path = member.name.rstrip("/")
            parts = path.split("/")
            require(not path.startswith("/") and "\\" not in path and all(part not in ("", ".", "..") for part in parts), f"unsafe archive path: {member.name!r}")
            require(parts[0] == name, f"unexpected archive prefix: {member.name!r}")
            require(member.isfile() or member.isdir(), f"unsupported archive entry: {member.name!r}")
            relative = "/".join(parts[1:])
            if member.isdir():
                require(relative in dirs or relative == "", f"unexpected archive directory: {relative}")
                require(relative not in seen_dirs, f"duplicate archive directory: {relative}")
                seen_dirs.add(relative)
            else:
                require(relative in tracked, f"unexpected archive file: {relative}")
                require(relative not in seen_files, f"duplicate archive file: {relative}")
                seen_files.add(relative)
                require(not (member.mode & 0o7000), f"unsafe archive permissions: {relative}")
                total += member.size
                require(total <= MAX_ARCHIVE_BYTES, "archive exceeds expanded size limit")
                mode, expected_blob = blobs[relative]
                require(bool(member.mode & 0o111) == (mode == "100755"), f"archive executable mode mismatch: {relative}")
                digest = hashlib.sha1() if len(expected_commit) == 40 else hashlib.sha256()
                digest.update(f"blob {member.size}\0".encode())
                source = archive.extractfile(member)
                for block in iter(lambda: source.read(65536), b""):
                    digest.update(block)
                require(digest.hexdigest() == expected_blob, f"archive source differs from trusted commit: {relative}")
        require(seen_files == tracked, "archive is missing committed source files")
        # Compare manifests to the trusted commit as well as the SBOM.
        source = archive.extractfile(f"{name}/build.zig.zon")
        require(source is not None, "archive manifest missing")
        manifest = source.read().decode()
        manifest_version, toolchain = manifest_values(manifest)
        require(manifest_version == version, "archive manifest version mismatch")
        bom = load_json(dist / bom_name)
        require(bom["bomFormat"] == "CycloneDX" and bom["specVersion"] == "1.5" and bom["version"] == 1, "invalid CycloneDX header")
        require(bom["serialNumber"].startswith("urn:uuid:"), "invalid SBOM serial number")
        uuid.UUID(bom["serialNumber"].removeprefix("urn:uuid:"))
        datetime.strptime(bom["metadata"]["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
        metadata = bom["metadata"]
        require(metadata["component"] == {"type": "library", "name": "claude_agent_zig", "version": version}, "SBOM metadata component mismatch")
        require(metadata["tools"] == [{"name": "scripts/release.sh", "version": expected_commit}], "SBOM producer commit mismatch")
        require(len(bom["components"]) == 1, "SBOM must describe exactly one component")
        component = bom["components"][0]
        ref = f"pkg:github/cipher-rc5/claude_agent_zig@v{version}"
        require(component["name"] == "claude_agent_zig" and component["type"] == "library" and component["version"] == version, "SBOM component mismatch")
        require(component["purl"] == ref and component["bom-ref"] == ref, "SBOM package reference mismatch")
        require(component.get("licenses") == [{"expression": "LicenseRef-Proprietary"}], "SBOM license mismatch")
        require(component["hashes"] == [{"alg": "SHA-256", "content": expected[archive_name]}], "SBOM archive hash mismatch")
        properties = component["properties"]
        require(len(properties) == 4, "SBOM property set mismatch")
        require({prop["name"]: prop["value"] for prop in properties} == {
            "zig:version": toolchain, "zig:minimum_zig_version": toolchain,
            "git:commit": expected_commit, "dependencies": "none",
        }, "SBOM toolchain, commit, or dependency mismatch")
        require(bom["dependencies"] == [{"ref": ref, "dependsOn": []}], "SBOM dependency graph mismatch")
        allowed = os.environ.get("RELEASE_ALLOWED_SIGNERS")
        signature = dist / "SHA256SUMS.sig"
        require(not require_signature or allowed, "authenticated verification requires RELEASE_ALLOWED_SIGNERS")
        if allowed:
            require(signature.is_file() and not signature.is_symlink(), "signature missing")
            identities = [line.split()[0] for line in Path(allowed).read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]
            require(identities, "allowed signers file has no identities")
            identity = os.environ.get("RELEASE_SIGNER_IDENTITY") or identities[0].split(",", 1)[0]
            with (dist / "SHA256SUMS").open("rb") as checksums:
                code, output = run(["ssh-keygen", "-Y", "verify", "-f", allowed, "-I", identity, "-n", "file", "-s", str(signature)], stdin=checksums)
            require(code == 0, f"signature verification failed: {output.strip()}")
        if consumer:
            code, actual_zig = run(["zig", "version"])
            require(code == 0 and actual_zig.strip() == toolchain, "consumer requires the archived Zig toolchain")
            with tempfile.TemporaryDirectory(prefix="claude-release-consumer-") as temporary:
                work = Path(temporary)
                # Every entry was checked before any extraction occurs.
                archive.extractall(work, filter="data")
                consumer_build(work, name, dist / archive_name)
    assurance = "signature authenticated" if allowed else "integrity only; signature NOT authenticated"
    print(f"release-verify: PASS — every archive entry, checksums, structured SBOM, and source commit verified; {assurance}")


def consumer_build(work, name, archive):
    consumer = work / "consumer"
    consumer.mkdir()
    (consumer / "build.zig.zon").write_text('.{ .name = .release_consumer, .version = "0.0.0", .fingerprint = 0x2b5bec46852c9801, .dependencies = .{ .agent = .{ .path = "../' + name + '" } }, .paths = .{""} }\n')
    (consumer / "build.zig").write_text('''const std = @import("std");
pub fn build(b: *std.Build) void {
    const dependency = b.dependency("agent", .{});
    const module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = b.graph.host });
    module.addImport("agent", dependency.module("agent"));
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = module });
    b.installArtifact(exe);
}
''')
    (consumer / "main.zig").write_text('''const std = @import("std");
const agent = @import("agent");
pub fn main(init: std.process.Init) !void {
    const client = try agent.Client.open(init.gpa, init.io, .{});
    defer _ = client.close();
    try client.send("consumer compile only");
    if (try client.next()) |event| {
        var owned = event;
        owned.deinit();
    }
    _ = client.status();
    _ = try client.terminate(10);
}
''')
    code, output = run(["zig", "build"], cwd=consumer, timeout=180)
    require(code == 0, f"extracted package consumer failed: {output}")
    (consumer / "build.zig.zon").write_text('.{ .name = .release_consumer, .version = "0.0.0", .fingerprint = 0x2b5bec46852c9801, .dependencies = .{}, .paths = .{""} }\n')
    packages = work / "packages"
    code, output = run(["zig", "fetch", "--pkg-dir", str(packages), "--save-exact=agent", archive.as_uri()], cwd=consumer, timeout=120)
    require(code == 0, f"local archive fetch failed: {output}")
    fetched_manifest = (consumer / "build.zig.zon").read_text()
    require(re.search(r'\.hash\s*=\s*"[A-Za-z0-9_.-]+"', fetched_manifest), "fetch did not save a package hash")
    code, output = run(["zig", "build", "--pkg-dir", str(packages)], cwd=consumer, timeout=180)
    require(code == 0, f"hash-addressed archive consumer failed: {output}")
    print("release-verify: separate extracted and hash-addressed consumers compiled actual lifecycle calls (not executed)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "verify"))
    parser.add_argument("version")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--dist", type=Path)
    parser.add_argument("--commit", help="trusted source commit; defaults to local HEAD")
    parser.add_argument("--require-signature", action="store_true")
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        dist = (args.dist or root / "dist").resolve()
        if args.action == "create":
            create(root, dist, args.version)
        else:
            validate(root, dist, args.version, args.commit or git(root, "rev-parse", "HEAD"), args.require_signature)
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, subprocess.SubprocessError, RuntimeError) as error:
        print(f"release-{args.action}: FAIL — {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
