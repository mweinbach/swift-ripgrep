#!/usr/bin/env python3
"""Install a verified upstream ripgrep release for local and CI comparisons."""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import re
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path


TARGETS = {
    ("linux", "x86_64"): "x86_64-unknown-linux-musl.tar.gz",
    ("linux", "aarch64"): "aarch64-unknown-linux-musl.tar.gz",
    ("darwin", "x86_64"): "x86_64-apple-darwin.tar.gz",
    ("darwin", "aarch64"): "aarch64-apple-darwin.tar.gz",
    ("windows", "x86_64"): "x86_64-pc-windows-msvc.zip",
    ("windows", "aarch64"): "aarch64-pc-windows-msvc.zip",
}


def normalized_platform() -> tuple[str, str]:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if machine in {"amd64", "x64"}:
        machine = "x86_64"
    elif machine in {"arm64", "arm64e"}:
        machine = "aarch64"
    return system, machine


def download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "swift-ripgrep-ci"})
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="15.2.0")
    parser.add_argument("--destination", required=True)
    args = parser.parse_args()

    system, machine = normalized_platform()
    try:
        suffix = TARGETS[(system, machine)]
    except KeyError as error:
        raise SystemExit(f"unsupported host for upstream rg: {system}/{machine}") from error

    asset = f"ripgrep-{args.version}-{suffix}"
    base = f"https://github.com/BurntSushi/ripgrep/releases/download/{args.version}"
    destination = Path(args.destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="swift-rg-install-") as temp_name:
        temp = Path(temp_name)
        archive = temp / asset
        checksum_file = temp / f"{asset}.sha256"
        print(f"Downloading {asset}", flush=True)
        download(f"{base}/{asset}", archive)
        download(f"{base}/{asset}.sha256", checksum_file)
        checksum_text = checksum_file.read_text(encoding="utf-8")
        checksum_match = re.search(r"(?im)^[0-9a-f]{64}$", checksum_text)
        if checksum_match is None:
            raise SystemExit(f"could not parse SHA-256 file for {asset}")
        expected = checksum_match.group(0).lower()
        actual = sha256(archive)
        if actual != expected:
            raise SystemExit(f"SHA-256 mismatch for {asset}: expected {expected}, got {actual}")

        extract_root = temp / "extract"
        extract_root.mkdir()
        if asset.endswith(".zip"):
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(extract_root)
        else:
            with tarfile.open(archive, "r:gz") as bundle:
                bundle.extractall(extract_root, filter="data")

        executable_name = "rg.exe" if system == "windows" else "rg"
        matches = list(extract_root.rglob(executable_name))
        if len(matches) != 1:
            raise SystemExit(f"expected one {executable_name} in {asset}, found {len(matches)}")
        installed = destination / executable_name
        shutil.copy2(matches[0], installed)
        installed.chmod(installed.stat().st_mode | 0o111)
        print(installed)

        github_path = os.environ.get("GITHUB_PATH")
        if github_path:
            with Path(github_path).open("a", encoding="utf-8") as output:
                output.write(str(destination) + "\n")


if __name__ == "__main__":
    main()
