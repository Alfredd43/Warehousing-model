"""Business-demo operations behind the dashboard's POST endpoints.

Each operation validates its input, calls the EXISTING source-system or ETL
function (never a direct stock update), commits, and then reads back what
that call actually created: the generated identifiers, the staged copies and
the warehouse rows linked to them. Nothing here reimplements a business rule.

Items are given by item number (P001), the same in every system. Stores can
be given as warehouse store codes (S01), translated to each system's own
store code through the approved store-code mapping.

A blocked checkout is a normal committed result (online.checkout returns
NULL); it is committed, not rolled back, so its evidence reaches the reports.
"""

from __future__ import annotations

import re

from queries import BadRequest, NotFound, row, rows, value


class Refused(Exception):
    """The business system refused the operation in its current state (HTTP 409)."""

    def __init__(self, message: str, detail=None):
        super().__init__(message)
        self.detail = detail


MAX_UNITS = 999
ITEM_NO = r"P[0-9]{3}"


# --- input helpers --------------------------------------------------------------
def _text(body: dict, name: str, *, required: bool = True, pattern: str | None = None) -> str | None:
    v = body.get(name)
    if v is None or (isinstance(v, str) and not v.strip()):
        if required:
            raise BadRequest(f"'{name}' is required")
        return None
    if not isinstance(v, str):
        raise BadRequest(f"'{name}' must be text")
    v = v.strip()
    if pattern and not re.fullmatch(pattern, v):
        raise BadRequest(f"Invalid value for '{name}'")
    return v


def _qty(v, name: str) -> int:
    if isinstance(v, bool) or not isinstance(v, int):
        if isinstance(v, str) and v.strip().isdigit():
            v = int(v.strip())
        else:
            raise BadRequest(f"'{name}' must be a positive whole number")
    if v <= 0 or v > MAX_UNITS:
        raise BadRequest(f"'{name}' must be between 1 and {MAX_UNITS}")
    return v


def _id(v, name: str) -> int:
    s = str(v).strip() if v is not None else ""
    if not s.isdigit():
        raise BadRequest(f"'{name}' must be a whole number")
    return int(s)


def _items(body: dict, qty_key: str) -> list[tuple[str, int]]:
    items = body.get("items")
    if not isinstance(items, list) or not items:
        raise BadRequest("Give at least one item")
    if len(items) > 20:
        raise BadRequest("At most 20 items per operation")
    out = []
    for n, it in enumerate(items, 1):
        if not isinstance(it, dict):
            raise BadRequest(f"Item {n} is not valid")
        code = _text(it, "product")
        out.append((code, _qty(it.get(qty_key), f"item {n} {qty_key}")))
    codes = [c for c, _ in out]
    if len(set(codes)) != len(codes):
        raise BadRequest("Each item can appear only once")
    return out


def _store_code(conn, system: str, code: str, exists_sql: str) -> str:
    """Warehouse store code (S01) -> the source system's own store code, through
    the approved store-code mapping. Any other value must already exist in the source."""
    if re.fullmatch(r"S0[1-9]", code):
        mapped = value(conn, "SELECT source_code FROM etl.store_xref WHERE source_system = %s AND store_code = %s",
                       (system, code))
        if mapped is None:
            raise NotFound(f"{code} has no approved {system} store code")
        return mapped
    if value(conn, exists_sql, (code,)) is None:
        raise NotFound(f"Unknown {system} store code {code}")
    return code


def store_no(conn, code: str) -> str:
    return _store_code(conn, "STORE", code, "SELECT 1 FROM store_ops.store WHERE store_no = %s")


def location(conn, code: str) -> str:
    return _store_code(conn, "SUPPLY", code, "SELECT 1 FROM supply.location WHERE location_code = %s")


def cp_code(conn, code: str) -> str:
    return _store_code(conn, "ONLINE", code, "SELECT 1 FROM online.collection_point WHERE cp_code = %s")


CATALOGUES = {
    "store": ("store_ops.product", "the store catalogue"),
    "supplier": ("supply.item", "the supplier delivery system"),
    "online": ("online.product", "the online store"),
}


def item_no(conn, code: str, system: str) -> str:
    """An item number that exists in the given system's catalogue."""
    if not re.fullmatch(ITEM_NO, code or ""):
        raise BadRequest("Give an item number such as P001")
    table, label = CATALOGUES[system]
    if value(conn, f"SELECT 1 FROM {table} WHERE item_no = %s", (code,)) is None:
        raise NotFound(f"Item {code} is not in {label}")
    return code


# --- read-back helpers -------------------------------------------------------------
def staged(conn, table: str, ref_pattern: str) -> list[dict]:
    """Staging rows (and their fact rows) created by one operation."""
    assert table in {"stg_store_sale_line", "stg_supplier_delivery_line", "stg_reservation_change", "stg_checkout_item"}
    return rows(conn, f"""
        SELECT '{table}' AS stg_table, s.stg_id::text AS stg_id, s.source_ref, s.load_status, s.note,
               s.etl_run_id, s.event_id::text AS event_id, f.event_type, p.product_code, st.store_code,
               f.quantity_change AS available_change, f.reserved_change
          FROM etl.{table} s
          LEFT JOIN dw.fact_stock_event f ON f.event_id = s.event_id
          LEFT JOIN dw.dim_product p ON p.product_key = f.product_key
          LEFT JOIN dw.dim_store st ON st.store_key = f.store_key
         WHERE s.source_ref LIKE %s
         ORDER BY s.stg_id""", (ref_pattern,))


def _like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def website_vs_shelf(conn, item_nos: list[str]) -> list[dict]:
    return rows(conn, """
        SELECT sp.item_no, sp.item_no AS product_code, sp.description,
               (SELECT sum(in_store_quantity) FROM store_ops.store_stock ss WHERE ss.item_no = sp.item_no)
                   AS shelf_total_all_stores,
               os.available_quantity AS website_shown, op.item_no IS NOT NULL AS sold_online
          FROM store_ops.product sp
          LEFT JOIN online.product op ON op.item_no = sp.item_no
          LEFT JOIN online.online_stock os ON os.item_no = sp.item_no
         WHERE sp.item_no = ANY(%s)
         ORDER BY sp.item_no""", (item_nos,))


def basket_view(conn, basket_id: int) -> dict:
    b = row(conn, """
        SELECT b.basket_id::text AS basket_id, b.customer_postcode, pl.suburb, b.status, b.created_at,
               b.checked_out_at
          FROM online.basket b JOIN online.postcode_location pl ON pl.postcode = b.customer_postcode
         WHERE b.basket_id = %s""", (basket_id,))
    if b is None:
        raise NotFound(f"Bag {basket_id} does not exist")
    b["items"] = rows(conn, """
        SELECT i.item_no, p.title, i.quantity, i.website_qty_at_add,
               s.available_quantity AS website_shown_now, i.added_at
          FROM online.basket_item i
          JOIN online.product p ON p.item_no = i.item_no
          JOIN online.online_stock s ON s.item_no = i.item_no
         WHERE i.basket_id = %s ORDER BY i.item_no""", (basket_id,))
    b["attempts"] = rows(conn, """
        SELECT attempt_no::text AS attempt_no, attempted_at, outcome, order_no::text AS order_no, pickup_cp_code
          FROM online.checkout_attempt WHERE basket_id = %s ORDER BY attempt_no""", (basket_id,))
    return b


def pickup_options(conn, basket_id: int) -> list[dict]:
    basket_view(conn, basket_id)   # 404 if missing
    return rows(conn, """
        SELECT o.option_rank, o.cp_code, o.cp_name, x.store_code, o.distance_km,
               o.items_here, o.items_transferred, o.items_unavailable
          FROM online.pickup_options(%s) o
          LEFT JOIN etl.store_xref x ON x.source_system = 'ONLINE' AND x.source_code = o.cp_code
         ORDER BY o.option_rank""", (basket_id,))


# --- operations ------------------------------------------------------------------------
def record_sale(conn, body: dict) -> dict:
    store = store_no(conn, _text(body, "store"))
    items = [(item_no(conn, code, "store"), qty) for code, qty in _items(body, "quantity")]
    sale_no = value(conn, "SELECT store_ops.record_sale(%s, %s, %s)",
                    (store, [i for i, _ in items], [q for _, q in items]))
    conn.commit()
    return {"sale_no": str(sale_no), "store_no": store,
            "lines": [{"item_no": i, "quantity": q} for i, q in items],
            "staging": staged(conn, "stg_store_sale_line", f"STORE:receipt {sale_no} line %"),
            "website_vs_shelf": website_vs_shelf(conn, [i for i, _ in items]),
            "message": f"Receipt number {sale_no} recorded at store {store}. "
                       "The website number is unchanged until the next sync."}


def record_supplier_delivery(conn, body: dict) -> dict:
    loc = location(conn, _text(body, "location"))
    items = [(item_no(conn, code, "supplier"), qty) for code, qty in _items(body, "cartons")]
    supplier = _text(body, "supplier_id", required=False, pattern=r"SUP-[0-9]{2}")
    if supplier is None:
        suppliers = {value(conn, "SELECT supplier_id FROM supply.item WHERE item_no = %s", (i,)) for i, _ in items}
        if len(suppliers) != 1:
            raise BadRequest("These items come from different suppliers; give 'supplier_id'")
        supplier = suppliers.pop()
    elif value(conn, "SELECT 1 FROM supply.supplier WHERE supplier_id = %s", (supplier,)) is None:
        raise NotFound(f"Unknown supplier ID {supplier}")
    order = _text(body, "supplier_order_no", required=False, pattern=r"[A-Za-z0-9-]{1,30}")
    if order and value(conn, """SELECT 1 FROM supply.supplier_delivery
                                 WHERE supplier_id = %s AND supplier_order_no = %s""", (supplier, order)):
        raise Refused(f"Supplier {supplier} order {order} has already been delivered.")
    delivery_no = value(conn, "SELECT supply.record_supplier_delivery(%s, %s, %s, %s, %s)",
                        (loc, supplier, order, [i for i, _ in items], [c for _, c in items]))
    conn.commit()
    head = row(conn, """
        SELECT d.supplier_id, s.supplier_name, d.supplier_order_no
          FROM supply.supplier_delivery d JOIN supply.supplier s USING (supplier_id)
         WHERE d.delivery_no = %s""", (delivery_no,))
    lines = rows(conn, """
        SELECT l.line_no, l.item_no, l.cartons, i.units_per_carton, l.cartons * i.units_per_carton AS units,
               to_char(d.delivered_at_utc, 'YYYY-MM-DD HH24:MI:SS') AS delivered_at_utc,
               d.delivered_at_utc AT TIME ZONE 'UTC' AS delivered_at_sydney
          FROM supply.supplier_delivery_line l
          JOIN supply.supplier_delivery d USING (delivery_no)
          JOIN supply.item i ON i.item_no = l.item_no
         WHERE l.delivery_no = %s ORDER BY l.line_no""", (delivery_no,))
    ref = f"SUPPLY:supplier {_like(head['supplier_id'])} order {_like(head['supplier_order_no'])} line %"
    return {"delivery_no": str(delivery_no), "location_code": loc, **head, "lines": lines,
            "staging": staged(conn, "stg_supplier_delivery_line", ref),
            "website_vs_shelf": website_vs_shelf(conn, [l["item_no"] for l in lines]),
            "message": f"Supplier {head['supplier_id']} ({head['supplier_name']}) order {head['supplier_order_no']} "
                       f"delivered at {loc}. The website number is unchanged until the next sync."}


def create_basket(conn, body: dict) -> dict:
    postcode = _text(body, "postcode", pattern=r"[0-9]{4}")
    basket_id = value(conn, "SELECT online.create_basket(%s)", (postcode,))
    conn.commit()
    return {"basket": basket_view(conn, basket_id), "message": f"Bag {basket_id} created."}


def set_basket_item(conn, basket_id: str, body: dict) -> dict:
    bid = _id(basket_id, "basket")
    basket_view(conn, bid)
    item = item_no(conn, _text(body, "product"), "online")
    qty = _qty(body.get("quantity"), "quantity")
    value(conn, "SELECT online.add_to_basket(%s, %s, %s), 1", (bid, item, qty))
    conn.commit()
    return {"basket": basket_view(conn, bid),
            "message": f"{item}: quantity in bag set to {qty}. Nothing is held until checkout."}


def remove_basket_item(conn, basket_id: str, body: dict) -> dict:
    bid = _id(basket_id, "basket")
    basket_view(conn, bid)
    item = item_no(conn, _text(body, "product"), "online")
    value(conn, "SELECT online.remove_from_basket(%s, %s), 1", (bid, item))
    conn.commit()
    return {"basket": basket_view(conn, bid), "message": f"{item} removed from bag {bid}."}


def checkout(conn, basket_id: str, body: dict) -> dict:
    bid = _id(basket_id, "basket")
    basket_view(conn, bid)
    pickup = _text(body, "pickup", required=False)
    pickup = cp_code(conn, pickup) if pickup else None
    order_no = value(conn, "SELECT online.checkout(%s, %s)", (bid, pickup))
    # This request's attempt: checkout locked the bag row, so the newest
    # attempt for this bag inside this transaction is the one just made.
    attempt_no = value(conn, "SELECT max(attempt_no) FROM online.checkout_attempt WHERE basket_id = %s", (bid,))
    conn.commit()
    items = rows(conn, """
        SELECT i.item_no, i.item_no AS product_code, i.quantity, i.website_qty_shown, i.result, i.source_cp_code
          FROM online.checkout_attempt_item i
         WHERE i.attempt_no = %s ORDER BY i.item_no""", (attempt_no,))
    reservations = rows(conn, """
        SELECT reservation_no::text AS reservation_no, web_line_no, item_no, quantity,
               store_no AS taken_from, pickup_store_no, status
          FROM store_ops.reservation WHERE web_order_ref = %s ORDER BY web_line_no""",
                        (str(order_no),)) if order_no else []
    outcome = "paid" if order_no else "blocked"
    unavailable = [i for i in items if i["result"] == "unavailable"]
    return {"outcome": outcome, "attempt_no": str(attempt_no),
            "order_no": str(order_no) if order_no else None,
            "items": items, "unavailable_items": unavailable, "reservations": reservations,
            "staging": staged(conn, "stg_checkout_item", f"ONLINE:checkout attempt {attempt_no} item %"),
            "basket": basket_view(conn, bid),
            "message": (f"Paid: order ID {order_no} created; every item is held at its supplying store."
                        if order_no else
                        f"Checkout blocked before payment: {len(unavailable)} item(s) unavailable in any single "
                        f"store. Nothing was charged or held; bag {bid} is still open.")}


def sync(conn, body: dict) -> dict:
    sync_no = value(conn, "SELECT online.sync_website_stock(now(), 'manual')")
    conn.commit()
    run = row(conn, """
        SELECT sync_id, source_sync_no::text AS source_sync_no, run_at, triggered_by, events_processed,
               numbers_changed, store_mismatches
          FROM dw.sync_run WHERE source_sync_no = %s""", (sync_no,))
    changes = rows(conn, """
        SELECT l.item_no, l.item_no AS product_code, l.before_qty, l.after_qty, l.after_qty - l.before_qty AS change
          FROM online.stock_sync_line l
         WHERE l.sync_no = %s AND l.before_qty <> l.after_qty ORDER BY l.item_no""", (sync_no,))
    return {"source_sync_no": str(sync_no), "warehouse_sync": run, "website_changes": changes,
            "message": f"Manual sync {sync_no} copied the store system's shelf totals to the website; "
                       f"{len(changes)} website quantit{'y' if len(changes) == 1 else 'ies'} changed."}


def add_item(conn, body: dict) -> dict:
    """Data-steward action: put an item on the warehouse product list."""
    item = _text(body, "item_no", pattern=ITEM_NO)
    if value(conn, "SELECT 1 FROM store_ops.product WHERE item_no = %s", (item,)) is None:
        raise NotFound(f"Item {item} is not in the store catalogue")
    if value(conn, "SELECT 1 FROM etl.item_list WHERE item_no = %s", (item,)) is not None:
        raise Refused(f"Item {item} is already on the warehouse product list.")
    value(conn, "SELECT etl.add_item(%s), 1", (item,))
    conn.commit()
    waiting = value(conn, """
        SELECT count(*) FROM etl.v_transform WHERE item_no = %s AND event_type IS NOT NULL""", (item,))
    return {"item_no": item, "records_waiting": waiting,
            "message": f"{item} added to the warehouse product list. Records already staged are not loaded "
                       f"yet; run the ETL to retry them ({waiting} waiting)."}


def run_etl(conn, body: dict) -> dict:
    run_id = value(conn, "SELECT etl.run_etl('manual')")
    conn.commit()
    if run_id is None:
        return {"etl_run_id": None, "run": None, "message": "No pending records to process."}
    run = row(conn, """
        SELECT etl_run_id, trigger_source, started_at, finished_at, rows_read, rows_loaded,
               rows_rejected, rows_skipped
          FROM etl.etl_run WHERE etl_run_id = %s""", (run_id,))
    handled = rows(conn, """
        SELECT stg_table, stg_id::text AS stg_id, source_ref, load_status, note, event_id::text AS event_id
          FROM etl.v_staging WHERE etl_run_id = %s ORDER BY stg_table, stg_id""", (run_id,))
    return {"etl_run_id": run_id, "run": run, "handled": handled,
            "message": f"ETL run {run_id}: {run['rows_loaded']} loaded, {run['rows_rejected']} still rejected, "
                       f"{run['rows_skipped']} skipped."}


# --- order lifecycle (secondary) ----------------------------------------------------------
LIFECYCLE = {
    "dispatch": ("store_ops.dispatch_order_transfers(%s)", "line(s) sent to the pickup store"),
    "receive": ("store_ops.receive_order_transfers(%s)", "line(s) booked in at the pickup store"),
    "collect": ("store_ops.collect_order(%s)", "line(s) collected"),
}


def order_step(conn, order_no: str, step: str, body: dict) -> dict:
    order = str(_id(order_no, "order"))
    if value(conn, "SELECT 1 FROM store_ops.reservation WHERE web_order_ref = %s LIMIT 1", (order,)) is None:
        raise NotFound(f"Order ID {order} has no store reservations")
    if step == "cancel":
        reason = _text(body, "reason", required=False) or "Customer cancelled"
        n = value(conn, "SELECT store_ops.cancel_order(%s, %s)", (order, reason[:120]))
        text = "line(s) cancelled; stock back on a shelf"
    else:
        fn, text = LIFECYCLE[step]
        n = value(conn, f"SELECT {fn}", (order,))
    conn.commit()
    lines = rows(conn, """
        SELECT reservation_no::text AS reservation_no, web_line_no, item_no, quantity,
               store_no AS taken_from, pickup_store_no, status
          FROM store_ops.reservation WHERE web_order_ref = %s ORDER BY web_line_no""", (order,))
    return {"order_no": order, "lines_changed": n, "lines": lines,
            "message": f"Order ID {order}: {n} {text}." + ("" if n else " Nothing was in that state.")}


def cancel_overdue(conn, body: dict) -> dict:
    n = value(conn, "SELECT store_ops.cancel_overdue_orders(3)")
    conn.commit()
    return {"orders_cancelled": n,
            "message": f"{n} order(s) not collected within 3 days were cancelled; stock went back on the shelf."}


# --- scenario A: sell the remaining free stock of one product -------------------------------
def sellout_preview(conn, product: str) -> dict:
    if not re.fullmatch(ITEM_NO, product or ""):
        raise BadRequest("Choose an item number, e.g. P018")
    item = item_no(conn, product, "store")
    stores = rows(conn, """
        SELECT s.store_no, st.store_name, x.store_code, s.in_store_quantity AS available,
               s.reserved_quantity AS reserved
          FROM store_ops.store_stock s
          JOIN store_ops.store st USING (store_no)
          LEFT JOIN etl.store_xref x ON x.source_system = 'STORE' AND x.source_code = s.store_no
         WHERE s.item_no = %s ORDER BY s.store_no""", (item,))
    web = row(conn, """
        SELECT p.item_no, s.available_quantity AS website_shown
          FROM online.product p JOIN online.online_stock s USING (item_no) WHERE p.item_no = %s""", (item,))
    to_sell = [s for s in stores if s["available"] > 0]
    return {"product_code": product, "item_no": item, "stores": stores,
            "sales_planned": [{"store_no": s["store_no"], "store_code": s["store_code"],
                               "quantity": s["available"]} for s in to_sell],
            "units_to_sell": sum(s["available"] for s in to_sell),
            "website": web,
            "ready": bool(to_sell) and web is not None,
            "problem": (None if to_sell and web else
                        "This item has no free shelf stock in any store. Choose another item or "
                        "record a supplier delivery first." if web else "This item is not sold online.")}


def sellout(conn, body: dict) -> dict:
    product = _text(body, "product", pattern=ITEM_NO)
    expected = body.get("expected")
    if not isinstance(expected, list):
        raise BadRequest("'expected' must list the planned sales shown in the preview")
    item = item_no(conn, product, "store")
    # Lock this item's stock rows, then confirm nothing changed since the preview.
    current = rows(conn, """
        SELECT store_no, in_store_quantity AS quantity FROM store_ops.store_stock
         WHERE item_no = %s AND in_store_quantity > 0 ORDER BY store_no FOR UPDATE""", (item,))
    planned = sorted((str(e.get("store_no")), _qty(e.get("quantity"), "quantity"))
                     for e in expected if isinstance(e, dict))
    if planned != [(c["store_no"], c["quantity"]) for c in current]:
        conn.rollback()
        raise Refused("Store stock changed since the preview. Review the new balances and try again.")
    if not current:
        conn.rollback()
        raise Refused("There is no free shelf stock to sell.")
    receipts = []
    for c in current:
        sale_no = value(conn, "SELECT store_ops.record_sale(%s, %s, %s)", (c["store_no"], [item], [c["quantity"]]))
        receipts.append({"sale_no": str(sale_no), "store_no": c["store_no"], "quantity": c["quantity"]})
    conn.commit()
    return {"product_code": product, "receipts": receipts,
            "website_vs_shelf": website_vs_shelf(conn, [item]),
            "message": f"{len(receipts)} till sale(s) recorded; {product} now has no free shelf stock. "
                       "The website still shows its old number until the next sync."}
