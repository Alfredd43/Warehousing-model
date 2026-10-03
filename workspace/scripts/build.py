"""Build the PetHaven demo database from scratch.

Recreates the database pethaven_demo on the lab server, creates the three
source schemas and the warehouse, loads the sample data and runs the initial
sync. Safe to rerun: it always starts from an empty database.

Usage (from the repository root)
    docker compose exec python python /workspace/scripts/build.py
"""

from __future__ import annotations

import sys

import pethaven_db as db


def main() -> int:
    print(f"Building {db.DEMO_DATABASE} ...")
    db.build_database(db.DEMO_DATABASE)
    conn = db.connect()
    try:
        print()
        db.print_table(*db.query(conn, """
            SELECT 'stores' AS item, count(*) FROM store_ops.store
            UNION ALL SELECT 'products in store catalogue', count(*) FROM store_ops.product
            UNION ALL SELECT 'source records extracted to staging', count(*) FROM etl.v_staging
            UNION ALL SELECT 'stock events loaded into warehouse', count(*) FROM dw.fact_stock_event
            UNION ALL SELECT 'source records rejected by ETL', count(*) FROM etl.v_data_quality
            UNION ALL SELECT 'syncs', count(*) FROM dw.sync_run
            UNION ALL SELECT 'events pending sync', pending_events FROM dw.rpt_online_staleness
            UNION ALL SELECT 'store/product pairs not reconciled', count(*) FROM dw.rpt_reconciliation WHERE status <> 'match'"""))
    finally:
        conn.close()
    print(f"\nDone. Try: python /workspace/scripts/demo.py report all")
    return 0


if __name__ == "__main__":
    sys.exit(main())
