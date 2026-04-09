"""Small, standalone helper utilities.

This module is intentionally decoupled from the running application.
Nothing imports it by default, so it does not change runtime behavior.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Iterable, Iterator, TypeVar

T = TypeVar("T")


def utc_timestamp() -> str:
    """Return the current UTC timestamp in ISO-8601 format."""
    return datetime.now(timezone.utc).isoformat()


def chunk_iterable(values: Iterable[T], size: int) -> Iterator[list[T]]:
    """Yield items from an iterable in fixed-size chunks."""
    if size <= 0:
        raise ValueError("size must be greater than 0")

    bucket: list[T] = []
    for value in values:
        bucket.append(value)
        if len(bucket) == size:
            yield bucket
            bucket = []

    if bucket:
        yield bucket


def safe_int(value: object, default: int = 0) -> int:
    """Convert a value to int, returning default on invalid input."""
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def unique_preserve_order(values: Iterable[T]) -> list[T]:
    """Return unique values while preserving the original order."""
    seen: set[T] = set()
    result: list[T] = []

    for value in values:
        if value not in seen:
            seen.add(value)
            result.append(value)

    return result
