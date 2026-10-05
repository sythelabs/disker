import argparse
from dataclasses import dataclass
from pathlib import Path
import plistlib
import re
import subprocess


@dataclass(frozen=True)
class BundleVersion:
    marketing: str
    build: int


def parse_version(version: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError(f"Expected a stable major.minor.patch version, got {version!r}")
    major, minor, patch = version.split(".")
    return int(major), int(minor), int(patch)


def read_version(content: bytes) -> BundleVersion:
    metadata: dict[str, object] = plistlib.loads(content)
    marketing: object = metadata.get("CFBundleShortVersionString")
    build: object = metadata.get("CFBundleVersion")
    if not isinstance(marketing, str):
        raise ValueError("Info.plist must contain a string CFBundleShortVersionString")
    parse_version(marketing)
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Info.plist CFBundleVersion must be a positive integer string")
    return BundleVersion(marketing, int(build))


def validate_versions(current: BundleVersion, candidate: BundleVersion) -> BundleVersion:
    if parse_version(candidate.marketing) <= parse_version(current.marketing):
        raise ValueError(
            f"Version must increase from {current.marketing}; proposed {candidate.marketing}. "
            "Bump CFBundleShortVersionString in Info.plist."
        )
    if candidate.build <= current.build:
        raise ValueError(
            f"Build number must increase from {current.build}; proposed {candidate.build}. "
            "Bump CFBundleVersion in Info.plist."
        )
    return candidate


def main() -> None:
    parser: argparse.ArgumentParser = argparse.ArgumentParser()
    parser.add_argument("base_ref")
    args: argparse.Namespace = parser.parse_args()
    current: BundleVersion = read_version(subprocess.run(
        ["git", "show", f"{args.base_ref}:Info.plist"],
        check=True, capture_output=True,
    ).stdout)
    candidate: BundleVersion = validate_versions(current, read_version(Path("Info.plist").read_bytes()))
    print(
        f"Version increases from {current.marketing} to {candidate.marketing}; "
        f"build increases from {current.build} to {candidate.build}."
    )


if __name__ == "__main__":
    main()
