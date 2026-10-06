"""Business-demo operations behind the dashboard's POST endpoints.

Each operation validates its input, calls the EXISTING source-system or ETL
function (never a direct stock update), commits, and then reads back what
that call actually created: the generated identifiers, the staged copies and
the warehouse rows linked to them. Nothing here reimplements a business rule.

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


def _items(body: dict, code_key: str, qty_key: str) -> list[tuple[str, int]]:
    items = body.get("items")
    if not isinstance(items, list) or not items:
        raise BadRequest("Give at least one item")
    if len(items) > 20:
        raise BadRequest("At most 20 items per operation")
    out = []
    for n, it in enumerate(items, 1):
        if not isinstance(it, dict):
            raise BadRequest(f"Item {n} is not valid")
        code = _text(it, code_key)
        out.append((code, _qty(it.get(qty_key), f"item {n} {qty_key}")))
    codes = [c for c, _ in out]
    if len(set(codes)) != len(codes):
        raise BadRequest("Each product can appear only once")
    return out


def _source_code(conn, kind: str, system: str, code: str, exists_sql: str) -> str:
    """Warehouse code (S01 / P001) -> the source system's own code, through the
    approved cross-reference. Any other value must already exist in the source."""
    if re.fullmatch(r"S0[1-9]" if kind == "store" else r"P[0-9]{3}", code):
        table, col = ("etl.store_xref", "store_code") if kind == "store" else ("etl.product_xref", "product_code")
        mapped = value(conn, f"SELECT source_code FROM {table} WHERE source_system = %s AND {col} = %s",
                       (system, code))
        if mapped is None:
            raise NotFound(f"{code} has no approved {system} code; choose the source code instead")
        return mapped
    if value(conn, exists_sql, (code,)) is None:
        raise NotFound(f"Unknown {system} {kind} code {code}")
    return code


def store_no(conn, code: str) -> str:
    return _source_code(conn, "store", "STORE", code, "SELECT 1 FROM store_ops.store WHERE store_no = %s")


def barcode(conn, code: str) -> str:
    return _source_code(conn, "product", "STORE", code, "SELECT 1 FROM store_ops.product WHERE barcode = %s")


def location(conn, code: str) -> str:
    return _source_code(conn, "store", "SUPPLY", code,
                        "SELECT 1 FROM supply.location WHERE location_code = %s")


def supplier_sku(conn, code: str) -> str:
    return _source_code(conn, "product", "SUPPLY", code, "SELECT 1 FROM supply.item WHERE supplier_sku = %s")


def web_sku(conn, code: str) -> str:
    return _source_code(conn, "product", "ONLINE", code, "SELECT 1 FROM online.product WHERE web_sku = %s")


def cp_code(conn, code: str) -> str:
    return _source_code(conn, "store", "ONLINE", code,
                        "SELECT 1 FROM online.collection_point WHERE cp_code = %s")


# --- read-back helpers -------------------------------------------------------------
def staged(conn, table: str, ref_pattern: str) -> list[dict]:
    """Staging rows (and their fact rows) created by one operation."""
    assert table in {"stg_store_sale_line", "stg_delivery_line", "stg_reservation_change", "stg_checkout_item"}
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


def website_vs_shelf(conn, barcodes: list[str]) -> list[dict]:
    return rows(conn, """
        SELECT sp.barcode, x.product_code, sp.description,
               (SELECT sum(in_store_quantity) FROM store_ops.store_stock ss WHERE ss.barcode = sp.barcode)
                   AS shelf_total_all_stores,
               os.available_quantity AS website_shown, op.web_sku
          FROM store_ops.product sp
          LEFT JOIN etl.product_xref x ON x.source_system = 'STORE' AND x.source_code = sp.barcode
          LEFT JOIN online.product op ON op.pos_barcode = sp.barcode
          LEFT JOIN online.online_stock os ON os.web_sku = op.web_sku
         WHERE sp.barcode = ANY(%s)
         ORDER BY sp.barcode""", (barcodes,))


def basket_view(conn, basket_id: int) -> dict:
    b = row(conn, """
        SELECT b.basket_id::text AS basket_id, b.customer_postcode, pl.suburb, b.status, b.created_at,
               b.checked_out_at
          FROM online.basket b JOIN online.postcode_location pl ON pl.postcode = b.customer_postcode
         WHERE b.basket_id = %s""", (basket_id,))
    if b is None:
        raise NotFound(f"Bag {basket_id} does not exist")
    b["items"] = rows(conn, """
        SELECT i.web_sku, p.title, x.product_code, i.quantity, i.website_qty_at_add,
               s.available_quantity AS website_shown_now, i.added_at
          FROM online.basket_item i
          JOIN online.product p ON p.web_sku = i.web_sku
          JOIN online.online_stock s ON s.web_sku = i.web_sku
          LEFT JOIN etl.product_xref x ON x.source_system = 'ONLINE' AND x.source_code = i.web_sku
         WHERE i.basket_id = %s ORDER BY i.web_sku""", (basket_id,))
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
    items = [(barcode(conn, code), qty) for code, qty in _items(body, "product", "quantity")]
    sale_no = value(conn, "SELECT store_ops.record_sale(%s, %s, %s)",
                    (store, [b for b, _ in items], [q for _, q in items]))
    conn.commit()
    return {"sale_no": str(sale_no), "store_no": store,
            "lines": [{"barcode": b, "quantity": q} for b, q in items],
            "staging": staged(conn, "stg_store_sale_line", f"STORE:sale {sale_no} line %"),
            "website_vs_shelf": website_vs_shelf(conn, [b for b, _ in items]),
            "message": f"Receipt {sale_no} recorded at store {store}. The website number is unchanged until the next sync."}


def record_delivery(conn, body: dict) -> dict:
    loc = location(conn, _text(body, "location"))
    supplier = _text(body, "supplier_name")
    if len(supplier) > 80:
        raise BadRequest("'supplier_name' is too long")
    items = [(supplier_sku(conn, code), qty) for code, qty in _items(body, "sku", "cartons")]
    delivery_no = value(conn, "SELECT supply.record_delivery(%s, %s, %s, %s)",
                        (loc, supplier, [s for s, _ in items], [c for _, c in items]))
    conn.commit()
    lines = rows(conn, """
        SELECT l.line_no, l.supplier_sku, l.cartons, i.units_per_carton, l.cartons * i.units_per_carton AS units,
               right(i.gtin14, 13) AS barcode,
               to_char(d.delivered_at_utc, 'YYYY-MM-DD HH24:MI:SS') AS delivered_at_utc,
               d.delivered_at_utc AT TIME ZONE 'UTC' AS delivered_at_sydney
          FROM supply.delivery_line l
          JOIN supply.delivery d USING (delivery_no)
          JOIN supply.item i ON i.supplier_sku = l.supplier_sku
         WHERE l.delivery_no = %s ORDER BY l.line_no""", (delivery_no,))
    return {"delivery_no": str(delivery_no), "location_code": loc, "lines": lines,
            "staging": staged(conn, "stg_delivery_line", f"SUPPLY:delivery {delivery_no} line %"),
            "website_vs_shelf": website_vs_shelf(conn, [l["barcode"] for l in lines]),
            "message": f"Delivery {delivery_no} recorded at {loc}. The website number is unchanged until the next sync."}


def create_basket(conn, body: dict) -> dict:
    postcode = _text(body, "postcode", pattern=r"[0-9]{4}")
    basket_id = value(conn, "SELECT online.create_basket(%s)", (postcode,))
    conn.commit()
    return {"basket": basket_view(conn, basket_id), "message": f"Bag {basket_id} created."}


def set_basket_item(conn, basket_id: str, body: dict) -> dict:
    bid = _id(basket_id, "basket")
    basket_view(conn, bid)
    sku = web_sku(conn, _text(body, "product"))
    qty = _qty(body.get("quantity"), "quantity")
    value(conn, "SELECT online.add_to_basket(%s, %s, %s), 1", (bid, sku, qty))
    conn.commit()
    return {"basket": basket_view(conn, bid),
            "message": f"{sku}: quantity in bag set to {qty}. Nothing is held until checkout."}


def remove_basket_item(conn, basket_id: str, body: dict) -> dict:
    bid = _id(basket_id, "basket")
    basket_view(conn, bid)
    sku = web_sku(conn, _text(body, "product"))
    value(conn, "SELECT online.remove_from_basket(%s, %s), 1", (bid, sku))
    conn.commit()
    return {"basket": basket_view(conn, bid), "message": f"{sku} removed from bag {bid}."}


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
        SELECT i.web_sku, x.product_code, i.quantity, i.website_qty_shown, i.result, i.source_cp_code
          FROM online.checkout_attempt_item i
          LEFT JOIN etl.product_xref x ON x.source_system = 'ONLINE' AND x.source_code = i.web_sku
         WHERE i.attempt_no = %s ORDER BY i.web_sku""", (attempt_no,))
    reservations = rows(conn, """
        SELECT reservation_no::text AS reservation_no, web_line_no, barcode, quantity,
               store_no AS taken_from, pickup_store_no, status
          FROM store_ops.reservation WHERE web_order_ref = %s ORDER BY web_line_no""",
                        (str(order_no),)) if order_no else []
    outcome = "paid" if order_no else "blocked"
    unavailable = [i for i in items if i["result"] == "unavailable"]
    return {"outcome": outcome, "attempt_no": str(attempt_no),
            "order_no": str(order_no) if order_no else None,
            "items": items, "unavailable_items": unavailable, "reservations": reservations,
            "staging": staged(conn, "stg_checkout_item", f"ONLINE:checkout {attempt_no} %"),
            "basket": basket_view(conn, bid),
            "message": (f"Paid: order {order_no} created; every item is held at its supplying store."
                        if order_no else
                        f"Checkout blocked before payment: {len(unavailable)} item(s) unavailable in any single "
                        f"store. Nothing was charged or held; bag {bid} is still open.")}


def sync(conn, body: dict) -> dict:
    sync_no = value(conn, "SELECT online.sync_website_stock()")
    conn.commit()
    run = row(conn, """
        SELECT sync_id, source_sync_no::text AS source_sync_no, run_at, events_processed,
               numbers_changed, store_mismatches
          FROM dw.sync_run WHERE source_sync_no = %s""", (sync_no,))
    changes = rows(conn, """
        SELECT l.web_sku, x.product_code, l.before_qty, l.after_qty, l.after_qty - l.before_qty AS change
          FROM online.stock_sync_line l
          LEFT JOIN etl.product_xref x ON x.source_system = 'ONLINE' AND x.source_code = l.web_sku
         WHERE l.sync_no = %s AND l.before_qty <> l.after_qty ORDER BY l.web_sku""", (sync_no,))
    return {"source_sync_no": str(sync_no), "warehouse_sync": run, "website_changes": changes,
            "message": f"Website sync {sync_no} copied the store system's shelf totals to the website; "
                       f"{len(changes)} website quantit{'y' if len(changes) == 1 else 'ies'} changed."}


SOURCE_EXISTS = {
    "STORE": "SELECT 1 FROM store_ops.product WHERE barcode = %s",
    "SUPPLY": "SELECT 1 FROM supply.item WHERE supplier_sku = %s",
    "ONLINE": "SELECT 1 FROM online.product WHERE web_sku = %s",
}


def approve_mapping(conn, body: dict) -> dict:
    system = _text(body, "source_system")
    if system not in SOURCE_EXISTS:
        raise BadRequest("'source_system' must be STORE, SUPPLY or ONLINE")
    code = _text(body, "source_code")
    product = _text(body, "product_code", pattern=r"P[0-9]{3}")
    if value(conn, SOURCE_EXISTS[system], (code,)) is None:
        raise NotFound(f"{code} is not in the {system} catalogue")
    existing = value(conn, "SELECT product_code FROM etl.product_xref WHERE source_system = %s AND source_code = %s",
                     (system, code))
    if existing is not None:
        raise Refused(f"{system} code {code} is already mapped to {existing}. "
                      "This demo only approves codes that have no mapping.")
    taken = value(conn, "SELECT source_code FROM etl.product_xref WHERE source_system = %s AND product_code = %s",
                  (system, product))
    if taken is not None:
        raise Refused(f"{product} already has the {system} code {taken}; one code per system is allowed.")
    value(conn, "SELECT etl.approve_product_mapping(%s, %s, %s), 1", (system, code, product))
    conn.commit()
    waiting = value(conn, """
        SELECT count(*) FROM etl.v_transform
         WHERE source_system = %s AND product_source_code = %s AND event_type IS NOT NULL""", (system, code))
    return {"mapping": {"source_system": system, "source_code": code, "product_code": product},
            "records_waiting": waiting,
            "message": f"Mapping approved: {system} {code} -> {product}. Records already staged are not loaded "
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
        raise NotFound(f"Order {order} has no store reservations")
    if step == "cancel":
        reason = _text(body, "reason", required=False) or "Customer cancelled"
        n = value(conn, "SELECT store_ops.cancel_order(%s, %s)", (order, reason[:120]))
        text = "line(s) cancelled; stock back on a shelf"
    else:
        fn, text = LIFECYCLE[step]
        n = value(conn, f"SELECT {fn}", (order,))
    conn.commit()
    lines = rows(conn, """
        SELECT reservation_no::text AS reservation_no, web_line_no, barcode, quantity,
               store_no AS taken_from, pickup_store_no, status
          FROM store_ops.reservation WHERE web_order_ref = %s ORDER BY web_line_no""", (order,))
    return {"order_no": order, "lines_changed": n, "lines": lines,
            "message": f"Order {order}: {n} {text}." + ("" if n else " Nothing was in that state.")}


def cancel_overdue(conn, body: dict) -> dict:
    n = value(conn, "SELECT store_ops.cancel_overdue_orders(3)")
    conn.commit()
    return {"orders_cancelled": n,
            "message": f"{n} order(s) not collected within 3 days were cancelled; stock went back on the shelf."}


# --- scenario A: sell the remaining free stock of one product -------------------------------
def sellout_preview(conn, product: str) -> dict:
    if not re.fullmatch(r"P[0-9]{3}", product or ""):
        raise BadRequest("Choose a warehouse product code, e.g. P018")
    bc = barcode(conn, product)
    stores = rows(conn, """
        SELECT s.store_no, st.store_name, x.store_code, s.in_store_quantity AS available,
               s.reserved_quantity AS reserved
          FROM store_ops.store_stock s
          JOIN store_ops.store st USING (store_no)
          LEFT JOIN etl.store_xref x ON x.source_system = 'STORE' AND x.source_code = s.store_no
         WHERE s.barcode = %s ORDER BY s.store_no""", (bc,))
    web = row(conn, """
        SELECT p.web_sku, s.available_quantity AS website_shown
          FROM online.product p JOIN online.online_stock s USING (web_sku) WHERE p.pos_barcode = %s""", (bc,))
    to_sell = [s for s in stores if s["available"] > 0]
    return {"product_code": product, "barcode": bc, "stores": stores,
            "sales_planned": [{"store_no": s["store_no"], "store_code": s["store_code"],
                               "quantity": s["available"]} for s in to_sell],
            "units_to_sell": sum(s["available"] for s in to_sell),
            "website": web,
            "ready": bool(to_sell) and web is not None,
            "problem": (None if to_sell and web else
                        "This product has no free shelf stock in any store. Choose another product or "
                        "record a delivery first." if web else "This product is not sold online.")}


def sellout(conn, body: dict) -> dict:
    product = _text(body, "product", pattern=r"P[0-9]{3}")
    expected = body.get("expected")
    if not isinstance(expected, list):
        raise BadRequest("'expected' must list the planned sales shown in the preview")
    bc = barcode(conn, product)
    # Lock this product's stock rows, then confirm nothing changed since the preview.
    current = rows(conn, """
        SELECT store_no, in_store_quantity AS quantity FROM store_ops.store_stock
         WHERE barcode = %s AND in_store_quantity > 0 ORDER BY store_no FOR UPDATE""", (bc,))
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
        sale_no = value(conn, "SELECT store_ops.record_sale(%s, %s, %s)", (c["store_no"], [bc], [c["quantity"]]))
        receipts.append({"sale_no": str(sale_no), "store_no": c["store_no"], "quantity": c["quantity"]})
    conn.commit()
    return {"product_code": product, "receipts": receipts,
            "website_vs_shelf": website_vs_shelf(conn, [bc]),
            "message": f"{len(receipts)} till sale(s) recorded; {product} now has no free shelf stock. "
                       "The website still shows its old number until the next sync."}
