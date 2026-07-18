#!/usr/bin/env python3
"""Extract test counts from an Xcode 26 xcresulttool summary."""

from __future__ import annotations

import json
import math
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

COUNT_FIELDS = ("passedTests", "failedTests", "skippedTests")


def numeric(value: Any) -> int | None:
    """Return a non-negative integer JSON number, rejecting booleans/strings."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, float) and math.isfinite(value) and value.is_integer() and value >= 0:
        return int(value)
    return None


def dictionaries(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from dictionaries(child)
    elif isinstance(value, list):
        for child in value:
            yield from dictionaries(child)


def count_values(candidate: dict[str, Any]) -> tuple[int, int, int] | None:
    values = tuple(numeric(candidate.get(name)) for name in COUNT_FIELDS)
    if not all(value is not None for value in values):
        return None
    # The all() check narrows the values after numeric() validation.
    return (values[0], values[1], values[2])  # type: ignore[return-value]


def find_counts(payload: Any) -> tuple[dict[str, Any], tuple[int, int, int]] | None:
    """Find aggregate counts, preferring the root or device configurations."""
    if isinstance(payload, dict):
        root_counts = count_values(payload)
        if root_counts is not None:
            return payload, root_counts

        configurations = payload.get("devicesAndConfigurations")
        if isinstance(configurations, list):
            configuration_counts = [
                count_values(configuration)
                for configuration in configurations
                if isinstance(configuration, dict)
            ]
            if configuration_counts and all(count is not None for count in configuration_counts):
                aggregate = tuple(sum(count[index] for count in configuration_counts) for index in range(3))
                return payload, aggregate  # type: ignore[arg-type]

    for candidate in dictionaries(payload):
        values = count_values(candidate)
        if values is not None:
            return candidate, values
    return None


def extract(path: Path) -> tuple[str, int, int, int]:
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"unable to read test summary JSON: {error}") from error

    found = find_counts(payload)
    if found is None:
        raise ValueError("test summary does not contain numeric passed/failed/skipped counts")

    candidate, (passed, failed, skipped) = found
    total = numeric(candidate.get("totalTestCount"))
    if total is None and candidate is not payload:
        total = numeric(payload.get("totalTestCount"))
    expected_failures = numeric(candidate.get("expectedFailures")) or 0
    executed = total if total is not None else passed + failed + skipped + expected_failures
    result = candidate.get("result", payload.get("result", "Unavailable"))
    if not isinstance(result, str) or not result:
        result = "Unavailable"
    return result, executed, failed, skipped


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} SUMMARY_JSON", file=sys.stderr)
        return 2
    try:
        result, executed, failed, skipped = extract(Path(sys.argv[1]))
    except ValueError as error:
        print(f"Coverage summary unavailable: {error}", file=sys.stderr)
        return 1
    print(f"{result}\t{executed}\t{failed}\t{skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
