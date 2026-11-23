#!/usr/bin/env python3
"""Resolve the next four-part Windows release version."""

from __future__ import annotations

import argparse
import re


VERSION_PATTERN = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)\.(\d+)$")


def parse_version(value: str) -> tuple[int, int, int, int]:
    match = VERSION_PATTERN.fullmatch(value.strip())
    if match is None:
        raise ValueError(f"invalid four-part release version: {value!r}")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def format_version(parts: tuple[int, int, int, int]) -> str:
    return ".".join(str(part) for part in parts)


def next_version(latest: str | None, minimum: str) -> str:
    minimum_parts = parse_version(minimum)
    if latest is None or not latest.strip():
        return format_version(minimum_parts)

    latest_parts = parse_version(latest)
    if latest_parts < minimum_parts:
        return format_version(minimum_parts)

    major, minor, patch, build = latest_parts
    return format_version((major, minor, patch, build + 1))


def self_test() -> None:
    assert next_version(None, "v1.0.0.1") == "1.0.0.1"
    assert next_version("", "1.0.0.1") == "1.0.0.1"
    assert next_version("v0.9.9.9", "v1.0.0.1") == "1.0.0.1"
    assert next_version("v1.0.0.87", "v1.0.0.1") == "1.0.0.88"
    try:
        next_version("v1.0.0-beta", "v1.0.0.1")
    except ValueError:
        pass
    else:
        raise AssertionError("pre-release labels must be rejected")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--latest")
    parser.add_argument("--minimum", default="v1.0.0.1")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        print("next_release_version self-test passed")
        return

    print(next_version(args.latest, args.minimum))


if __name__ == "__main__":
    main()
