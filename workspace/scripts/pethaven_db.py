"""Shared database helpers for the PetHaven scripts.

Connection settings
    Defaults are the Lab Environment values from docker-compose.yml (host
    ``postgres``, port 5432, user/password ``student``). Standard libpq
    variables (PGHOST, PGPORT, PGUSER, PGPASSWORD) override them, for example
    ``PGHOST=localhost`` when running a script on the host machine.

Safety
    Only the databases named in MANAGED_DATABASES are ever dropped, and only on
    a local lab server. The lab's own ``lab`` database is never touched.
"""

from __future__ import annotations

import os
from pathlib import Path

import psycopg2
import psycopg2.extensions

WORKSPACE = Path(__file__).resolve().parents[1]
DB_DIR = WORKSPACE / "db"

DEMO_DATABASE = "pethaven_demo"
CHECK_DATABASE = "pethaven_check"
MANAGED_DATABASES = {DEMO_DATABASE, CHECK_DATABASE}
LOCAL_LAB_HOSTS = {"postgres", "localhost", "127.0.0.1"}
SYDNEY = "Australia/Sydney"

# How often the website stock sync runs (scripts/sync_scheduler.py). This is
# the only place the interval is set. The scheduler records the value it uses
# in online.sync_schedule, so the reports and the dashboard can show it.
SYNC_INTERVAL_SECONDS = 180

# Applied in this order by build_database().
SQL_FILES = [
    "01_schemas.sql",
    "02_store_ops.sql",
    "03_supply.sql",
    "04_online.sql",
    "05_warehouse.sql",
    "06_etl.sql",
    "07_sync.sql",
    "08_reports.sql",
    "seed/01_reference_data.sql",
    "seed/02_business_history.sql",
]


def lab_settings() -> dict:
    """Return connection keyword arguments for the lab server (env overrides)."""
    return {
        "host": os.environ.get("PGHOST", "postgres"),
        "port": int(os.environ.get("PGPORT", "5432")),
        "user": os.environ.get("PGUSER", "student"),
        "password": os.environ.get("PGPASSWORD", "student"),
    }


def connect(database: str = DEMO_DATABASE):
    """Open a connection in Sydney time. Autocommit is off; the caller commits."""
    conn = psycopg2.connect(dbname=database, **lab_settings())
    with conn.cursor() as cur:
        cur.execute("SET TIME ZONE %s", (SYDNEY,))
    conn.commit()
    return conn


def recreate_database(database: str) -> None:
    """Drop (if present) and create one managed database on the local lab server."""
    if database not in MANAGED_DATABASES:
        raise RuntimeError(f"Refusing to drop '{database}': only {sorted(MANAGED_DATABASES)} are managed")
    host = lab_settings()["host"]
    if host not in LOCAL_LAB_HOSTS:
        raise RuntimeError(f"Refusing to drop databases on host '{host}': only the local lab server is allowed")
    admin = psycopg2.connect(dbname="lab", **lab_settings())
    admin.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    try:
        with admin.cursor() as cur:
            cur.execute(f'DROP DATABASE IF EXISTS "{database}" WITH (FORCE)')
            cur.execute(f'CREATE DATABASE "{database}"')
            cur.execute(f"ALTER DATABASE \"{database}\" SET timezone TO '{SYDNEY}'")
    finally:
        admin.close()


def build_database(database: str = DEMO_DATABASE, verbose: bool = True) -> None:
    """Recreate ``database`` and apply every SQL file, one transaction per file."""
    recreate_database(database)
    conn = connect(database)
    try:
        for relative in SQL_FILES:
            try:
                with conn.cursor() as cur:
                    cur.execute((DB_DIR / relative).read_text(encoding="utf-8"))
                conn.commit()
            except Exception:
                conn.rollback()
                print(f"  FAILED while applying db/{relative}")
                raise
            if verbose:
                print(f"  applied db/{relative}")
    finally:
        conn.close()


def query(conn, sql: str, params=None) -> tuple[list[str], list[tuple]]:
    """Run a query and return (column names, rows)."""
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return [d.name for d in cur.description], cur.fetchall()


def print_table(columns: list[str], rows: list[tuple]) -> None:
    """Print rows as a plain aligned text table."""
    cells = [[("" if v is None else str(v)) for v in row] for row in rows]
    widths = [max([len(c)] + [len(r[i]) for r in cells]) for i, c in enumerate(columns)]
    print("  ".join(c.ljust(w) for c, w in zip(columns, widths)))
    print("  ".join("-" * w for w in widths))
    for row in cells:
        print("  ".join(v.ljust(w) for v, w in zip(row, widths)))
    print(f"({len(rows)} row{'s' if len(rows) != 1 else ''})")
