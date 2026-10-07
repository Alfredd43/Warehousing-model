"""Website stock sync scheduler: runs the sync every SYNC_INTERVAL_SECONDS.

Every interval it runs online.sync_website_stock(now(), 'scheduled'): the
website takes the real shelf totals from the store system, and the warehouse
records the sync (07_sync.sql). The first sync runs one interval after start.

The interval is set once, in pethaven_db.SYNC_INTERVAL_SECONDS (180 s);
--interval overrides it for tests. While running, the scheduler keeps its
registration in online.sync_schedule up to date (interval, heartbeat, next
sync due), which is what the staleness report and the dashboard show. A
session advisory lock makes sure only one scheduler runs per database.

Start and stop it with demo.py (it then runs in the background):
    docker compose exec python python /workspace/scripts/demo.py scheduler start
    docker compose exec python python /workspace/scripts/demo.py scheduler stop
Or run it in the foreground (Ctrl+C stops it):
    docker compose exec python python /workspace/scripts/sync_scheduler.py

Stopping: demo.py sets the registration to 'stop_requested'; the scheduler
sees it within a second, marks itself 'stopped' and exits. SIGTERM / Ctrl+C
do the same. If the database is rebuilt (build.py), the scheduler loses its
connection, waits, reconnects and carries on with the new database.
"""

from __future__ import annotations

import argparse
import signal
import sys
import time
from datetime import datetime

import psycopg2

import pethaven_db as db

LOCK_SQL = "SELECT pg_try_advisory_lock(hashtext('pethaven.sync_scheduler'))"
HEARTBEAT_SECONDS = 2
RETRY_SECONDS = 3


class AlreadyRunning(Exception):
    pass


def log(message: str) -> None:
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S} {message}", flush=True)


def register(conn, interval: int, next_due_in: float) -> None:
    with conn.cursor() as cur:
        cur.execute(LOCK_SQL)
        if not cur.fetchone()[0]:
            conn.rollback()
            raise AlreadyRunning("another sync scheduler is already running on this database")
        cur.execute("""
            INSERT INTO online.sync_schedule
                   (schedule_id, interval_seconds, status, started_at, heartbeat_at, next_sync_at, stopped_at)
            VALUES (1, %s, 'running', now(), now(), now() + make_interval(secs => %s), NULL)
            ON CONFLICT (schedule_id) DO UPDATE
               SET interval_seconds = EXCLUDED.interval_seconds, status = 'running',
                   started_at = EXCLUDED.started_at, heartbeat_at = EXCLUDED.heartbeat_at,
                   next_sync_at = EXCLUDED.next_sync_at, stopped_at = NULL""", (interval, next_due_in))
    conn.commit()


def heartbeat(conn, next_due_in: float) -> str:
    """Refresh the heartbeat and next due time; return the requested status."""
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE online.sync_schedule
               SET heartbeat_at = now(), next_sync_at = now() + make_interval(secs => %s)
             WHERE schedule_id = 1
            RETURNING status""", (max(next_due_in, 0),))
        row = cur.fetchone()
    conn.commit()
    return row[0] if row else "stop_requested"


def run_sync(conn) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT online.sync_website_stock(now(), 'scheduled')")
        sync_no = cur.fetchone()[0]
        cur.execute("SELECT products_changed FROM online.stock_sync WHERE sync_no = %s", (sync_no,))
        changed = cur.fetchone()[0]
    conn.commit()
    log(f"sync {sync_no}: {changed} website number(s) changed")
    return sync_no


def mark_stopped(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("""UPDATE online.sync_schedule SET status = 'stopped', stopped_at = now(),
                              next_sync_at = NULL WHERE schedule_id = 1""")
    conn.commit()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--interval", type=int, default=db.SYNC_INTERVAL_SECONDS,
                        help=f"seconds between syncs (default {db.SYNC_INTERVAL_SECONDS}, from pethaven_db)")
    parser.add_argument("--database", default=db.DEMO_DATABASE, help=f"default {db.DEMO_DATABASE}")
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error("--interval must be positive")

    stopping = False

    def on_signal(signum, frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    log(f"sync scheduler: every {args.interval} s on database {args.database}")
    next_due = time.monotonic() + args.interval
    conn = None
    while not stopping:
        try:
            if conn is None:
                conn = db.connect(args.database)
                register(conn, args.interval, next_due - time.monotonic())
                log("registered in online.sync_schedule")
                last_beat = 0.0
            now = time.monotonic()
            if now >= next_due:
                run_sync(conn)
                # Keep a fixed cadence; if a sync ran late, restart from now.
                next_due = max(next_due + args.interval, time.monotonic() + 0.5)
                last_beat = 0.0
            if time.monotonic() - last_beat >= HEARTBEAT_SECONDS:
                if heartbeat(conn, next_due - time.monotonic()) == "stop_requested":
                    log("stop requested")
                    break
                last_beat = time.monotonic()
            time.sleep(0.2)
        except AlreadyRunning as exc:
            log(f"refused: {exc}")
            conn.close()
            return 1
        except psycopg2.Error as exc:
            # Database unavailable or being rebuilt: reconnect and re-register.
            log(f"database error ({type(exc).__name__}): {str(exc).strip().splitlines()[0]}; retrying in {RETRY_SECONDS} s")
            if conn is not None:
                try:
                    conn.close()
                except psycopg2.Error:
                    pass
            conn = None
            time.sleep(RETRY_SECONDS)

    if conn is not None:
        try:
            mark_stopped(conn)
            conn.close()
        except psycopg2.Error:
            pass
    log("sync scheduler stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
