"""Self-check of the PetHaven business rules, ETL and reports.

Builds a separate database (pethaven_check, never the demo database), runs a
scripted sequence of business events against the three sources, and checks
each rule. Check names start with the rule id from docs/traceability.md.
Prints PASS/FAIL per check and exits 1 if any check fails.

Usage (from the repository root)
    docker compose exec python python /workspace/tests/check_demo.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import psycopg2  # noqa: E402

import pethaven_db as db  # noqa: E402

results: list[bool] = []
conn = None


def check(name: str, expected, actual) -> None:
    ok = expected == actual
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: expected {expected!r}, actual {actual!r}")


def one(sql: str, params=None):
    _, rows = db.query(conn, sql, params)
    return rows[0][0] if rows else None


def run(sql: str, params=None):
    value = one(sql, params)
    conn.commit()
    return value


# --- code translation (warehouse code -> each source's own code) -------------
def code(kind: str, system: str, warehouse_code: str) -> str:
    table, col = ("etl.store_xref", "store_code") if kind == "store" else ("etl.product_xref", "product_code")
    return one(f"SELECT source_code FROM {table} WHERE source_system=%s AND {col}=%s", (system, warehouse_code))


def bc(p): return code("product", "STORE", p)
def sku(p): return code("product", "SUPPLY", p)
def web(p): return code("product", "ONLINE", p)
def sno(s): return code("store", "STORE", s)
def loc(s): return code("store", "SUPPLY", s)


# --- state helpers -----------------------------------------------------------
def in_store(store: str, product: str) -> int:
    return one("SELECT in_store_quantity FROM store_ops.store_stock WHERE store_no=%s AND barcode=%s", (sno(store), bc(product)))


def reserved(store: str, product: str) -> int:
    return one("SELECT reserved_quantity FROM store_ops.store_stock WHERE store_no=%s AND barcode=%s", (sno(store), bc(product)))


def online(product: str) -> int:
    return one("SELECT available_quantity FROM online.online_stock WHERE web_sku=%s", (web(product),))


def actual_total(product: str) -> int:
    return one("SELECT sum(in_store_quantity)::int FROM store_ops.store_stock WHERE barcode=%s", (bc(product),))


def events() -> int:
    return one("SELECT count(*)::int FROM dw.fact_stock_event")


def last_event() -> tuple:
    _, rows = db.query(conn, """
        SELECT f.event_type, s.store_code, f.quantity_change, f.reserved_change
          FROM dw.fact_stock_event f JOIN dw.dim_store s USING (store_key)
         ORDER BY f.event_id DESC LIMIT 1""")
    return tuple(rows[0])


def not_matching() -> int:
    return one("SELECT count(*)::int FROM dw.rpt_reconciliation WHERE status <> 'match'")


def sale(store: str, items: dict[str, int]) -> None:
    run("SELECT store_ops.record_sale(%s, %s, %s)", (sno(store), [bc(p) for p in items], list(items.values())))


def sell_all(store: str, product: str) -> None:
    qty = in_store(store, product)
    if qty:
        sale(store, {product: qty})


def order(postcode: str, items: dict[str, int]) -> tuple[int, str, str, dict]:
    """Place an order; return (order_no, order status, pickup store, {product: (line status, source store)})."""
    order_no = run("SELECT online.place_online_order(%s,%s,%s)",
                   (postcode, [web(p) for p in items], list(items.values())))
    status, pickup = db.query(conn, """
        SELECT o.status, x.store_code FROM online.web_order o
          JOIN etl.store_xref x ON x.source_system='ONLINE' AND x.source_code=o.pickup_cp_code
         WHERE o.order_no=%s""", (order_no,))[1][0]
    _, rows = db.query(conn, """
        SELECT px.product_code, l.line_status, sx.store_code
          FROM online.web_order_line l
          JOIN etl.product_xref px ON px.source_system='ONLINE' AND px.source_code=l.web_sku
          LEFT JOIN etl.store_xref sx ON sx.source_system='ONLINE' AND sx.source_code=l.source_cp_code
         WHERE l.order_no=%s""", (order_no,))
    return order_no, status, pickup, {p: (s, src) for p, s, src in rows}


def store_step(function: str, order_no: int, *extra):
    return run(f"SELECT store_ops.{function}({', '.join(['%s'] * (1 + len(extra)))})", (str(order_no), *extra))


def main() -> int:
    global conn
    print(f"Building {db.CHECK_DATABASE} ...")
    db.build_database(db.CHECK_DATABASE, verbose=False)
    conn = db.connect(db.CHECK_DATABASE)

    print("\n-- Sources and seed")
    check("R1 three sources + etl + dw schemas", 5,
          one("SELECT count(*)::int FROM pg_namespace WHERE nspname IN ('store_ops','supply','online','etl','dw')"))
    check("R1 5 stores", 5, one("SELECT count(*)::int FROM store_ops.store"))
    check("R1 every mapped product stocked at every store", 90, one("SELECT count(*)::int FROM store_ops.store_stock"))
    check("R2 each source uses its own code for P001", 3,
          one("SELECT count(DISTINCT source_code)::int FROM etl.product_xref WHERE product_code='P001'"))
    check("R2 each source uses its own code for S01", 3,
          one("SELECT count(DISTINCT source_code)::int FROM etl.store_xref WHERE store_code='S01'"))
    check("R2 barcode check digit enforced", "refused", _refused(
        "INSERT INTO store_ops.product VALUES ('9300601001010','Bad barcode','Toys',1)"))
    check("R12 dim_store = 5 stores + online", 6, one("SELECT count(*)::int FROM dw.dim_store"))
    check("R12 dim_product excludes unmapped P019", 18, one("SELECT count(*)::int FROM dw.dim_product"))
    check("R11 seed: reserved order lines are skipped with a reason", 9,
          one("SELECT count(*)::int FROM etl.stg_web_order_line WHERE load_status='skipped' AND note IS NOT NULL"))
    check("R13 seed: every fact traces to one loaded staging row", events(),
          one("SELECT count(*)::int FROM etl.v_staging WHERE load_status='loaded'"))
    check("R16 seed shortfall: pickup store Bondi", "PetHaven Bondi",
          one("SELECT pickup_store FROM dw.rpt_shortfall_orders"))
    check("R8 seed dog-bed order: collected at Penrith, taken from Parramatta", ("S05", "S01"),
          tuple(db.query(conn, """
              SELECT pk.store_code, src.store_code FROM store_ops.reservation r
                JOIN etl.store_xref pk ON pk.source_system='STORE' AND pk.source_code=r.pickup_store_no
                JOIN etl.store_xref src ON src.source_system='STORE' AND src.source_code=r.store_no
               WHERE r.web_order_ref='3'""")[1][0]))
    check("R20 seed: 4 open orders, 1 overdue", (4, 1),
          (one("SELECT count(DISTINCT order_no)::int FROM dw.rpt_open_reservations"),
           one("SELECT count(DISTINCT order_no)::int FROM dw.rpt_open_reservations WHERE overdue")))
    check("R21 seed: 3-item order 6 has 2 lines in transit and is not ready", (2, False),
          (one("SELECT count(*)::int FROM dw.rpt_open_reservations WHERE order_no='6' AND line_status='in transit'"),
           one("SELECT bool_and(order_ready) FROM dw.rpt_open_reservations WHERE order_no='6'")))
    check("R17 nothing pending after initial sync", 0, one("SELECT pending_events::int FROM dw.rpt_online_staleness"))
    check("R17 website equals real total (P001)", actual_total("P001"), online("P001"))
    check("R19 warehouse reconciles with store system", 0, not_matching())
    check("R14 no rejected source rows", 0, one("SELECT count(*)::int FROM etl.v_data_quality"))

    print("\n-- In-store sale: one receipt, several items")
    before = {p: in_store("S01", p) for p in ("P003", "P005", "P009")}
    before_online = online("P003")
    n = events()
    sale("S01", {"P003": 2, "P005": 1, "P009": 1})
    check("R3 shelf stock drops immediately", [before["P003"] - 2, before["P005"] - 1, before["P009"] - 1],
          [in_store("S01", p) for p in ("P003", "P005", "P009")])
    check("R3 one receipt, three lines", 3,
          one("SELECT count(*)::int FROM store_ops.sale_line WHERE sale_no=(SELECT max(sale_no) FROM store_ops.sale)"))
    check("R10 three store_sale facts loaded at once", 3, events() - n)
    check("R3 website number unchanged", before_online, online("P003"))

    print("\n-- Receipt with one item short is refused entirely")
    n, p3 = events(), in_store("S01", "P003")
    check("R3 receipt refused", "refused", _refused(
        "SELECT store_ops.record_sale(%s, %s, %s)", (sno("S01"), [bc("P003"), bc("P013")], [1, 99])))
    check("R3 nothing deducted, no facts", (p3, n), (in_store("S01", "P003"), events()))

    print("\n-- Delivery in cartons, UTC time")
    before_s02, before_online = in_store("S02", "P001"), online("P001")
    upc = one("SELECT units_per_carton FROM supply.item WHERE supplier_sku=%s", (sku("P001"),))
    run("""SELECT supply.record_delivery(%s, 'Check Supplier', %s, '{2}',
                                         ((current_date - 1) + time '15:30')::timestamp)""", (loc("S02"), [sku("P001")]))
    check("R9 cartons converted to units on the shelf", before_s02 + 2 * upc, in_store("S02", "P001"))
    check("R9 fact units = cartons x units per carton", 2 * upc,
          one("SELECT units FROM dw.fact_stock_event WHERE event_type='delivery' ORDER BY event_id DESC LIMIT 1"))
    check("R9 15:30 UTC yesterday is today in Sydney (date_key)", one("SELECT to_char(current_date,'YYYYMMDD')::int"),
          one("SELECT date_key FROM dw.fact_stock_event WHERE event_type='delivery' ORDER BY event_id DESC LIMIT 1"))
    check("R4 website number unchanged", before_online, online("P001"))

    print("\n-- Online order held at the closest store")
    shown = online("P001")
    _, status, pickup, lines = order("2150", {"P001": 2})
    check("R8 pickup = closest store, held there", ("reserved", "S01", ("reserved", "S01")),
          (status, pickup, lines["P001"]))
    check("R6 website number lowered immediately", shown - 2, online("P001"))
    check("R6 report shows the same website number", online("P001"),
          one("SELECT online_shown FROM dw.rpt_online_vs_actual WHERE product_code='P001'"))

    print("\n-- Website shows 10, customer buys 7 -> website shows 3")
    for store in ("S01", "S02", "S04", "S05"):
        sell_all(store, "P006")
    sale("S03", {"P006": in_store("S03", "P006") - 10})
    run("SELECT dw.run_sync()")
    check("R17 website shows 10 after sync", 10, online("P006"))
    _, status, _, lines = order("2067", {"P006": 7})
    check("R6 order of 7 held at Chatswood", ("reserved", ("reserved", "S03")), (status, lines["P006"]))
    check("R6 website shows 3 before the next sync", 3, online("P006"))
    check("R6 not counted as out of date", "in sync",
          one("SELECT status FROM dw.rpt_online_vs_actual WHERE product_code='P006'"))
    _, status, _, _ = order("2067", {"P006": 7})
    check("R7 second order of 7 rejected (website shows 3)", "rejected", status)

    print("\n-- Closest store lacks stock -> taken from next-nearest and transferred")
    sell_all("S05", "P016")
    held_s01 = reserved("S01", "P016")
    order_no, status, pickup, lines = order("2750", {"P016": 1})
    check("R8 pickup Penrith, taken from Parramatta", ("reserved", "S05", ("reserved", "S01")),
          (status, pickup, lines["P016"]))
    check("R8 held at the source store until sent", held_s01 + 1, reserved("S01", "P016"))
    check("R21 cannot collect before the item arrives", "refused",
          _refused("SELECT store_ops.collect_order(%s)", (str(order_no),)))
    store_step("dispatch_order_transfers", order_no)
    check("R21 dispatch: leaves the source store, in transit", (held_s01, ("transfer_out", "S01", 0, -1)),
          (reserved("S01", "P016"), last_event()))
    check("R21 cannot cancel while in transit", "refused",
          _refused("SELECT store_ops.cancel_order(%s, 'x')", (str(order_no),)))
    check("R21 open order shows the line in transit", "in transit",
          one("SELECT line_status FROM dw.rpt_open_reservations WHERE order_no=%s", (str(order_no),)))
    store_step("receive_order_transfers", order_no)
    check("R21 receive: arrives held at the pickup store", (1, ("transfer_in", "S05", 0, 1)),
          (reserved("S05", "P016"), last_event()))
    store_step("collect_order", order_no)
    check("R5 collected at the pickup store", (0, ("collection", "S05", 0, -1)),
          (reserved("S05", "P016"), last_event()))

    print("\n-- Three items, not all at the closest store")
    p13_total = actual_total("P013")
    shown = {p: online(p) for p in ("P009", "P018", "P013")}
    order_no, status, pickup, lines = order("2026", {"P009": 1, "P018": 1, "P013": 2})
    check("R22 pickup Bondi; order partly short", ("partial_shortfall", "S02"), (status, pickup))
    check("R22 duck held at Bondi (local)", ("reserved", "S02"), lines["P009"])
    check("R22 aquarium kit taken from Newtown (transfer)", ("reserved", "S04"), lines["P018"])
    check("R22 2 dog beds: no single store has 2 -> line shortfall", ("shortfall", None), lines["P013"])
    check("R16 shortfall reason: split across stores", (True, "enough stock in total but no single store had enough"),
          (p13_total >= 2, one("SELECT reason FROM dw.rpt_shortfall_orders WHERE order_no=%s", (str(order_no),))))
    check("R6 website lowered only for the held lines", (shown["P009"] - 1, shown["P018"] - 1, shown["P013"]),
          (online("P009"), online("P018"), online("P013")))
    store_step("dispatch_order_transfers", order_no)
    store_step("receive_order_transfers", order_no)
    shelf_s02 = in_store("S02", "P018")
    store_step("cancel_order", order_no, "Customer cancelled")
    check("R5 cancel after arrival: kit goes on the pickup store's shelf", (shelf_s02 + 1, 0),
          (in_store("S02", "P018"), reserved("S02", "P018")))

    print("\n-- Collection and cancellation (local)")
    order_no, _, _, _ = order("2042", {"P009": 2})
    held = reserved("S04", "P009")
    store_step("collect_order", order_no)
    check("R5 collection: reserved down, shelf unchanged", held - 2, reserved("S04", "P009"))
    check("R5 collection fact", ("collection", "S04", 0, -2), last_event())
    order_no, _, _, _ = order("2042", {"P009": 1})
    shelf, shown = in_store("S04", "P009"), online("P009")
    store_step("cancel_order", order_no, "Check cancel")
    check("R5 cancellation: back on the shelf", shelf + 1, in_store("S04", "P009"))
    check("R5 website not told until sync (understated)", (shown, "understated - lost sales risk"),
          (online("P009"), one("SELECT status FROM dw.rpt_online_vs_actual WHERE product_code='P009'")))

    print("\n-- Stale website number -> shortfall")
    for store in ("S01", "S02", "S03", "S04", "S05"):
        sell_all(store, "P017")
    shown = online("P017")
    order_no, status, _, _ = order("2067", {"P017": 1})
    check("R16 website still showed stock", True, shown >= 1)
    check("R16 order status shortfall", "shortfall", status)
    check("R16 shortfall fact at the pickup store (Chatswood)", "S03",
          one("SELECT s.store_code FROM dw.fact_stock_event f JOIN dw.dim_store s USING (store_key) "
              "WHERE f.order_ref=%s AND f.event_type='shortfall'", (str(order_no),)))
    check("R16 shortfall report reason", "stock sold since last sync - online number was stale",
          one("SELECT reason FROM dw.rpt_shortfall_orders WHERE order_no=%s", (str(order_no),)))

    print("\n-- Rejected order moves nothing")
    n = events()
    _, status, _, lines = order("2000", {"P001": 1, "P018": online("P018") + 1})
    check("R7 whole order rejected if one line is not covered", ("rejected", "rejected", "rejected"),
          (status, lines["P001"][0], lines["P018"][0]))
    check("R11 no fact written (staged and skipped)", (n, "skipped"),
          (events(), one("SELECT load_status FROM etl.stg_web_order_line ORDER BY stg_id DESC LIMIT 1")))

    print("\n-- Data quality: unmapped new product")
    tunnel = "9300601001194"
    n = events()
    run("SELECT supply.record_delivery(%s, 'PlayPets Wholesale', '{PP-CAT-TUNNEL}', '{2}')", (loc("S01"),))
    run("SELECT store_ops.record_sale(%s, %s, '{1}')", (sno("S01"), [tunnel]))
    check("R14 store system works with the new product", 7,
          one("SELECT in_store_quantity FROM store_ops.store_stock WHERE store_no=%s AND barcode=%s", (sno("S01"), tunnel)))
    check("R14 both rows rejected, not loaded", (2, n),
          (one("SELECT count(*)::int FROM etl.v_data_quality"), events()))
    check("R14 reason names the missing mapping", True,
          one("SELECT bool_and(reject_reason LIKE 'No approved % product mapping for code %') FROM etl.v_data_quality"))
    check("R19 reconciliation flags the gap", "not in warehouse - unmapped code",
          one("SELECT status FROM dw.rpt_reconciliation WHERE barcode=%s", (tunnel,)))
    check("R14 staleness report counts it", 2, one("SELECT source_rows_not_loaded::int FROM dw.rpt_online_staleness"))
    run("SELECT etl.approve_product_mapping('STORE', %s, 'P019'), 1", (tunnel,))
    run("SELECT etl.approve_product_mapping('SUPPLY', 'PP-CAT-TUNNEL', 'P019'), 1")
    run("SELECT etl.run_etl()")
    check("R14 after approval both rows load", (0, n + 2),
          (one("SELECT count(*)::int FROM etl.v_data_quality"), events()))
    check("R12 P019 added to dim_product", 19, one("SELECT count(*)::int FROM dw.dim_product"))

    print("\n-- Run sync")
    pending = one("SELECT pending_events::int FROM dw.rpt_online_staleness")
    sync_id = run("SELECT dw.run_sync()")
    check("R17 events processed = events pending", pending,
          one("SELECT events_processed FROM dw.sync_run WHERE sync_id=%s", (sync_id,)))
    check("R17 nothing pending after sync", 0, one("SELECT pending_events::int FROM dw.rpt_online_staleness"))
    for product in ("P001", "P009", "P016", "P017", "P018"):
        check(f"R17 website corrected ({product})", actual_total(product), online(product))
    check("R17 P017 before/after logged", (shown, 0),
          tuple(db.query(conn, "SELECT before_qty, after_qty FROM dw.rpt_last_sync_changes "
                               "WHERE product_code='P017' AND measure='online_available'")[1][0]))
    check("R17 all products in sync", 0, one("SELECT products_out_of_date::int FROM dw.rpt_online_staleness"))
    check("R19 sync reconciliation", 0, one("SELECT store_mismatches FROM dw.sync_run WHERE sync_id=%s", (sync_id,)))
    check("R19 warehouse reconciles with store system", 0, not_matching())
    check("R13 every fact traces to one loaded staging row", events(),
          one("SELECT count(*)::int FROM etl.v_staging WHERE load_status='loaded'"))
    check("R18 daily sales report uses dim_date", True,
          one("SELECT count(*) > 0 FROM dw.rpt_daily_sales WHERE full_date = current_date"))

    conn.close()
    passed = sum(results)
    print(f"\nTOTAL: {len(results)} checks - PASS {passed}, FAIL {len(results) - passed}")
    return 0 if passed == len(results) else 1


def _refused(sql: str, params=None) -> str:
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
        conn.rollback()
        return "accepted"
    except psycopg2.Error:
        conn.rollback()
        return "refused"


if __name__ == "__main__":
    sys.exit(main())
