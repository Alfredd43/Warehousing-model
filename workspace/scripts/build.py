"""Build the PetHaven demo database from scratch.

Recreates the database pethaven_demo on the lab server, creates the three
source schemas and the warehouse, loads the sample data and runs the initial
sync. Safe to rerun: it always starts from an empty database. It does not
start the automatic sync; run 'demo.py scheduler start' for that.

Usage (from the repository root)
    docker compose exec python python /workspace/scripts/build.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import pethaven_db as db


def main() -> int:
    print(f"Building {db.DEMO_DATABASE} ...")
    db.build_database(db.DEMO_DATABASE)
    conn = db.connect()
    try:
        print()
        db.print_table(*db.query(conn, """
            SELECT 'stores' AS item, count(*) FROM store_ops.store
            UNION ALL SELECT 'items in store catalogue', count(*) FROM store_ops.product
            UNION ALL SELECT 'items on warehouse product list', count(*) FROM etl.item_list
            UNION ALL SELECT 'source records extracted to staging', count(*) FROM etl.v_staging
            UNION ALL SELECT 'stock events loaded into warehouse', count(*) FROM dw.fact_stock_event
            UNION ALL SELECT 'source records rejected by ETL', count(*) FROM etl.v_data_quality
            UNION ALL SELECT 'syncs', count(*) FROM dw.sync_run
            UNION ALL SELECT 'events pending sync', pending_events FROM dw.rpt_online_staleness
            UNION ALL SELECT 'store/product pairs not reconciled', count(*) FROM dw.rpt_reconciliation WHERE status <> 'match'"""))
    finally:
        conn.close()
    print(f"\nDone. Try: python /workspace/scripts/demo.py report all")
    if scheduler_running():
        print("The automatic sync scheduler is running; it reconnects to the new database within a few seconds.")
    else:
        print(f"The automatic sync is not started. To sync every {db.SYNC_INTERVAL_SECONDS} s: "
              f"python /workspace/scripts/demo.py scheduler start")
    return 0


def scheduler_running() -> bool:
    """True if a sync_scheduler.py process runs in this container (where demo.py starts it)."""
    proc = Path("/proc")
    if not proc.is_dir():
        return False
    for pid in proc.iterdir():
        try:
            if pid.name.isdigit() and b"sync_scheduler.py" in (pid / "cmdline").read_bytes():
                return True
        except OSError:
            continue
    return False


if __name__ == "__main__":
    sys.exit(main())
