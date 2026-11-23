#!/usr/bin/env python3
"""Inject one resolved release version into every product version source."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import tempfile

from next_release_version import parse_version


def replace_once(path: Path, pattern: str, replacement: str) -> None:
    original = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, original, flags=re.MULTILINE)
    if count != 1:
        raise RuntimeError(f"expected one version match in {path}, found {count}")
    path.write_text(updated, encoding="utf-8")


def prepare(root: Path, version: str) -> None:
    major, minor, patch, build = parse_version(version)
    flutter_version = f"{major}.{minor}.{patch}+{build}"
    tag = f"v{version}"

    replace_once(
        root / "pubspec.yaml",
        r"^version:\s*\d+\.\d+\.\d+\+\d+\s*$",
        f"version: {flutter_version}",
    )
    replace_once(
        root / "lib/features/updater/domain/app_update_config.dart",
        r"^\s*static const currentVersion = '[^']+';\s*$",
        f"  static const currentVersion = '{version}';",
    )
    replace_once(
        root / "lib/features/updater/domain/app_update_config.dart",
        r"^\s*static const currentVersionTag = '[^']+';\s*$",
        f"  static const currentVersionTag = '{tag}';",
    )
    replace_once(
        root / "installer/filmstoryboard.iss",
        r'^#define MyAppVersion "[^"]+"\s*$',
        f'#define MyAppVersion "{version}"',
    )


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "lib/features/updater/domain").mkdir(parents=True)
        (root / "installer").mkdir()
        (root / "pubspec.yaml").write_text("version: 1.0.0+7\n", encoding="utf-8")
        (root / "lib/features/updater/domain/app_update_config.dart").write_text(
            "  static const currentVersion = '1.0.0.7';\n"
            "  static const currentVersionTag = 'v1.0.0.7';\n",
            encoding="utf-8",
        )
        (root / "installer/filmstoryboard.iss").write_text(
            '#define MyAppVersion "1.0.0.7"\n', encoding="utf-8"
        )
        prepare(root, "1.0.0.8")
        assert "version: 1.0.0+8" in (root / "pubspec.yaml").read_text(encoding="utf-8")
        config = (root / "lib/features/updater/domain/app_update_config.dart").read_text(
            encoding="utf-8"
        )
        assert "currentVersion = '1.0.0.8'" in config
        assert "currentVersionTag = 'v1.0.0.8'" in config
        assert 'MyAppVersion "1.0.0.8"' in (
            root / "installer/filmstoryboard.iss"
        ).read_text(encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--version")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        print("prepare_release self-test passed")
        return
    if not args.version:
        parser.error("--version is required unless --self-test is used")

    prepare(args.root.resolve(), args.version)


if __name__ == "__main__":
    main()
