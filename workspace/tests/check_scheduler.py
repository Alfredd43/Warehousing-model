"""Checks for the automatic website sync (scripts/sync_scheduler.py).

Builds the separate check database (pethaven_check, never the demo database),
starts the scheduler through 'demo.py scheduler start' with a short interval
(2 s instead of SYNC_INTERVAL_SECONDS), and checks that it syncs at that
interval, that the warehouse and the staleness report record it, that a
manual sync still works, and that 'demo.py scheduler stop' stops it.
Prints PASS/FAIL per check and exits 1 if any check fails.

Usage (from the repository root)
    docker compose exec python python /workspace/tests/check_scheduler.py
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import pethaven_db as db  # noqa: E402

INTERVAL = 2
results: list[bool] = []
conn = None


def check(name: str, expected, actual) -> None:
    ok = expected == actual
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: expected {expected!r}, actual {actual!r}")


def one(sql: str, params=None):
    _, rows = db.query(conn, sql, params)
    conn.commit()
    return rows[0][0] if rows else None


def demo(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPTS / "demo.py"), *args, "--database", db.CHECK_DATABASE],
                          capture_output=True, text=True, timeout=60)


def scheduled_syncs() -> int:
    return one("SELECT count(*)::int FROM online.stock_sync WHERE triggered_by = 'scheduled'")


def wait_for(condition, timeout: float) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return True
        time.sleep(0.2)
    return condition()


def main() -> int:
    global conn
    print(f"Building {db.CHECK_DATABASE} ...")
    db.build_database(db.CHECK_DATABASE, verbose=False)
    conn = db.connect(db.CHECK_DATABASE)

    print("\n-- Configuration")
    check("S1 the interval is configured once: SYNC_INTERVAL_SECONDS = 180", 180, db.SYNC_INTERVAL_SECONDS)
    help_text = subprocess.run([sys.executable, str(SCRIPTS / "sync_scheduler.py"), "--help"],
                               capture_output=True, text=True).stdout
    check("S1 the scheduler's default interval comes from that value", True, "default 180" in help_text)
    check("S1 before starting: scheduler never started, only the seed syncs", ("never started", 0),
          (one("SELECT scheduler_status FROM dw.rpt_online_staleness"), scheduled_syncs()))

    try:
        print(f"\n-- Start with a {INTERVAL} s interval")
        started = demo("scheduler", "start", "--interval", str(INTERVAL))
        check("S2 'demo.py scheduler start' succeeds", 0, started.returncode)
        check("S2 staleness report shows the scheduler running with the configured interval",
              ("running", f"00:00:0{INTERVAL}"),
              (one("SELECT scheduler_status FROM dw.rpt_online_staleness"),
               one("SELECT sync_interval::text FROM dw.rpt_online_staleness")))
        check("S2 starting again does not start a second scheduler", True,
              "already running" in demo("scheduler", "start").stdout)
        second = subprocess.run([sys.executable, str(SCRIPTS / "sync_scheduler.py"), "--interval", "1",
                                 "--database", db.CHECK_DATABASE], capture_output=True, text=True, timeout=30)
        check("S2 a second scheduler process is refused (one per database)", (1, True),
              (second.returncode, "already running" in second.stdout))

        print("\n-- It syncs at the configured interval")
        check("S3 three scheduled syncs within 10 s", True, wait_for(lambda: scheduled_syncs() >= 3, 10))
        _, rows = db.query(conn, """
            SELECT extract(epoch FROM run_at - lag(run_at) OVER (ORDER BY sync_no))::numeric(6,2)
              FROM online.stock_sync WHERE triggered_by = 'scheduled' ORDER BY sync_no""")
        conn.commit()
        gaps = [float(r[0]) for r in rows if r[0] is not None]
        check(f"S3 consecutive scheduled syncs are {INTERVAL} s apart (+/- 0.6 s)", True,
              bool(gaps) and all(abs(g - INTERVAL) <= 0.6 for g in gaps))
        print(f"      gaps: {gaps}")
        check("S3 every scheduled sync is recorded in the warehouse as scheduled", True,
              one("""SELECT count(*) FROM online.stock_sync o
                       JOIN dw.sync_run r ON r.source_sync_no = o.sync_no AND r.triggered_by = 'scheduled'
                      WHERE o.triggered_by = 'scheduled'""") >= 3)
        check("S3 report: last sync was scheduled, next one due within the interval", ("scheduled", True),
              (one("SELECT last_sync_trigger FROM dw.rpt_online_staleness"),
               one(f"""SELECT next_sync_at > now() AND next_sync_at <= now() + interval '{INTERVAL + 1} seconds'
                        FROM dw.rpt_online_staleness""")))

        print("\n-- An in-store sale is corrected on the website by the next scheduled sync")
        before = scheduled_syncs()
        one("SELECT store_ops.record_sale('101', '{P001}', '{1}')")
        stale = one("SELECT status FROM dw.rpt_online_vs_actual WHERE product_code = 'P001'")
        check("S4 straight after the sale the website number is stale", "overstated - oversell risk", stale)
        wait_for(lambda: scheduled_syncs() > before, INTERVAL + 2)
        check("S4 after the next scheduled sync the website is correct, with no manual step", "in sync",
              one("SELECT status FROM dw.rpt_online_vs_actual WHERE product_code = 'P001'"))

        print("\n-- Manual sync still works while the scheduler runs")
        sync_no = one("SELECT online.sync_website_stock()")
        check("S5 a manual sync is recorded as manual", "manual",
              one("SELECT triggered_by FROM dw.sync_run WHERE source_sync_no = %s", (sync_no,)))
    finally:
        print("\n-- Stop")
        stopped = demo("scheduler", "stop")

    check("S6 'demo.py scheduler stop' succeeds", 0, stopped.returncode)
    check("S6 report shows the scheduler stopped, no next sync", ("stopped", None),
          (one("SELECT scheduler_status FROM dw.rpt_online_staleness"),
           one("SELECT next_sync_at FROM dw.rpt_online_staleness")))
    after_stop = scheduled_syncs()
    time.sleep(INTERVAL * 2)
    check("S6 no scheduled syncs after stopping", after_stop, scheduled_syncs())

    conn.close()
    passed = sum(results)
    print(f"\nTOTAL: {len(results)} checks - PASS {passed}, FAIL {len(results) - passed}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
