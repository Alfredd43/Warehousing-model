"""API checks for the PetHaven dashboard.

Builds the separate check database (pethaven_check, never the demo database),
starts the dashboard server in this process on a free local port, and checks
its read-only endpoints against the report views. Business events are made
with the source systems' own SQL functions, as scripts/demo.py does.
Prints PASS/FAIL per check and exits 1 if any check fails.

Usage (from the repository root)
    docker compose exec python python /workspace/tests/check_dashboard.py
"""

from __future__ import annotations

import json
import os
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "dashboard"))

import pethaven_db as db  # noqa: E402
import server  # noqa: E402

results: list[bool] = []
BASE = ""


def check(name: str, expected, actual) -> None:
    ok = expected == actual
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: expected {expected!r}, actual {actual!r}")


def request(method: str, path: str, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json"} if body is not None else {}
    h.update(headers or {})
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def get(path):
    return request("GET", path)


def post(path, body=None):
    return request("POST", path, body if body is not None else {})


def sql(query, params=None):
    conn = db.connect(db.CHECK_DATABASE)
    try:
        return db.query(conn, query, params)[1]
    finally:
        conn.close()


def write(query, params=None):
    """Run one business function in the check database and commit it."""
    conn = db.connect(db.CHECK_DATABASE)
    try:
        result = db.query(conn, query, params)[1]
        conn.commit()
        return result
    finally:
        conn.close()


def main() -> int:
    global BASE
    print(f"Building {db.CHECK_DATABASE} ...")
    db.build_database(db.CHECK_DATABASE, verbose=False)
    httpd = server.make_server("127.0.0.1", 0, db.CHECK_DATABASE)
    BASE = f"http://127.0.0.1:{httpd.server_address[1]}/api"
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    # --- 1. read endpoints match their views --------------------------------------
    s, r = get("/health")
    check("D1 health reports the check database", (200, "pethaven_check"), (s, r["data"]["database"]))

    s, r = get("/website-stock")
    view = {row[0]: (row[1], row[2], row[3]) for row in sql(
        "SELECT product_code, online_shown, actual_in_store, overstated_by FROM dw.rpt_online_vs_actual")}
    api = {x["product_code"]: (x["online_shown"], x["actual_in_store"], x["difference"]) for x in r["data"]["comparison"]}
    check("D1 website comparison equals dw.rpt_online_vs_actual", view, api)
    check("D1 website comparison scope is stated", True, "five stores" in (r["meta"]["scope"] or ""))

    s, r = get("/stock")
    view = sql("SELECT count(*), sum(in_store_quantity), sum(reserved_quantity) FROM dw.rpt_current_stock_by_store")[0]
    rows = r["data"]["rows"]
    check("D1 stock equals dw.rpt_current_stock_by_store (rows, available, reserved)",
          tuple(view), (len(rows), sum(x["available"] for x in rows), sum(x["reserved"] for x in rows)))
    s2, r2 = get("/stock?from=2020-01-01&to=2020-01-02")
    check("D6 current stock ignores history date parameters", rows, r2["data"]["rows"])

    s, r = get("/checkout/blocked")
    check("D1 blocked items equal dw.rpt_checkout_blocked row count",
          sql("SELECT count(*) FROM dw.rpt_checkout_blocked")[0][0], len(r["data"]["rows"]))
    check("D4 every blocked item has a stable event and attempt id", True,
          all(x["event_id"] and x["attempt_no"] for x in r["data"]["rows"]))

    s, r = get("/reservations")
    check("D1 open reservations equal dw.rpt_open_reservations row count",
          sql("SELECT count(*) FROM dw.rpt_open_reservations")[0][0], len(r["data"]["rows"]))

    s, o = get("/overview")
    ov = o["data"]
    check("D8 overview: website accuracy equals dw.rpt_online_vs_actual",
          (sql("SELECT count(*) FROM dw.rpt_online_vs_actual")[0][0],
           sql("SELECT count(*) FROM dw.rpt_online_vs_actual WHERE status <> 'in sync'")[0][0]),
          (ov["website"]["products"], ov["website"]["out_of_date"]))
    check("D8 overview: stock alerts equal dw.rpt_current_stock_by_store",
          tuple(sql("""SELECT count(*) FILTER (WHERE in_store_quantity = 0),
                              count(*) FILTER (WHERE in_store_quantity BETWEEN 1 AND 2)
                         FROM dw.rpt_current_stock_by_store""")[0]),
          (ov["stock"]["out_of_stock"], ov["stock"]["low_stock"]))
    check("D8 overview: open and overdue orders equal dw.rpt_open_reservations",
          tuple(sql("""SELECT count(DISTINCT order_no), count(DISTINCT order_no) FILTER (WHERE overdue)
                         FROM dw.rpt_open_reservations""")[0]),
          (ov["orders"]["open_orders"], ov["orders"]["overdue"]))
    check("D8 overview: scheduler state comes from the staleness report",
          sql("SELECT scheduler_status FROM dw.rpt_online_staleness")[0][0], ov["sync"]["scheduler_status"])

    # --- 2. validation and refusals ------------------------------------------------
    check("D2 bad product code is refused", 400, get("/stock/events?product=P001;drop")[0])
    check("D2 missing attempt is 404", 404, get("/checkout/attempts/999999")[0])
    check("D2 unknown endpoint is 404", 404, get("/nope")[0])
    check("D2 the dashboard is read-only (POST is 405)", 405, post("/sync")[0])

    # --- 3. sale and supplier delivery reach the reports ----------------------------
    before = {x["product_code"]: x for x in get("/website-stock")[1]["data"]["comparison"]}["P001"]
    sale_no = write("SELECT store_ops.record_sale('101', ARRAY['P001'], ARRAY[1])")[0][0]
    after = {x["product_code"]: x for x in get("/website-stock")[1]["data"]["comparison"]}["P001"]
    check("D3 sale leaves the website number unchanged", before["online_shown"], after["online_shown"])
    check("D3 sale lowers warehouse available by 1", before["actual_in_store"] - 1, after["actual_in_store"])
    s, e = get("/stock/events?product=P001&store=S01&limit=1")
    check("D5 the newest S01 event traces to its receipt number", f"STORE:receipt {sale_no} line 1",
          e["data"]["rows"][0]["source_ref"])

    write("SELECT supply.record_supplier_delivery('NSW-CHATS', 'SUP-01', 'PO-DASH-0', ARRAY['P001'], ARRAY[5])")
    ev, units, sydney_date = sql("""
        SELECT event_id::text, units, (event_ts AT TIME ZONE 'Australia/Sydney')::date::text
          FROM dw.fact_stock_event WHERE source_ref = 'SUPPLY:supplier SUP-01 order PO-DASH-0 line 1'""")[0]
    check("D3 supplier delivery converts 5 cartons to 20 units", 20, units)
    s, e = get(f"/stock/events?product=P001&store=S03&from={sydney_date}&to={sydney_date}")
    check("D6 history date filter includes the event on its Sydney date", True, ev in [x["event_id"] for x in e["data"]["rows"]])

    # --- 4. blocked checkout: report and source record --------------------------------
    for store_no, qty in sql("""SELECT store_no, in_store_quantity FROM store_ops.store_stock
                                 WHERE item_no = 'P018' AND in_store_quantity > 0 ORDER BY store_no"""):
        write("SELECT store_ops.record_sale(%s, ARRAY['P018'], ARRAY[%s])", (store_no, qty))
    p018 = {x["product_code"]: x for x in get("/website-stock")[1]["data"]["comparison"]}["P018"]
    check("D4 after the sell-out the website shows P018 too high", (0, True),
          (p018["actual_in_store"], p018["difference"] > 0))

    orders_before = sql("SELECT count(*) FROM online.web_order")[0][0]
    bag = write("SELECT online.create_basket('2026')")[0][0]
    write("SELECT online.add_to_basket(%s, 'P018', 1), 1", (bag,))
    check("D4 checkout is blocked (no order)", None, write("SELECT online.checkout(%s, NULL)", (bag,))[0][0])
    first_attempt = str(sql("SELECT max(attempt_no) FROM online.checkout_attempt WHERE basket_id = %s", (bag,))[0][0])
    check("D4 blocked checkout creates no order", orders_before, sql("SELECT count(*) FROM online.web_order")[0][0])
    blocked = [x for x in get("/checkout/blocked")[1]["data"]["rows"] if x["attempt_no"] == first_attempt]
    check("D4 blocked item appears in Report 3 with its attempt", (1, "P018"),
          (len(blocked), blocked[0]["product_code"] if blocked else None))
    s, a = get(f"/checkout/attempts/{first_attempt}")
    check("D4 source attempt shows no order and an open bag", ("blocked", None, "open"),
          (a["data"]["attempt"]["outcome"], a["data"]["attempt"]["order_no"], a["data"]["attempt"]["basket_status"]))
    write("SELECT online.remove_from_basket(%s, 'P018'), 1", (bag,))
    write("SELECT online.add_to_basket(%s, 'P001', 1), 1", (bag,))
    write("SELECT online.checkout(%s, NULL)", (bag,))
    s, o = get("/reservations")
    check("D4 the paid retry's lines are in the open reservations",
          sql("SELECT count(*) FROM dw.rpt_open_reservations")[0][0], len(o["data"]["rows"]))

    # --- sync ---------------------------------------------------------------------
    sched = get("/status")[1]["data"]["schedule"]
    check("D7 status reports the automatic sync (not started in the check database)",
          ("never started", None), (sched["scheduler_status"], sched["interval_seconds"]))
    write("SELECT online.sync_website_stock(now(), 'manual')")
    s, y = get("/sync/latest")
    check("D7 the latest sync is the manual one", "manual", y["data"]["run"]["triggered_by"])
    changes = {x["product_code"]: (x["before_qty"], x["after_qty"]) for x in y["data"]["website_changes"]}
    check("D1 sync corrects P018 to zero", 0, changes.get("P018", (None, None))[1])
    check("D1 latest sync lists only website corrections as website changes", True,
          all(x["measure"] == "online_available" for x in y["data"]["website_changes"]))
    check("D1 website change count comes from filtered rows, not numbers_changed",
          sql("SELECT count(*) FROM dw.sync_change WHERE changed AND measure = 'online_available' AND sync_id = %s",
              (y["data"]["run"]["sync_id"],))[0][0], len(y["data"]["website_changes"]))
    check("D1 store balance changes are separate", True,
          all(x["measure"] in ("in_store", "reserved") for x in y["data"]["store_changes"]))
    check("D8 after the sync the overview shows no wrong website numbers", 0,
          get("/overview")[1]["data"]["website"]["out_of_date"])

    # --- 5. unknown item: the shared data warning --------------------------------------
    write("SELECT supply.record_supplier_delivery('NSW-PARRA', 'SUP-02', 'PO-DASH-1', ARRAY['P019'], ARRAY[2])")
    write("SELECT store_ops.record_sale('101', ARRAY['P019'], ARRAY[1])")
    q = get("/status")[1]["data"]["quality"]
    check("D5 status warns that the warehouse may be incomplete", (True, 2, 1),
          (q["incomplete"], q["rejected_rows"], q["mismatched_pairs"]))
    check("D8 overview carries the same warning", True, get("/overview")[1]["data"]["quality"]["incomplete"])
    write("SELECT etl.add_item('P019'), 1")
    write("SELECT etl.run_etl('manual')")
    q = get("/status")[1]["data"]["quality"]
    check("D5 the warning clears once the item is added and the ETL runs", (False, 0, 0),
          (q["incomplete"], q["rejected_rows"], q["mismatched_pairs"]))

    # --- 6. disconnected state ------------------------------------------------------
    saved = os.environ.get("PGPORT")
    os.environ["PGPORT"] = "1"
    s, r = get("/status")
    if saved is None:
        os.environ.pop("PGPORT")
    else:
        os.environ["PGPORT"] = saved
    check("D6 unreachable database is a 503 with guidance", (503, "database_unavailable"), (s, r["error"]["code"]))

    httpd.shutdown()
    passed = sum(results)
    print(f"\nTOTAL: {len(results)} checks - PASS {passed}, FAIL {len(results) - passed}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
