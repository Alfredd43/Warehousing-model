"""PetHaven demo commands: make business events, run the sync, show reports.

Usage (from the repository root; prefix every command with
``docker compose exec python python /workspace/scripts/demo.py``)

  Business events (each goes to the source system that owns it)
    sale S01 P001 2 [P005 1 ...]     in-store till sale (one receipt, any number of items)
    supplier-delivery S03 P001 5     supplier delivery to a store, in CARTONS
          [--supplier SUP-01]        supplier ID (default: the item's supplier)
          [--order PO-2001]          supplier order number (default: numbered by the system)
    order 2026 P003 2 [P013 2 ...]   online bag from a customer postcode: shows the pickup options,
          [--pickup S03]             then checks out at the chosen store (default: best option).
                                     Real stock is checked BEFORE payment; blocked if any item is
                                     unavailable in every store
    options 9                        pickup options for bag 9 (stores holding at least one item)
    remove 9 P013                    remove an item from bag 9 (after a blocked checkout)
    checkout 9 [--pickup S02]        check out bag 9 again
    cancel-overdue [--days 3]        cancel click-and-collect orders not collected in time
    dispatch 6                       stores holding lines of order 6 send them to its pickup store
    receive 6                        pickup store books in the lines of order 6 that were sent
    collect 6                        customer collects order 6 (all lines must be at the pickup store)
    cancel 6 [--reason "..."]        order 6 cancelled, held stock back on a shelf

  Integration
    sync                             RUN SYNC NOW: website takes the shelf totals from the store
                                     system; the warehouse logs before/after of every change
    scheduler start [--interval N]   start the automatic sync in the background (every
                                     SYNC_INTERVAL_SECONDS = 180 s, from pethaven_db.py)
    scheduler stop | status          stop it / show its interval, last and next sync
    etl                              run one ETL pass by hand and show the latest runs
    add-item P019                    data steward adds an item to the warehouse product list
                                     (its rejected records load on the next ETL pass)
    codes                            the item list and each store's code in every system

  Reports
    online                           website number vs real stock, per product
    report stock [S01]               1 current stock by store (in-store vs reserved)
    report staleness                 2 time since last sync, pending events, last sync changes
    report blocked                   3 bag items blocked at checkout although the website showed them
    report sales                     4 units sold per day, store and category
    report reservations              5 click-and-collect order lines not yet collected (transfers too)
    report reconciliation            6 warehouse vs store system, plus rejected source rows
    report all                       all of the above

Products are given by item number (P001), which every system shares. Stores
can be given as warehouse codes (S01): the script translates them into each
system's own store code (store 101, NSW-PARRA, CP-PARRAMATTA) through the
approved store-code mapping and prints the translation. Any other store value
is passed to the source system unchanged.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

import psycopg2

import pethaven_db as db


def show(conn, title: str, sql: str, params=None) -> None:
    print(f"\n== {title} ==")
    db.print_table(*db.query(conn, sql, params))


def store_code(conn, system: str, code: str) -> str:
    """Translate a warehouse store code (S01) into a source system's store code."""
    _, rows = db.query(conn, "SELECT source_code FROM etl.store_xref WHERE source_system = %s AND store_code = %s",
                       (system, code))
    if rows:
        print(f"  {code} -> {system} store code {rows[0][0]}")
        return rows[0][0]
    return code


def show_position(conn, item_no: str, note: str = "unchanged until sync") -> None:
    """Live store stock for one item next to the website number."""
    show(conn, f"Live store stock for item {item_no} (Source 1)", """
        SELECT store_no, in_store_quantity, reserved_quantity, updated_at
          FROM store_ops.store_stock WHERE item_no = %s ORDER BY store_no""", (item_no,))
    show(conn, f"Website number (Source 3, {note})", """
        SELECT p.item_no, p.title, s.available_quantity AS online_shown, s.last_synced_at
          FROM online.product p JOIN online.online_stock s USING (item_no)
         WHERE p.item_no = %s""", (item_no,))


def show_new_facts(conn, since_event_id: int) -> None:
    show(conn, "Loaded into dw.fact_stock_event by the ETL", """
        SELECT f.event_id, f.event_type, s.store_code, p.product_code, f.quantity_change,
               f.reserved_change, f.order_ref, pk.store_code AS pickup, f.source_ref, f.etl_run_id
          FROM dw.fact_stock_event f
          JOIN dw.dim_store s USING (store_key) JOIN dw.dim_product p USING (product_key)
          LEFT JOIN dw.dim_store pk ON pk.store_key = f.pickup_store_key
         WHERE f.event_id > %s ORDER BY f.event_id""", (since_event_id,))
    _, rows = db.query(conn, "SELECT count(*) FROM etl.v_data_quality")
    if rows[0][0]:
        show(conn, "Rejected by the ETL (not in the warehouse)", "SELECT * FROM etl.v_data_quality")


def last_event_id(conn) -> int:
    return db.query(conn, "SELECT coalesce(max(event_id), 0) FROM dw.fact_stock_event")[1][0][0]


def cmd_sale(conn, args) -> None:
    if len(args.items) % 2:
        raise SystemExit("Give items as pairs: PRODUCT QUANTITY [PRODUCT QUANTITY ...]")
    store_no = store_code(conn, "STORE", args.store)
    item_nos = list(args.items[0::2])
    quantities = [int(q) for q in args.items[1::2]]
    before = last_event_id(conn)
    _, rows = db.query(conn, "SELECT store_ops.record_sale(%s, %s, %s)", (store_no, item_nos, quantities))
    conn.commit()
    print(f"Receipt number {rows[0][0]} saved at store {store_no}: {len(item_nos)} item(s).")
    show_new_facts(conn, before)
    for item_no in item_nos:
        show_position(conn, item_no)


def cmd_supplier_delivery(conn, args) -> None:
    location = store_code(conn, "SUPPLY", args.store)
    _, rows = db.query(conn, "SELECT supplier_id FROM supply.item WHERE item_no = %s", (args.product,))
    supplier = args.supplier or (rows[0][0] if rows else None)
    before = last_event_id(conn)
    _, rows = db.query(conn, "SELECT supply.record_supplier_delivery(%s, %s, %s, %s, %s)",
                       (location, supplier, args.order, [args.product], [args.cartons]))
    conn.commit()
    _, info = db.query(conn, """
        SELECT d.supplier_id, s.supplier_name, d.supplier_order_no, i.units_per_carton
          FROM supply.supplier_delivery d JOIN supply.supplier s USING (supplier_id)
          JOIN supply.supplier_delivery_line l USING (delivery_no)
          JOIN supply.item i ON i.item_no = l.item_no
         WHERE d.delivery_no = %s""", (rows[0][0],))
    supplier_id, supplier_name, order_no, upc = info[0]
    print(f"Supplier {supplier_id} ({supplier_name}), supplier order {order_no}, delivered to {location}: "
          f"{args.cartons} carton(s) x {upc} = {args.cartons * upc} units.")
    show_new_facts(conn, before)
    show_position(conn, args.product)


def show_order(conn, order_no: int) -> None:
    show(conn, f"Online order ID {order_no} (Source 3, paid)", """
        SELECT o.order_no, o.basket_id, o.customer_postcode, o.pickup_cp_code,
               l.line_no, l.item_no, l.quantity, l.website_qty_shown, l.source_cp_code
          FROM online.web_order o JOIN online.web_order_line l USING (order_no)
         WHERE o.order_no = %s ORDER BY l.line_no""", (order_no,))
    show(conn, f"Store system reservations for order {order_no} (Source 1)", """
        SELECT reservation_no, web_line_no, item_no, quantity, store_no AS taken_from,
               pickup_store_no, status
          FROM store_ops.reservation WHERE web_order_ref = %s ORDER BY web_line_no""", (str(order_no),))


def show_checkout(conn, basket_id: int, order_no, before: int) -> None:
    """Result of the latest checkout attempt for a bag."""
    show(conn, f"Checkout of bag {basket_id}: real stock check before payment", """
        SELECT a.attempt_no, a.outcome, a.pickup_cp_code, i.item_no, i.quantity,
               i.website_qty_shown, i.result, i.source_cp_code
          FROM online.checkout_attempt a JOIN online.checkout_attempt_item i USING (attempt_no)
         WHERE a.attempt_no = (SELECT max(attempt_no) FROM online.checkout_attempt WHERE basket_id = %s)
         ORDER BY i.item_no""", (basket_id,))
    if order_no is None:
        print(f"\nBLOCKED before payment: nothing charged, nothing held. Bag {basket_id} is still open.")
        print(f"Remove the unavailable items, then check out again, e.g.:")
        print(f"  demo.py remove {basket_id} <PRODUCT>   then   demo.py checkout {basket_id}")
    else:
        print(f"\nPAID: order ID {order_no} created.")
        show_order(conn, order_no)
    show_new_facts(conn, before)


def cmd_order(conn, args) -> None:
    if len(args.items) % 2:
        raise SystemExit("Give items as pairs: PRODUCT QUANTITY [PRODUCT QUANTITY ...]")
    item_nos = list(args.items[0::2])
    quantities = [int(q) for q in args.items[1::2]]
    before = last_event_id(conn)
    _, rows = db.query(conn, "SELECT online.create_basket(%s)", (args.postcode,))
    basket_id = rows[0][0]
    for item_no, qty in zip(item_nos, quantities):
        db.query(conn, "SELECT online.add_to_basket(%s, %s, %s), 1", (basket_id, item_no, qty))
    print(f"Bag {basket_id}: {len(item_nos)} item(s) added (the website showed them in stock).")
    show_options(conn, basket_id)
    pickup = store_code(conn, "ONLINE", args.pickup) if args.pickup else None
    _, rows = db.query(conn, "SELECT online.checkout(%s, %s)", (basket_id, pickup))
    conn.commit()
    show_checkout(conn, basket_id, rows[0][0], before)
    show(conn, "Website numbers (Source 3, lowered at once only if paid)", """
        SELECT item_no, available_quantity AS online_shown, last_synced_at
          FROM online.online_stock WHERE item_no = ANY(%s) ORDER BY item_no""", (item_nos,))


def cmd_remove(conn, args) -> None:
    db.query(conn, "SELECT online.remove_from_basket(%s, %s), 1", (args.basket_id, args.product))
    conn.commit()
    show(conn, f"Bag {args.basket_id}", """
        SELECT item_no, quantity, website_qty_at_add FROM online.basket_item
         WHERE basket_id = %s ORDER BY item_no""", (args.basket_id,))


def show_options(conn, basket_id: int) -> None:
    show(conn, f"Pickup options for bag {basket_id} (stores holding at least one item)", """
        SELECT * FROM online.pickup_options(%s)""", (basket_id,))


def cmd_options(conn, args) -> None:
    show_options(conn, args.basket_id)


def cmd_checkout(conn, args) -> None:
    before = last_event_id(conn)
    pickup = store_code(conn, "ONLINE", args.pickup) if args.pickup else None
    _, rows = db.query(conn, "SELECT online.checkout(%s, %s)", (args.basket_id, pickup))
    conn.commit()
    show_checkout(conn, args.basket_id, rows[0][0], before)


def cmd_cancel_overdue(conn, args) -> None:
    before = last_event_id(conn)
    _, rows = db.query(conn, "SELECT store_ops.cancel_overdue_orders(%s)", (args.days,))
    conn.commit()
    print(f"Cancelled {rows[0][0]} order(s) not collected within {args.days} days; stock back on the shelf.")
    show_new_facts(conn, before)


def _store_step(conn, order_no: int, function: str, *extra) -> None:
    before = last_event_id(conn)
    placeholders = ", ".join(["%s"] * (1 + len(extra)))
    _, rows = db.query(conn, f"SELECT store_ops.{function}({placeholders})", (str(order_no), *extra))
    conn.commit()
    print(f"{function}: {rows[0][0]} line(s) of order {order_no}.")
    show_order(conn, order_no)
    show_new_facts(conn, before)


def cmd_dispatch(conn, args) -> None:
    _store_step(conn, args.order_no, "dispatch_order_transfers")


def cmd_receive(conn, args) -> None:
    _store_step(conn, args.order_no, "receive_order_transfers")


def cmd_collect(conn, args) -> None:
    _store_step(conn, args.order_no, "collect_order")


def cmd_cancel(conn, args) -> None:
    _store_step(conn, args.order_no, "cancel_order", args.reason)


def cmd_etl(conn, args) -> None:
    before = last_event_id(conn)
    _, rows = db.query(conn, "SELECT etl.run_etl('manual')")
    conn.commit()
    print("ETL pass: " + ("nothing to do" if rows[0][0] is None else f"run {rows[0][0]}"))
    show_new_facts(conn, before)
    show(conn, "Latest ETL runs", """
        SELECT etl_run_id, trigger_source, started_at, rows_read, rows_loaded, rows_rejected, rows_skipped
          FROM etl.etl_run ORDER BY etl_run_id DESC LIMIT 5""")


def cmd_add_item(conn, args) -> None:
    db.query(conn, "SELECT etl.add_item(%s), 1", (args.item_no,))
    conn.commit()
    print(f"Added: {args.item_no} is on the warehouse product list. Run 'etl' (or 'sync') to load its waiting rows.")


def cmd_codes(conn, args) -> None:
    show(conn, "Items (one item number in every system)", """
        SELECT item_no, description, barcode, supplier_id, units_per_carton, sold_online, on_product_list
          FROM etl.v_item_list ORDER BY item_no""")
    show(conn, "Store codes in each system", "SELECT * FROM etl.v_store_codes ORDER BY store_code")


def cmd_online(conn, args) -> None:
    show(conn, "Website number vs real stock (Report 2 detail)", """
        SELECT product_code, product_name, online_shown, actual_in_store, overstated_by, status
          FROM dw.rpt_online_vs_actual ORDER BY product_code""")


def cmd_sync(conn, args) -> None:
    show(conn, "BEFORE sync: products whose website number is wrong", """
        SELECT product_code, product_name, online_shown, actual_in_store, status
          FROM dw.rpt_online_vs_actual WHERE status <> 'in sync' ORDER BY product_code""")
    _, rows = db.query(conn, "SELECT online.sync_website_stock(now(), 'manual')")
    conn.commit()
    sync_no = rows[0][0]
    show(conn, f"Online store: sync {sync_no} took the shelf totals from the store system", """
        SELECT sync_no, run_at, triggered_by, products_changed FROM online.stock_sync WHERE sync_no = %s""", (sync_no,))
    show(conn, "Warehouse record of this sync (for reporting)", """
        SELECT sync_id, source_sync_no, run_at, triggered_by, events_processed AS events_since_last_sync,
               numbers_changed, store_mismatches
          FROM dw.sync_run WHERE source_sync_no = %s""", (sync_no,))
    show(conn, "AFTER sync: every number that changed (before -> after)", """
        SELECT store_or_channel, product_code, product_name, measure, before_qty, after_qty, difference
          FROM dw.rpt_last_sync_changes
         ORDER BY measure = 'online_available' DESC, product_code, store_or_channel, measure""")


SCHEDULER = Path(__file__).with_name("sync_scheduler.py")
SCHEDULER_LOG = Path("/tmp/pethaven_sync_scheduler.log")
SCHEDULE_STATUS = """
    SELECT scheduler_status, sync_interval, last_sync_at, last_sync_trigger,
           time_since_sync, next_sync_at, products_out_of_date
      FROM dw.rpt_online_staleness"""


def _scheduler_state(conn) -> str:
    _, rows = db.query(conn, "SELECT scheduler_status FROM dw.rpt_online_staleness")
    conn.commit()
    return rows[0][0]


def cmd_scheduler(args) -> int:
    """Start / stop / show the automatic sync (scripts/sync_scheduler.py)."""
    conn = db.connect(args.database)
    try:
        state = _scheduler_state(conn)
        if args.action == "start":
            if state == "running":
                print("The sync scheduler is already running.")
            else:
                command = [sys.executable, str(SCHEDULER), "--database", args.database]
                if args.interval:
                    command += ["--interval", str(args.interval)]
                with open(SCHEDULER_LOG, "a", encoding="utf-8") as log:
                    subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
                for _ in range(50):
                    time.sleep(0.2)
                    state = _scheduler_state(conn)
                    if state == "running":
                        break
                if state != "running":
                    print(f"The scheduler did not start; see {SCHEDULER_LOG}")
                    return 1
                print(f"Sync scheduler started (log: {SCHEDULER_LOG}).")
        elif args.action == "stop":
            if state != "running":
                print(f"The sync scheduler is not running ({state}).")
            else:
                db.query(conn, """UPDATE online.sync_schedule SET status = 'stop_requested'
                                   WHERE schedule_id = 1 AND status = 'running' RETURNING 1""")
                conn.commit()
                for _ in range(50):
                    time.sleep(0.2)
                    _, rows = db.query(conn, "SELECT status FROM online.sync_schedule")
                    conn.commit()
                    if rows and rows[0][0] == "stopped":
                        break
                print("Sync scheduler stopped. The website now changes only on a manual sync (demo.py sync).")
        show(conn, "Automatic sync", SCHEDULE_STATUS)
    finally:
        conn.close()
    return 0


REPORTS = {
    "stock": ("Report 1: current stock by store (in-store vs reserved)", """
        SELECT store_name, product_code, product_name, in_store_quantity, reserved_quantity, total_on_hand, low_stock
          FROM dw.rpt_current_stock_by_store
         WHERE %(store)s IS NULL OR store_code = %(store)s
         ORDER BY store_code, product_code"""),
    "staleness": ("Report 2: online staleness", "SELECT * FROM dw.rpt_online_staleness"),
    "blocked": ("Report 3: items blocked at checkout (before payment)", """
        SELECT basket, attempted_at, product_code, product_name, quantity_in_bag, pickup_store,
               website_showed, actual_combined_at_checkout, reason
          FROM dw.rpt_checkout_blocked ORDER BY attempted_at"""),
    "sales": ("Report 4: daily sales (in-store and online)", """
        SELECT full_date, day_name, store_name, channel, category, units_sold, sales_value_at_current_price
          FROM dw.rpt_daily_sales ORDER BY full_date, store_name, channel, category"""),
    "reservations": ("Report 5: click-and-collect order lines not yet collected", """
        SELECT * FROM dw.rpt_open_reservations ORDER BY reserved_at, order_no, product_code"""),
    "reconciliation": ("Report 6: warehouse vs store system (anything not matching)", """
        SELECT * FROM dw.rpt_reconciliation WHERE status <> 'match' ORDER BY store_no, item_no"""),
}


def cmd_report(conn, args) -> None:
    for name in (REPORTS if args.which == "all" else [args.which]):
        title, sql = REPORTS[name]
        show(conn, title, sql, {"store": args.store} if name == "stock" else None)
        if name == "staleness":
            show(conn, "Report 2: changes made by the last sync", """
                SELECT sync_id, run_at, store_or_channel, product_code, measure, before_qty, after_qty, difference
                  FROM dw.rpt_last_sync_changes
                 ORDER BY measure = 'online_available' DESC, product_code, store_or_channel, measure""")
        if name == "reconciliation":
            _, rows = db.query(conn, "SELECT count(*) FROM dw.rpt_reconciliation WHERE status = 'match'")
            print(f"({rows[0][0]} store/product pairs match)")
            show(conn, "Source rows rejected by the ETL", "SELECT * FROM etl.v_data_quality")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("sale", help="till sale (one receipt)")
    p.add_argument("store"); p.add_argument("items", nargs="+", help="PRODUCT QUANTITY pairs")
    p.set_defaults(func=cmd_sale)

    p = sub.add_parser("supplier-delivery", help="supplier delivery in cartons")
    p.add_argument("store"); p.add_argument("product", help="item number, e.g. P001"); p.add_argument("cartons", type=int)
    p.add_argument("--supplier", help="supplier ID, e.g. SUP-01 (default: the item's supplier)")
    p.add_argument("--order", help="supplier order number (default: numbered by the system)")
    p.set_defaults(func=cmd_supplier_delivery)

    p = sub.add_parser("order", help="online bag + checkout")
    p.add_argument("postcode"); p.add_argument("items", nargs="+", help="PRODUCT QUANTITY pairs")
    p.add_argument("--pickup", help="pickup store, e.g. S03 (default: best option)")
    p.set_defaults(func=cmd_order)

    p = sub.add_parser("options", help="pickup options for a bag")
    p.add_argument("basket_id", type=int)
    p.set_defaults(func=cmd_options)

    p = sub.add_parser("cancel-overdue", help="cancel orders not collected in time")
    p.add_argument("--days", type=int, default=3)
    p.set_defaults(func=cmd_cancel_overdue)

    p = sub.add_parser("remove", help="remove an item from an open bag")
    p.add_argument("basket_id", type=int); p.add_argument("product")
    p.set_defaults(func=cmd_remove)

    p = sub.add_parser("checkout", help="check out an open bag again")
    p.add_argument("basket_id", type=int)
    p.add_argument("--pickup", help="pickup store, e.g. S02 (default: best option)")
    p.set_defaults(func=cmd_checkout)

    for name, func, text in (("dispatch", cmd_dispatch, "send an order's lines to its pickup store"),
                             ("receive", cmd_receive, "pickup store books in sent lines"),
                             ("collect", cmd_collect, "customer collects an online order")):
        p = sub.add_parser(name, help=text)
        p.add_argument("order_no", type=int)
        p.set_defaults(func=func)

    p = sub.add_parser("cancel", help="cancel an online order")
    p.add_argument("order_no", type=int); p.add_argument("--reason", default="Customer cancelled")
    p.set_defaults(func=cmd_cancel)

    sub.add_parser("sync", help="run sync now").set_defaults(func=cmd_sync)
    sub.add_parser("etl", help="run one ETL pass").set_defaults(func=cmd_etl)

    p = sub.add_parser("add-item", help="add an item to the warehouse product list")
    p.add_argument("item_no")
    p.set_defaults(func=cmd_add_item)

    p = sub.add_parser("scheduler", help="automatic sync: start / stop / status")
    p.add_argument("action", choices=["start", "stop", "status"])
    p.add_argument("--interval", type=int, help=f"seconds between syncs (default {db.SYNC_INTERVAL_SECONDS})")
    p.add_argument("--database", default=db.DEMO_DATABASE, help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_scheduler, own_connection=True)

    sub.add_parser("codes", help="code look-up").set_defaults(func=cmd_codes)
    sub.add_parser("online", help="website number vs real stock").set_defaults(func=cmd_online)

    p = sub.add_parser("report", help="show reports")
    p.add_argument("which", choices=[*REPORTS, "all"])
    p.add_argument("store", nargs="?", help="store code for the stock report, e.g. S01")
    p.set_defaults(func=cmd_report)

    args = parser.parse_args()
    if getattr(args, "own_connection", False):
        return args.func(args)
    conn = db.connect()
    try:
        args.func(conn, args)
    except psycopg2.Error as exc:
        conn.rollback()
        print(f"Refused: {exc.diag.message_primary or exc}")
        return 1
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
