#!/usr/bin/env python3
"""Prepare immutable artifacts first; publish them and the Sparkle feed second."""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPO = "Vt-mmm/agentwatch"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# SHA-1 of the self-signed "Agent Watch Signing" certificate (backup in ~/.config/agentwatch-signing).
SIGNING_IDENTITY = os.environ.get("AGENTWATCH_SIGNING_IDENTITY", "80D3F43941EFBF4012248EDE9DDA5A9F53F0F1CB")


def run(*args, capture=False):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip() if capture else subprocess.check_call(args, cwd=ROOT)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("action", choices=["prepare", "publish"])
    args = parser.parse_args()
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d?)\.(0|[1-9]\d?)", args.version):
        parser.error("Expected major.minor.patch; minor and patch must be below 100")
    version = args.version
    major, minor, patch = map(int, version.split("."))
    build = f"{major}{minor:02d}{patch:02d}"
    tag = "v" + version
    assert run("git", "branch", "--show-current", capture=True) == "main", "Release from main"
    assert not run("git", "status", "--porcelain", "--untracked-files=no", capture=True), "Commit tracked changes first"
    run("git", "fetch", "origin", "main")
    revision = run("git", "rev-parse", "HEAD", capture=True)
    assert revision == run("git", "rev-parse", "origin/main", capture=True), "Push source first"
    project = (ROOT / "project.yml").read_text()
    assert f'MARKETING_VERSION: "{version}"' in project and f'CURRENT_PROJECT_VERSION: "{build}"' in project
    notes = ROOT / "docs" / f"release-{version}.md"
    assert notes.is_file(), "Write release notes before packaging"
    public_key = re.search(r'SUPublicEDKey: "([^"]+)"', project).group(1)
    directory = ROOT / "Releases" / version
    manifest_path = directory / "release.json"
    zip_path = directory / f"AgentWatchMac-{version}.zip"

    def verify_signature(signature):
        run("swift", "scripts/verify-update.swift", public_key, signature, str(zip_path))

    if args.action == "prepare":
        previous = [int(e.text) for e in ET.parse(ROOT / "appcast.xml").iter(f"{{{NS}}}version")]
        assert not previous or int(build) > max(previous), "Build number must increase"
        assert not directory.exists(), "Artifact directory already exists; preserve it or choose a new version"
        directory.mkdir(parents=True)
        derived = ROOT / ".build" / "upstream-release"
        archive = directory / "AgentWatchMac.xcarchive"
        run("xcodegen", "generate")
        with (directory / "build.log").open("w") as log:
            subprocess.run(["xcodebuild", "-project", "AgentWatchMac.xcodeproj", "-scheme", "AgentWatchMac",
                            "-configuration", "Release", "-destination", "generic/platform=macOS",
                            "-derivedDataPath", str(derived), "-archivePath", str(archive), "-jobs", "2",
                            "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "archive"], cwd=ROOT,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        app = directory / "AgentWatchMac.app"
        run("ditto", str(archive / "Products/Applications/AgentWatchMac.app"), str(app))
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert info["CFBundleShortVersionString"] == version and info["CFBundleVersion"] == build
        assert info["CFBundleIdentifier"] == "com.vtamm.claudewatch.ClaudeWatchMac"
        assert info["SUPublicEDKey"] == public_key
        for binary in [app / "Contents/MacOS/AgentWatchMac", app / "Contents/Helpers/agentwatch"]:
            assert set(run("lipo", "-archs", str(binary), capture=True).split()) == {"arm64", "x86_64"}
        # A fixed certificate keeps the designated requirement stable, so Keychain
        # approvals survive updates (ad-hoc signing changes it on every build).
        run("codesign", "--force", "--deep", "--sign", SIGNING_IDENTITY, "--timestamp=none", str(app))
        run("codesign", "--verify", "--deep", "--strict", str(app))
        requirement = run("codesign", "-d", "-r-", str(app), capture=True)
        assert SIGNING_IDENTITY.lower() in requirement.lower(), "App is not signed with the stable certificate"
        shutil.copy2(app / "Contents/Helpers/agentwatch", directory / "agentwatch")
        run(str(directory / "agentwatch"), "--help")
        run("ditto", "-c", "-k", "--keepParent", str(app), str(zip_path))
        signer = derived / "SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
        signature = run(str(signer), "-p", str(zip_path), capture=True)
        verify_signature(signature)
        manifest = {"version": version, "build": build, "source_revision": revision,
                    "architectures": ["arm64", "x86_64"], "minimum_macos": "14.0",
                    "signature": signature, "length": zip_path.stat().st_size,
                    "notes_sha256": sha(notes),
                    "sha256": {p.name: sha(p) for p in [zip_path, directory / "agentwatch"]}}
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        checksums = dict(manifest["sha256"])
        checksums[manifest_path.name] = sha(manifest_path)
        (directory / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in checksums.items()))
        print(f"Prepared and verified {tag}; publish with: scripts/release.sh {version} publish")
        return

    manifest = json.loads(manifest_path.read_text())
    assert manifest["source_revision"] == revision and manifest["version"] == version
    assert manifest["notes_sha256"] == sha(notes)
    for name, expected in manifest["sha256"].items():
        assert sha(directory / name) == expected, f"Changed artifact: {name}"
    expected_sums = dict(manifest["sha256"])
    expected_sums[manifest_path.name] = sha(manifest_path)
    assert (directory / "SHA256SUMS").read_text() == "".join(f"{digest}  {name}\n" for name, digest in expected_sums.items())
    verify_signature(manifest["signature"])
    assets = [zip_path, directory / "agentwatch", manifest_path, directory / "SHA256SUMS"]
    existing_tag = subprocess.run(["git", "rev-parse", "--verify", tag + "^{commit}"], cwd=ROOT, capture_output=True, text=True)
    if existing_tag.returncode:
        run("git", "tag", "-a", tag, "-m", f"AgentWatch {version}", revision)
    else:
        assert existing_tag.stdout.strip() == revision, "Existing tag points at another commit"
    run("git", "push", "origin", tag)
    existing = subprocess.run(["gh", "release", "view", tag, "--repo", REPO, "--json", "isDraft"], capture_output=True, text=True)
    if existing.returncode:
        run("gh", "release", "create", tag, *(str(p) for p in assets), "--repo", REPO,
            "--verify-tag", "--draft", "--title", f"AgentWatch {version}", "--notes-file", str(notes))
    remote = json.loads(run("gh", "release", "view", tag, "--repo", REPO, "--json", "assets", capture=True))
    assert {a["name"]: a["digest"] for a in remote["assets"]} == {p.name: "sha256:" + sha(p) for p in assets}, "Uploaded assets differ"
    run("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest")
    appcast = ROOT / "appcast.xml"
    source = appcast.read_text()
    assert not any(e.text == version for e in ET.fromstring(source).iter(f"{{{NS}}}shortVersionString")), "Version already in feed"
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    item = f'''        <item>
            <title>Version {version}</title>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>{date}</pubDate>
            <enclosure url="https://github.com/{REPO}/releases/download/{tag}/{zip_path.name}" sparkle:edSignature="{manifest['signature']}" length="{manifest['length']}" type="application/octet-stream"/>
        </item>
'''
    assert source.count("<language>en</language>") == 1
    updated = source.replace("<language>en</language>\n", "<language>en</language>\n" + item, 1)
    ET.fromstring(updated)
    appcast.write_text(updated)
    run("git", "add", "appcast.xml")
    run("git", "commit", "-m", f"Publish Sparkle feed for {tag}")
    run("git", "push", "origin", "main")
    print(f"Published https://github.com/{REPO}/releases/tag/{tag} and Sparkle update feed")


if __name__ == "__main__":
    main()
