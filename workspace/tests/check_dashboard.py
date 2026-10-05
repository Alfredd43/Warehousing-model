"""API checks for the PetHaven dashboard.

Builds the separate check database (pethaven_check, never the demo database),
starts the dashboard server in this process on a free local port, and checks
its read and write endpoints against the report views and business rules.
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


def post(path, body=None, headers=None):
    return request("POST", path, body if body is not None else {}, headers)


def sql(query, params=None):
    conn = db.connect(db.CHECK_DATABASE)
    try:
        return db.query(conn, query, params)[1]
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

    # --- 2. validation and refusals ------------------------------------------------
    check("D2 bad product code is refused", 400, get("/stock/events?product=P001;drop")[0])
    check("D2 unknown staging table is refused", 400, get("/integration/staging?table=pg_user")[0])
    check("D2 unknown trace table is refused", 400, get("/integration/trace?table=pg_authid&id=1")[0])
    check("D2 missing attempt is 404", 404, get("/checkout/attempts/999999")[0])
    check("D2 unknown endpoint is 404", 404, get("/nope")[0])
    check("D2 zero quantity is 422", 422, post("/demo/sales", {"store": "S01", "items": [{"product": "P001", "quantity": 0}]})[0])
    check("D2 non-JSON write is 415", 415,
          request("POST", "/demo/sync", None, {"Content-Type": "text/plain"})[0])
    check("D2 cross-origin write is 403", 403, post("/demo/sync", {}, {"Origin": "http://evil.example"})[0])
    s, r = post("/demo/sales", {"store": "S01", "items": [{"product": "P018", "quantity": 99}]})
    check("D2 shelf shortage is a 409 business refusal", (409, "refused"), (s, r["error"]["code"]))

    # --- 3. sale and delivery effects through existing functions ---------------------
    before = {x["product_code"]: x for x in get("/website-stock")[1]["data"]["comparison"]}["P001"]
    s, r = post("/demo/sales", {"store": "S01", "items": [{"product": "P001", "quantity": 1}]})
    check("D3 sale returns its receipt and a loaded fact", (200, "loaded"), (s, r["data"]["staging"][0]["load_status"]))
    after = {x["product_code"]: x for x in get("/website-stock")[1]["data"]["comparison"]}["P001"]
    check("D3 sale leaves the website number unchanged", before["online_shown"], after["online_shown"])
    check("D3 sale lowers warehouse available by 1", before["actual_in_store"] - 1, after["actual_in_store"])

    s, r = post("/demo/deliveries", {"location": "S03", "supplier_name": "Pawfect Foods",
                                     "items": [{"sku": "PF-DOG-ADT-3K", "cartons": 5}]})
    line = r["data"]["lines"][0]
    check("D3 delivery converts cartons to units", (5, 4, 20), (line["cartons"], line["units_per_carton"], line["units"]))
    ev = r["data"]["staging"][0]["event_id"]
    s, t = get(f"/integration/trace?event_id={ev}")
    tr = t["data"]
    check("D5 delivery trace links source, staging and fact",
          ("SUPPLY", "loaded", ev, 20), (tr["source"]["system"], tr["staging"]["load_status"], tr["warehouse"]["event_id"], tr["warehouse"]["units"]))
    sydney_date = sql("SELECT (event_ts AT TIME ZONE 'Australia/Sydney')::date::text FROM dw.fact_stock_event WHERE event_id = %s", (int(ev),))[0][0]
    check("D6 business date is the Sydney date of the event", sydney_date, tr["warehouse"]["business_date"])
    s, e = get(f"/stock/events?product=P001&store=S03&from={sydney_date}&to={sydney_date}")
    check("D6 history date filter includes the event on its Sydney date", True, ev in [x["event_id"] for x in e["data"]["rows"]])

    # --- 4. blocked checkout: committed evidence, no partial hold, retry ------------------
    s, p = get("/demo/scenarios/sell-out?product=P018")
    planned = p["data"]["sales_planned"]
    s, r = post("/demo/scenarios/sell-out", {"product": "P018", "expected": [{"store_no": x["store_no"], "quantity": x["quantity"]} for x in planned]})
    check("D4 sell-out scenario leaves no free P018 stock", (200, 0), (s, r["data"]["website_vs_shelf"][0]["shelf_total_all_stores"]))
    s, r = post("/demo/scenarios/sell-out", {"product": "P018", "expected": [{"store_no": "101", "quantity": 1}]})
    check("D4 sell-out refuses a stale preview", 409, s)

    orders_before = sql("SELECT count(*) FROM online.web_order")[0][0]
    holds_before = sql("SELECT count(*) FROM store_ops.reservation")[0][0]
    bag = post("/demo/baskets", {"postcode": "2026"})[1]["data"]["basket"]["basket_id"]
    check("D4 stale website number lets the item into the bag", 200,
          post(f"/demo/baskets/{bag}/items", {"product": "P018", "quantity": 1})[0])
    s, c = post(f"/demo/baskets/{bag}/checkout", {})
    first_attempt = c["data"]["attempt_no"]
    check("D4 checkout is recorded as blocked (HTTP 200)", (200, "blocked", None), (s, c["data"]["outcome"], c["data"]["order_no"]))
    check("D4 blocked checkout creates no order and no hold", (orders_before, holds_before),
          (sql("SELECT count(*) FROM online.web_order")[0][0], sql("SELECT count(*) FROM store_ops.reservation")[0][0]))
    blocked = [x for x in get("/checkout/blocked")[1]["data"]["rows"] if x["attempt_no"] == first_attempt]
    check("D4 blocked item appears in Report 3 with its attempt", (1, "P018"), (len(blocked), blocked[0]["product_code"] if blocked else None))
    s, a = get(f"/checkout/attempts/{first_attempt}")
    check("D4 source attempt shows no order and an open bag", ("blocked", None, "open"),
          (a["data"]["attempt"]["outcome"], a["data"]["attempt"]["order_no"], a["data"]["attempt"]["basket_status"]))
    post(f"/demo/baskets/{bag}/remove-item", {"product": "P018"})
    post(f"/demo/baskets/{bag}/items", {"product": "P001", "quantity": 1})
    s, c2 = post(f"/demo/baskets/{bag}/checkout", {})
    check("D4 retry after editing the bag is paid", "paid", c2["data"]["outcome"])
    check("D4 repeated attempts from one bag stay separate", True, c2["data"]["attempt_no"] != first_attempt)
    s, b = post(f"/demo/baskets/{bag}/items", {"product": "P001", "quantity": 1})
    check("D4 a checked-out bag refuses changes", 409, s)

    # --- sync ---------------------------------------------------------------------
    s, r = post("/demo/sync", {})
    changes = {x["product_code"]: (x["before_qty"], x["after_qty"]) for x in r["data"]["website_changes"]}
    check("D1 sync corrects P018 to zero", 0, changes.get("P018", (None, None))[1])
    s, y = get("/sync/latest")
    check("D1 latest sync lists only website corrections as website changes", True,
          all(x["measure"] == "online_available" for x in y["data"]["website_changes"]))
    check("D1 website change count comes from filtered rows, not numbers_changed",
          sql("SELECT count(*) FROM dw.sync_change WHERE changed AND measure = 'online_available' AND sync_id = %s",
              (y["data"]["run"]["sync_id"],))[0][0], len(y["data"]["website_changes"]))
    check("D1 store balance changes are separate", True,
          all(x["measure"] in ("in_store", "reserved") for x in y["data"]["store_changes"]))
    bag2 = post("/demo/baskets", {"postcode": "2026"})[1]["data"]["basket"]["basket_id"]
    s, r = post(f"/demo/baskets/{bag2}/items", {"product": "P018", "quantity": 1})
    check("D4 after sync the item cannot enter a bag (refusal, not a blocked checkout)", 409, s)
    s, ss = get("/integration/sync-staging?limit=200")
    check("D5 sync records link to their warehouse sync", True, all(x["warehouse_sync_id"] for x in ss["data"]["rows"]))

    # --- 5. unmapped product: rejection and recovery --------------------------------
    s, r = post("/demo/deliveries", {"location": "NSW-PARRA", "supplier_name": "PlayPets Wholesale",
                                     "items": [{"sku": "PP-CAT-TUNNEL", "cartons": 2}]})
    stg = r["data"]["staging"][0]
    check("D5 unmapped delivery succeeds in its source but is rejected by the ETL", (200, "rejected"), (s, stg["load_status"]))
    s, t = get(f"/integration/trace?table={stg['stg_table']}&id={stg['stg_id']}")
    check("D5 rejected trace has no warehouse row", (None, None), (t["data"]["warehouse"], t["data"]["transform"]["product"]["warehouse_code"]))
    post("/demo/sales", {"store": "S01", "items": [{"product": "9300601001194", "quantity": 1}]})
    q = get("/integration/quality")[1]["data"]
    check("D5 quality shows rejections and the reconciliation gap", (2, 1), (len(q["rejected"]), q["summary"]["mismatched_pairs"]))
    check("D5 status warns that the warehouse may be incomplete", True, get("/status")[1]["data"]["quality"]["incomplete"])
    check("D5 mapping approval needs an existing source code", 404,
          post("/demo/mappings/approve", {"source_system": "SUPPLY", "source_code": "NOPE", "product_code": "P019"})[0])
    for system, code in (("SUPPLY", "PP-CAT-TUNNEL"), ("STORE", "9300601001194")):
        check(f"D5 approve {system} mapping", 200,
              post("/demo/mappings/approve", {"source_system": system, "source_code": code, "product_code": "P019"})[0])
    check("D5 an approved code cannot be re-approved here", 409,
          post("/demo/mappings/approve", {"source_system": "STORE", "source_code": "9300601001194", "product_code": "P019"})[0])
    s, e1 = post("/demo/etl", {})
    check("D5 ETL loads the waiting rows", (2, 0), (e1["data"]["run"]["rows_loaded"], e1["data"]["run"]["rows_rejected"]))
    s, e2 = post("/demo/etl", {})
    check("D5 a second ETL pass has nothing to do", None, e2["data"]["etl_run_id"])
    check("D5 no duplicate facts for the recovered records", 2, sql(
        "SELECT count(*) FROM dw.fact_stock_event WHERE source_ref IN (%s, %s)",
        (stg["source_ref"], "STORE:sale %s line 1" % sql("SELECT max(sale_no) FROM store_ops.sale")[0][0]))[0][0])
    q = get("/integration/quality")[1]["data"]["summary"]
    check("D5 reconciliation matches again", (0, 0), (q["rejected_rows"], q["mismatched_pairs"]))

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
