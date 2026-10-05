"""JSON conversion for the dashboard API.

Rules (docs/Dashboard_Implementation_Spec.md section 11.1)
    - timestamps keep their offset; the connection runs in Australia/Sydney,
      so every timestamptz arrives as Sydney time;
    - intervals become {"seconds": n, "display": "1 d 4 h 12 m"};
    - numeric becomes a JSON number; NULL stays null;
    - big integer identifiers are cast to text in SQL (``::text``) so the
      browser never rounds them.
"""

from __future__ import annotations

import datetime as dt
import decimal
import json
import uuid

SYDNEY = "Australia/Sydney"


def interval(value: dt.timedelta) -> dict:
    seconds = int(value.total_seconds())
    sign = "-" if seconds < 0 else ""
    rest = abs(seconds)
    days, rest = divmod(rest, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, secs = divmod(rest, 60)
    parts = []
    if days:
        parts.append(f"{days} d")
    if hours:
        parts.append(f"{hours} h")
    if minutes:
        parts.append(f"{minutes} min")
    if not parts:
        parts.append(f"{secs} s")
    return {"seconds": seconds, "display": sign + " ".join(parts)}


def _default(value):
    if isinstance(value, dt.datetime):
        return value.isoformat()
    if isinstance(value, dt.date):
        return value.isoformat()
    if isinstance(value, dt.timedelta):
        return interval(value)
    if isinstance(value, decimal.Decimal):
        return float(value) if value != value.to_integral_value() else int(value)
    raise TypeError(f"Cannot serialise {type(value).__name__}")


def dumps(payload) -> bytes:
    return json.dumps(payload, default=_default, ensure_ascii=False).encode("utf-8")


def envelope(data, *, read_at, database: str, scope: str | None = None,
             provenance: list[str] | None = None, warnings: list[str] | None = None) -> dict:
    return {
        "data": data,
        "meta": {
            "read_at": read_at,
            "timezone": SYDNEY,
            "database": database,
            "scope": scope,
            "provenance": provenance or [],
            "warnings": warnings or [],
        },
    }


def error(status: int, code: str, message: str, *, detail=None) -> dict:
    body = {"error": {"status": status, "code": code, "message": message}}
    if detail is not None:
        body["error"]["detail"] = detail
    return body


def error_id() -> str:
    return uuid.uuid4().hex[:10]
