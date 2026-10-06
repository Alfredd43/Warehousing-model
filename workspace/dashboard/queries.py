"""Read-only queries behind the dashboard's GET endpoints.

Every function takes an open connection and the request's query parameters
and returns a ``Result``. The report views in db/08_reports.sql are used as
they are; the supplemental queries here only join existing tables (stable
identifiers, event history and lineage) and never recompute a report rule.

Query parameters are always bound (%s). Table names for the trace are taken
from a fixed whitelist, never from the client.
"""

from __future__ import annotations

from dataclasses import dataclass, field


class BadRequest(ValueError):
    """Invalid query parameter (HTTP 400)."""


class NotFound(LookupError):
    """Referenced record does not exist (HTTP 404)."""


@dataclass
class Result:
    data: object
    scope: str | None = None
    provenance: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


DEFAULT_LIMIT = 50
MAX_LIMIT = 200

STORE_CODE = r"^S0[1-9]$"
PRODUCT_CODE = r"^P[0-9]{3}$"


# --- helpers ------------------------------------------------------------------
def rows(conn, sql: str, params=None) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(sql, params)
        names = [d.name for d in cur.description]
        return [dict(zip(names, r)) for r in cur.fetchall()]


def row(conn, sql: str, params=None) -> dict | None:
    found = rows(conn, sql, params)
    return found[0] if found else None


def value(conn, sql: str, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        r = cur.fetchone()
        return r[0] if r else None


def _one(params: dict, name: str) -> str | None:
    v = params.get(name)
    if isinstance(v, list):
        v = v[0] if v else None
    v = (v or "").strip()
    return v or None


def text_param(params: dict, name: str, pattern: str | None = None) -> str | None:
    import re
    v = _one(params, name)
    if v is not None and pattern and not re.fullmatch(pattern, v):
        raise BadRequest(f"Invalid value for '{name}'")
    return v


def int_param(params: dict, name: str, default: int | None = None,
              minimum: int = 0, maximum: int | None = None) -> int | None:
    v = _one(params, name)
    if v is None:
        return default
    if not v.isdigit():
        raise BadRequest(f"'{name}' must be a whole number")
    n = int(v)
    if n < minimum or (maximum is not None and n > maximum):
        raise BadRequest(f"'{name}' is out of range")
    return n


def date_param(params: dict, name: str) -> str | None:
    return text_param(params, name, r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")


def choice_param(params: dict, name: str, allowed: set[str]) -> str | None:
    v = _one(params, name)
    if v is not None and v not in allowed:
        raise BadRequest(f"Invalid value for '{name}'")
    return v


def page_params(params: dict) -> tuple[int, int]:
    limit = int_param(params, "limit", DEFAULT_LIMIT, 1, MAX_LIMIT)
    offset = int_param(params, "offset", 0, 0)
    return limit, offset


def paged(items: list[dict], total: int, limit: int, offset: int) -> dict:
    return {"rows": items, "total": total, "limit": limit, "offset": offset}


# --- shared status --------------------------------------------------------------
def quality_summary(conn) -> dict:
    """Counts behind the shared 'data may be incomplete' warning."""
    r = row(conn, """
        SELECT (SELECT count(*) FROM etl.v_data_quality)                         AS rejected_rows,
               (SELECT count(*) FROM dw.rpt_reconciliation)                      AS compared_pairs,
               (SELECT count(*) FROM dw.rpt_reconciliation WHERE status = 'match') AS matching_pairs""")
    r["mismatched_pairs"] = r["compared_pairs"] - r["matching_pairs"]
    r["incomplete"] = bool(r["rejected_rows"] or r["mismatched_pairs"])
    return r


def status(conn, params) -> Result:
    last = row(conn, """
        SELECT sync_id, source_sync_no::text AS source_sync_no, run_at
          FROM dw.sync_run ORDER BY sync_id DESC LIMIT 1""")
    return Result({"last_sync": last, "quality": quality_summary(conn)},
                  provenance=["dw.sync_run", "etl.v_data_quality", "dw.rpt_reconciliation"])


def health(conn, params) -> Result:
    r = row(conn, "SELECT current_database() AS database, now() AS server_time, version() AS version")
    r["database_available"] = True
    return Result(r)


# --- catalogue ---------------------------------------------------------------------
def catalogue(conn, params) -> Result:
    data = {
        "products": rows(conn, """
            SELECT d.product_code, d.product_name, d.category, c.store_barcode, c.supplier_sku, c.web_sku
              FROM dw.dim_product d JOIN etl.v_product_codes c USING (product_code)
             ORDER BY d.product_code"""),
        "stores": rows(conn, """
            SELECT d.store_code, d.store_name, d.suburb, c.store_no, c.location_code, c.cp_code
              FROM dw.dim_store d JOIN etl.v_store_codes c USING (store_code)
             WHERE d.channel = 'physical' ORDER BY d.store_code"""),
        "categories": [r["category"] for r in rows(conn,
                       "SELECT DISTINCT category FROM dw.dim_product ORDER BY category")],
        # Source catalogues, with the warehouse code when a mapping is approved.
        "store_products": rows(conn, """
            SELECT p.barcode, p.description, p.category, x.product_code
              FROM store_ops.product p
              LEFT JOIN etl.product_xref x ON x.source_system = 'STORE' AND x.source_code = p.barcode
             ORDER BY coalesce(x.product_code, 'Z'), p.barcode"""),
        "supplier_items": rows(conn, """
            SELECT i.supplier_sku, i.item_description, i.units_per_carton, x.product_code
              FROM supply.item i
              LEFT JOIN etl.product_xref x ON x.source_system = 'SUPPLY' AND x.source_code = i.supplier_sku
             ORDER BY coalesce(x.product_code, 'Z'), i.supplier_sku"""),
        "web_products": rows(conn, """
            SELECT p.web_sku, p.title, s.available_quantity AS website_shown, x.product_code
              FROM online.product p
              JOIN online.online_stock s USING (web_sku)
              LEFT JOIN etl.product_xref x ON x.source_system = 'ONLINE' AND x.source_code = p.web_sku
             ORDER BY p.web_sku"""),
        "store_numbers": rows(conn, """
            SELECT s.store_no, s.store_name, x.store_code
              FROM store_ops.store s
              LEFT JOIN etl.store_xref x ON x.source_system = 'STORE' AND x.source_code = s.store_no
             ORDER BY s.store_no"""),
        "locations": rows(conn, """
            SELECT l.location_code, l.location_name, x.store_code
              FROM supply.location l
              LEFT JOIN etl.store_xref x ON x.source_system = 'SUPPLY' AND x.source_code = l.location_code
             ORDER BY l.location_code"""),
        "collection_points": rows(conn, """
            SELECT c.cp_code, c.cp_name, x.store_code
              FROM online.collection_point c
              LEFT JOIN etl.store_xref x ON x.source_system = 'ONLINE' AND x.source_code = c.cp_code
             ORDER BY x.store_code, c.cp_code"""),
        "postcodes": rows(conn, "SELECT postcode, suburb FROM online.postcode_location ORDER BY postcode"),
        "suppliers": [r["supplier_name"] for r in rows(conn,
                      "SELECT DISTINCT supplier_name FROM supply.supplier_delivery ORDER BY supplier_name")],
    }
    return Result(data, provenance=["dw.dim_product", "dw.dim_store", "etl.v_product_codes",
                                    "etl.v_store_codes", "store_ops", "supply", "online"])


# --- Page A: Website & Sync (Report 2) ------------------------------------------------
def website_stock(conn, params) -> Result:
    comparison = rows(conn, """
        SELECT v.product_code, v.product_name, d.category,
               v.online_shown, v.actual_in_store, v.overstated_by AS difference,
               CASE WHEN v.overstated_by > 0 THEN 'higher'
                    WHEN v.overstated_by < 0 THEN 'lower' ELSE 'equal' END AS comparison,
               v.synced_at
          FROM dw.rpt_online_vs_actual v
          JOIN dw.dim_product d USING (product_code)
         ORDER BY abs(v.overstated_by) DESC, v.product_code""")
    staleness = row(conn, "SELECT * FROM dw.rpt_online_staleness")
    unmapped_online = value(conn, """
        SELECT count(*) FROM online.product p
         WHERE NOT EXISTS (SELECT 1 FROM etl.product_xref x
                            WHERE x.source_system = 'ONLINE' AND x.source_code = p.web_sku)""")
    warnings = []
    if unmapped_online:
        warnings.append(f"{unmapped_online} online product(s) have no approved mapping and are not compared.")
    return Result(
        {"comparison": comparison, "staleness": staleness, "quality": quality_summary(conn),
         "unmapped_online_products": unmapped_online},
        scope="All five stores combined; mapped online products",
        provenance=["dw.rpt_online_vs_actual (online.online_stock + dw.fact_stock_event)",
                    "dw.rpt_online_staleness"],
        warnings=warnings)


def sync_latest(conn, params) -> Result:
    sync_id = int_param(params, "sync_id", None, 1)
    runs = rows(conn, """
        SELECT sync_id, source_sync_no::text AS source_sync_no, run_at, events_processed,
               numbers_changed, store_mismatches
          FROM dw.sync_run ORDER BY sync_id DESC""")
    if not runs:
        return Result({"run": None, "runs": [], "website_changes": [], "store_changes": []},
                      provenance=["dw.sync_run"])
    if sync_id is None:
        run = runs[0]
    else:
        run = next((r for r in runs if r["sync_id"] == sync_id), None)
        if run is None:
            raise NotFound(f"Sync {sync_id} is not recorded")
    changes = rows(conn, """
        SELECT s.store_code, s.store_name, p.product_code, p.product_name, c.measure,
               c.before_qty, c.after_qty, c.after_qty - c.before_qty AS change
          FROM dw.sync_change c
          JOIN dw.dim_store s   ON s.store_key = c.store_key
          JOIN dw.dim_product p ON p.product_key = c.product_key
         WHERE c.sync_id = %s AND c.changed
         ORDER BY c.measure <> 'online_available', abs(c.after_qty - c.before_qty) DESC,
                  p.product_code, s.store_code, c.measure""", (run["sync_id"],))
    website = [c for c in changes if c["measure"] == "online_available"]
    store = [c for c in changes if c["measure"] != "online_available"]
    return Result({"run": run, "runs": runs, "website_changes": website, "store_changes": store,
                   "is_latest": run["sync_id"] == runs[0]["sync_id"]},
                  provenance=["dw.sync_run", "dw.sync_change" if sync_id else "dw.rpt_last_sync_changes"])


# --- Page B: Store Inventory (Report 1) --------------------------------------------------
def stock(conn, params) -> Result:
    data = rows(conn, """
        SELECT store_code, store_name, product_code, product_name, category,
               in_store_quantity AS available, reserved_quantity AS reserved,
               total_on_hand AS on_hand, low_stock, last_event_at
          FROM dw.rpt_current_stock_by_store
         ORDER BY store_code, product_code""")
    return Result({"rows": data}, scope="Current balance per physical store and product",
                  provenance=["dw.rpt_current_stock_by_store"])


EVENT_LABELS = {
    "store_sale": "In-store sale", "supplier_delivery": "Supplier delivery", "reservation": "Held for online order",
    "transfer_out": "Sent to pickup store", "transfer_in": "Arrived at pickup store",
    "collection": "Collected by customer", "cancellation": "Order cancelled",
    "checkout_blocked": "Checkout blocked",
}


def stock_events(conn, params) -> Result:
    store = text_param(params, "store", STORE_CODE)
    product = text_param(params, "product", PRODUCT_CODE)
    date_from, date_to = date_param(params, "from"), date_param(params, "to")
    event_type = choice_param(params, "type", set(EVENT_LABELS))
    limit, offset = page_params(params)
    where = """
         WHERE (%(store)s::text IS NULL OR s.store_code = %(store)s)
           AND (%(product)s::text IS NULL OR p.product_code = %(product)s)
           AND (%(from)s::date IS NULL OR d.full_date >= %(from)s::date)
           AND (%(to)s::date IS NULL OR d.full_date <= %(to)s::date)
           AND (%(type)s::text IS NULL OR f.event_type = %(type)s)"""
    args = {"store": store, "product": product, "from": date_from, "to": date_to,
            "type": event_type, "limit": limit, "offset": offset}
    joins = """
          FROM dw.fact_stock_event f
          JOIN dw.dim_store s   ON s.store_key = f.store_key
          JOIN dw.dim_product p ON p.product_key = f.product_key
          JOIN dw.dim_date d    ON d.date_key = f.date_key
          LEFT JOIN dw.dim_store pk ON pk.store_key = f.pickup_store_key"""
    total = value(conn, "SELECT count(*)" + joins + where, args)
    data = rows(conn, """
        SELECT f.event_id::text AS event_id, f.event_ts, d.full_date AS business_date, f.event_type,
               s.store_code, s.store_name, p.product_code, p.product_name,
               f.quantity_change AS available_change, f.reserved_change, f.units,
               f.order_ref, pk.store_code AS pickup_store_code, pk.store_name AS pickup_store_name,
               f.source_system, f.source_ref, f.etl_run_id, f.loaded_at""" + joins + where + """
         ORDER BY f.event_ts DESC, f.event_id DESC
         LIMIT %(limit)s OFFSET %(offset)s""", args)
    for r in data:
        r["event_label"] = EVENT_LABELS.get(r["event_type"], r["event_type"])
    return Result(paged(data, total, limit, offset),
                  scope="Warehouse stock events" + (" (date filter applies to event history only)"
                                                    if date_from or date_to else ""),
                  provenance=["dw.fact_stock_event", "dw.dim_store", "dw.dim_product", "dw.dim_date"])


def sales(conn, params) -> Result:
    data = rows(conn, """
        SELECT full_date, day_name, is_weekend, store_name, channel, category,
               units_sold, sales_value_at_current_price
          FROM dw.rpt_daily_sales ORDER BY full_date, store_name, channel, category""")
    return Result({"rows": data}, scope="Units sold per day, store, channel and category",
                  provenance=["dw.rpt_daily_sales"])


# --- Page C: Checkout & Fulfilment (Report 3) ----------------------------------------------
REASON_LABELS = {
    "stale": "Combined stock insufficient",
    "split": "No single store could supply the quantity",
}


def checkout_blocked(conn, params) -> Result:
    # The view has no unique key; join it back to its fact row (one blocked
    # event per attempt and product) and to the staging row for the attempt.
    data = rows(conn, """
        SELECT f.event_id::text AS event_id, f.source_ref, sc.attempt_no::text AS attempt_no,
               sc.stg_id::text AS stg_id, b.basket, sc.basket_id::text AS basket_id,
               b.attempted_at, b.product_code, b.product_name, b.quantity_in_bag AS requested,
               b.website_showed AS website_shown_then,
               b.actual_combined_at_checkout AS combined_available_then,
               ps.store_code AS pickup_store_code, b.pickup_store, b.reason AS report_reason,
               CASE WHEN starts_with(b.reason, 'stock sold since last sync') THEN 'stale' ELSE 'split' END AS reason_code
          FROM dw.rpt_checkout_blocked b
          JOIN dw.dim_product p ON p.product_code = b.product_code
          JOIN dw.fact_stock_event f
            ON f.event_type = 'checkout_blocked' AND f.order_ref = b.basket
           AND f.event_ts = b.attempted_at AND f.product_key = p.product_key
          JOIN dw.dim_store ps ON ps.store_key = f.store_key
          LEFT JOIN etl.stg_checkout_item sc ON sc.event_id = f.event_id
         ORDER BY b.attempted_at DESC, f.event_id DESC""")
    for r in data:
        r["reason"] = REASON_LABELS[r["reason_code"]]
    return Result({"rows": data}, scope="All recorded blocked items (prototype history)",
                  provenance=["dw.rpt_checkout_blocked", "dw.fact_stock_event", "etl.stg_checkout_item"])


def checkout_attempt(conn, params, attempt_no: str) -> Result:
    if not attempt_no.isdigit():
        raise BadRequest("Attempt number must be a whole number")
    attempt = row(conn, """
        SELECT a.attempt_no::text AS attempt_no, a.basket_id::text AS basket_id, a.pickup_cp_code,
               cp.cp_name AS pickup_cp_name, x.store_code AS pickup_store_code,
               a.attempted_at, a.outcome, a.order_no::text AS order_no, b.status AS basket_status
          FROM online.checkout_attempt a
          JOIN online.basket b ON b.basket_id = a.basket_id
          JOIN online.collection_point cp ON cp.cp_code = a.pickup_cp_code
          LEFT JOIN etl.store_xref x ON x.source_system = 'ONLINE' AND x.source_code = a.pickup_cp_code
         WHERE a.attempt_no = %s""", (int(attempt_no),))
    if attempt is None:
        raise NotFound(f"Checkout attempt {attempt_no} does not exist")
    items = rows(conn, """
        SELECT i.web_sku, p.title, x.product_code, i.quantity, i.website_qty_shown, i.result,
               i.source_cp_code, cp.cp_name AS source_cp_name,
               s.stg_id::text AS stg_id, s.load_status, s.note, s.event_id::text AS event_id
          FROM online.checkout_attempt_item i
          JOIN online.product p ON p.web_sku = i.web_sku
          LEFT JOIN etl.product_xref x ON x.source_system = 'ONLINE' AND x.source_code = i.web_sku
          LEFT JOIN online.collection_point cp ON cp.cp_code = i.source_cp_code
          LEFT JOIN etl.stg_checkout_item s ON s.attempt_no = i.attempt_no AND s.web_sku = i.web_sku
         WHERE i.attempt_no = %s
         ORDER BY i.web_sku""", (int(attempt_no),))
    # Values the report reconstructs for this attempt's blocked items.
    reconstructed = {r["event_id"]: r for r in checkout_blocked(conn, {}).data["rows"]
                     if r["attempt_no"] == attempt_no}
    for it in items:
        rec = reconstructed.get(it["event_id"])
        it["report_website_shown"] = rec["website_shown_then"] if rec else None
        it["report_combined_available"] = rec["combined_available_then"] if rec else None
        it["website_values_differ"] = (rec is not None and rec["website_shown_then"] is not None
                                       and rec["website_shown_then"] != it["website_qty_shown"])
    other_attempts = rows(conn, """
        SELECT attempt_no::text AS attempt_no, attempted_at, outcome, order_no::text AS order_no
          FROM online.checkout_attempt WHERE basket_id = %s ORDER BY attempt_no""",
                          (int(attempt["basket_id"]),))
    return Result({"attempt": attempt, "items": items, "basket_attempts": other_attempts},
                  scope="Source checkout record (online store)",
                  provenance=["online.checkout_attempt", "online.checkout_attempt_item",
                              "etl.stg_checkout_item", "dw.rpt_checkout_blocked"])


def reservations(conn, params) -> Result:
    data = rows(conn, """
        SELECT r.order_no, r.pickup_store, pk.store_code AS pickup_store_code,
               r.product_code, r.product_name, r.units, r.taken_from, src.store_code AS source_store_code,
               r.is_transfer, r.line_status, r.order_ready, r.reserved_at, r.waiting_for, r.overdue
          FROM dw.rpt_open_reservations r
          JOIN dw.dim_store pk  ON pk.store_name = r.pickup_store
          JOIN dw.dim_store src ON src.store_name = r.taken_from
         ORDER BY r.reserved_at, r.order_no::bigint, r.product_code""")
    return Result({"rows": data}, scope="Click-and-collect order lines not yet collected or cancelled",
                  provenance=["dw.rpt_open_reservations"])


# --- Page D: Integration & Quality ---------------------------------------------------------
def mappings(conn, params) -> Result:
    products = rows(conn, """
        SELECT c.product_code, c.product_name, c.store_barcode, c.supplier_sku, c.web_sku,
               -- 'Not sold online' only when the web catalogue has no item for this barcode.
               EXISTS (SELECT 1 FROM online.product o WHERE o.pos_barcode = c.store_barcode) AS in_web_catalogue
          FROM etl.v_product_codes c ORDER BY c.product_code""")
    stores = rows(conn, "SELECT * FROM etl.v_store_codes ORDER BY store_code")
    unmapped = rows(conn, """
        SELECT 'STORE' AS source_system, p.barcode AS source_code, p.description AS source_name
          FROM store_ops.product p
         WHERE NOT EXISTS (SELECT 1 FROM etl.product_xref x WHERE x.source_system = 'STORE' AND x.source_code = p.barcode)
        UNION ALL
        SELECT 'SUPPLY', i.supplier_sku, i.item_description
          FROM supply.item i
         WHERE NOT EXISTS (SELECT 1 FROM etl.product_xref x WHERE x.source_system = 'SUPPLY' AND x.source_code = i.supplier_sku)
        UNION ALL
        SELECT 'ONLINE', o.web_sku, o.title
          FROM online.product o
         WHERE NOT EXISTS (SELECT 1 FROM etl.product_xref x WHERE x.source_system = 'ONLINE' AND x.source_code = o.web_sku)
         ORDER BY 1, 2""")
    return Result({"products": products, "stores": stores, "unmapped_source_products": unmapped},
                  provenance=["etl.v_product_codes", "etl.v_store_codes", "etl.product_xref",
                              "store_ops.product", "supply.item", "online.product"])


STAGING_TABLES = {"stg_store_sale_line", "stg_supplier_delivery_line", "stg_reservation_change", "stg_checkout_item"}


def staging(conn, params) -> Result:
    source = choice_param(params, "source", {"STORE", "SUPPLY", "ONLINE"})
    load_status = choice_param(params, "status", {"pending", "loaded", "rejected", "skipped"})
    table = choice_param(params, "table", STAGING_TABLES)
    limit, offset = page_params(params)
    args = {"source": source, "status": load_status, "table": table, "limit": limit, "offset": offset}
    where = """
         WHERE (%(source)s::text IS NULL OR source_system = %(source)s)
           AND (%(status)s::text IS NULL OR load_status = %(status)s)
           AND (%(table)s::text IS NULL OR stg_table = %(table)s)"""
    total = value(conn, "SELECT count(*) FROM etl.v_staging" + where, args)
    data = rows(conn, """
        SELECT stg_table, stg_id::text AS stg_id, source_system, source_ref, load_status, note,
               etl_run_id, event_id::text AS event_id, captured_at, processed_at
          FROM etl.v_staging""" + where + """
         ORDER BY captured_at DESC, stg_table, stg_id DESC
         LIMIT %(limit)s OFFSET %(offset)s""", args)
    counts = rows(conn, """
        SELECT load_status, count(*) AS n FROM etl.v_staging GROUP BY load_status ORDER BY load_status""")
    return Result({**paged(data, total, limit, offset), "status_counts": counts},
                  scope="Business-event staging (sales, supplier deliveries, reservations, checkout items); "
                        "website sync records are listed separately",
                  provenance=["etl.v_staging"])


def sync_staging(conn, params) -> Result:
    limit, offset = page_params(params)
    load_status = choice_param(params, "status", {"pending", "loaded", "skipped"})
    args = {"status": load_status, "limit": limit, "offset": offset}
    where = " WHERE (%(status)s::text IS NULL OR s.load_status = %(status)s)"
    total = value(conn, "SELECT count(*) FROM etl.stg_website_sync_line s" + where, args)
    data = rows(conn, """
        SELECT s.stg_id::text AS stg_id, s.sync_no::text AS source_sync_no, r.sync_id AS warehouse_sync_id,
               s.web_sku, s.before_qty, s.after_qty, s.source_ref, s.load_status, s.note,
               s.captured_at, s.processed_at
          FROM etl.stg_website_sync_line s
          LEFT JOIN dw.sync_run r ON r.source_sync_no = s.sync_no""" + where + """
         ORDER BY s.sync_no DESC, s.web_sku
         LIMIT %(limit)s OFFSET %(offset)s""", args)
    return Result(paged(data, total, limit, offset),
                  scope="Website sync log lines (not part of etl.v_staging or etl.v_data_quality)",
                  provenance=["etl.stg_website_sync_line", "dw.sync_run"])


def runs(conn, params) -> Result:
    limit, offset = page_params(params)
    total = value(conn, "SELECT count(*) FROM etl.etl_run")
    data = rows(conn, """
        SELECT etl_run_id, trigger_source, started_at, finished_at,
               rows_read, rows_loaded, rows_rejected, rows_skipped
          FROM etl.etl_run ORDER BY etl_run_id DESC LIMIT %s OFFSET %s""", (limit, offset))
    return Result(paged(data, total, limit, offset),
                  scope="Recorded ETL passes. A rejected row is retried on every pass, so rejected "
                        "counts repeat across runs and must not be added up",
                  provenance=["etl.etl_run"])


def quality(conn, params) -> Result:
    rejected = rows(conn, """
        SELECT q.source_system, q.source_ref, q.reject_reason, q.captured_at, q.last_attempt_at,
               s.stg_table, s.stg_id::text AS stg_id
          FROM etl.v_data_quality q
          JOIN etl.v_staging s ON s.source_ref = q.source_ref
         ORDER BY q.captured_at, q.source_ref""")
    mismatches = rows(conn, """
        SELECT store_no, barcode, store_code, product_code, source_in_store, warehouse_in_store,
               source_reserved, warehouse_reserved, status
          FROM dw.rpt_reconciliation WHERE status <> 'match'
         ORDER BY store_no, barcode""")
    return Result({"rejected": rejected, "mismatches": mismatches, "summary": quality_summary(conn)},
                  scope="Rejected business-event records; live store system compared with the warehouse",
                  provenance=["etl.v_data_quality", "dw.rpt_reconciliation (store_ops.store_stock + dw)"])


# --- Source -> staging -> transformation -> warehouse trace ----------------------------------
SOURCE_QUERIES = {
    "stg_store_sale_line": ("store_ops.sale + store_ops.sale_line", """
        SELECT s.sale_no::text AS sale_no, l.line_no, s.store_no, s.till_no, l.barcode,
               l.quantity, l.unit_price, s.sold_at
          FROM store_ops.sale_line l JOIN store_ops.sale s USING (sale_no)
         WHERE l.sale_no = %(a)s AND l.line_no = %(b)s"""),
    "stg_supplier_delivery_line": ("supply.supplier_delivery + supply.supplier_delivery_line + supply.item", """
        SELECT d.delivery_no::text AS delivery_no, l.line_no, d.location_code, d.supplier_name,
               l.supplier_sku, l.cartons, i.units_per_carton,
               to_char(d.delivered_at_utc, 'YYYY-MM-DD HH24:MI:SS') AS delivered_at_utc
          FROM supply.supplier_delivery_line l
          JOIN supply.supplier_delivery d USING (delivery_no)
          JOIN supply.item i ON i.supplier_sku = l.supplier_sku
         WHERE l.delivery_no = %(a)s AND l.line_no = %(b)s"""),
    "stg_reservation_change": ("store_ops.reservation (current state of the record)", """
        SELECT reservation_no::text AS reservation_no, web_order_ref, web_line_no, store_no,
               pickup_store_no, barcode, quantity, status AS current_status,
               reserved_at, dispatched_at, arrived_at, closed_at, cancel_reason
          FROM store_ops.reservation WHERE reservation_no = %(a)s"""),
    "stg_checkout_item": ("online.checkout_attempt + online.checkout_attempt_item", """
        SELECT a.attempt_no::text AS attempt_no, a.basket_id::text AS basket_id, a.pickup_cp_code,
               a.attempted_at, a.outcome, i.web_sku, i.quantity, i.website_qty_shown, i.result,
               i.source_cp_code
          FROM online.checkout_attempt_item i JOIN online.checkout_attempt a USING (attempt_no)
         WHERE i.attempt_no = %(a)s AND i.web_sku = %(sku)s"""),
}

STAGING_SELECT = {
    "stg_store_sale_line": """
        SELECT stg_id::text AS stg_id, sale_no AS source_key, line_no AS source_line, store_no AS store_source_code,
               barcode AS product_source_code, quantity AS source_quantity, NULL::text AS source_unit,
               sold_at AS source_time, NULL::text AS source_time_utc, NULL::integer AS units_per_carton,
               NULL::text AS order_ref, NULL::text AS pickup_source_code, NULL::text AS detail,
               source_ref, load_status, note, etl_run_id, event_id::text AS event_id, captured_at, processed_at
          FROM etl.stg_store_sale_line WHERE stg_id = %s""",
    "stg_supplier_delivery_line": """
        SELECT stg_id::text AS stg_id, delivery_no AS source_key, line_no AS source_line, location_code AS store_source_code,
               supplier_sku AS product_source_code, cartons AS source_quantity, 'cartons' AS source_unit,
               (delivered_at_utc AT TIME ZONE 'UTC') AS source_time,
               to_char(delivered_at_utc, 'YYYY-MM-DD HH24:MI:SS') AS source_time_utc, units_per_carton,
               NULL::text AS order_ref, NULL::text AS pickup_source_code, NULL::text AS detail,
               source_ref, load_status, note, etl_run_id, event_id::text AS event_id, captured_at, processed_at
          FROM etl.stg_supplier_delivery_line WHERE stg_id = %s""",
    "stg_reservation_change": """
        SELECT stg_id::text AS stg_id, reservation_no AS source_key, NULL::integer AS source_line,
               store_no AS store_source_code, barcode AS product_source_code, quantity AS source_quantity,
               NULL::text AS source_unit, changed_at AS source_time, NULL::text AS source_time_utc,
               NULL::integer AS units_per_carton, web_order_ref AS order_ref,
               pickup_store_no AS pickup_source_code, change_type AS detail,
               source_ref, load_status, note, etl_run_id, event_id::text AS event_id, captured_at, processed_at
          FROM etl.stg_reservation_change WHERE stg_id = %s""",
    "stg_checkout_item": """
        SELECT stg_id::text AS stg_id, attempt_no AS source_key, NULL::integer AS source_line,
               pickup_cp_code AS store_source_code, web_sku AS product_source_code, quantity AS source_quantity,
               NULL::text AS source_unit, attempted_at AS source_time, NULL::text AS source_time_utc,
               NULL::integer AS units_per_carton, 'basket ' || basket_id AS order_ref,
               pickup_cp_code AS pickup_source_code, web_sku AS detail, result AS checkout_result,
               source_ref, load_status, note, etl_run_id, event_id::text AS event_id, captured_at, processed_at
          FROM etl.stg_checkout_item WHERE stg_id = %s""",
}

SOURCE_SYSTEM = {"stg_store_sale_line": "STORE", "stg_supplier_delivery_line": "SUPPLY",
                 "stg_reservation_change": "STORE", "stg_checkout_item": "ONLINE"}
SOURCE_LABEL = {"STORE": "Store system", "SUPPLY": "Supplier delivery system", "ONLINE": "Online store"}


def trace(conn, params) -> Result:
    event_id = int_param(params, "event_id", None, 1)
    table = choice_param(params, "table", STAGING_TABLES)
    stg_id = int_param(params, "id", None, 1)
    if event_id is not None:
        found = row(conn, "SELECT stg_table, stg_id FROM etl.v_staging WHERE event_id = %s", (event_id,))
        if found is None:
            raise NotFound(f"No staging record is linked to event {event_id}")
        table, stg_id = found["stg_table"], found["stg_id"]
    if table is None or stg_id is None:
        raise BadRequest("Give either event_id, or table and id")

    stg = row(conn, STAGING_SELECT[table], (stg_id,))
    if stg is None:
        raise NotFound(f"{table} row {stg_id} does not exist")
    system = SOURCE_SYSTEM[table]

    # 1. Source record, read from the operational system.
    label, sql = SOURCE_QUERIES[table]
    source_args = {"a": stg["source_key"], "b": stg["source_line"], "sku": stg["detail"]}
    source = row(conn, sql, source_args)

    # 3. Transformation, derived from the stored staging fields.
    fact = None
    if stg["event_id"]:
        fact = row(conn, """
            SELECT f.event_id::text AS event_id, f.event_type, p.product_code, p.product_name,
                   s.store_code, s.store_name, f.date_key, d.full_date AS business_date,
                   f.event_ts, f.quantity_change AS available_change, f.reserved_change, f.units,
                   f.order_ref, pk.store_code AS pickup_store_code, f.source_system, f.source_ref,
                   f.etl_run_id, f.loaded_at, f.product_key, f.store_key
              FROM dw.fact_stock_event f
              JOIN dw.dim_product p ON p.product_key = f.product_key
              JOIN dw.dim_store s   ON s.store_key = f.store_key
              JOIN dw.dim_date d    ON d.date_key = f.date_key
              LEFT JOIN dw.dim_store pk ON pk.store_key = f.pickup_store_key
             WHERE f.event_id = %s""", (int(stg["event_id"]),))
    pending = row(conn, """
        SELECT event_type, product_code, store_code, units, reject_reason, skip_reason
          FROM etl.v_transform WHERE stg_table = %s AND stg_id = %s""", (table, stg_id))
    current_product_map = value(conn, """
        SELECT product_code FROM etl.product_xref WHERE source_system = %s AND source_code = %s""",
                                (system, stg["product_source_code"]))
    current_store_map = value(conn, """
        SELECT store_code FROM etl.store_xref WHERE source_system = %s AND source_code = %s""",
                              (system, stg["store_source_code"]))
    business_date = value(conn, "SELECT (%s::timestamptz AT TIME ZONE 'Australia/Sydney')::date",
                          (stg["source_time"],)) if stg["source_time"] else None
    units = (stg["source_quantity"] * stg["units_per_carton"]
             if stg["units_per_carton"] and stg["source_quantity"] is not None else stg["source_quantity"])
    transform = {
        "product": {"source_code": stg["product_source_code"],
                    "warehouse_code": fact["product_code"] if fact else current_product_map,
                    "basis": "loaded fact row" if fact else "current approved mapping"},
        "store": {"source_code": stg["store_source_code"],
                  "warehouse_code": fact["store_code"] if fact else current_store_map,
                  "basis": "loaded fact row" if fact else "current approved mapping"},
        "quantity": {"source_quantity": stg["source_quantity"], "source_unit": stg["source_unit"] or "units",
                     "units_per_carton": stg["units_per_carton"], "units": units},
        "time": {"source_time_utc": stg["source_time_utc"], "event_ts": stg["source_time"],
                 "business_date": business_date},
        "pending_result": pending,
    }
    stg_out = {k: v for k, v in stg.items() if k not in ("source_key", "source_line")}
    stg_out["stg_table"] = table
    return Result({"source": {"system": system, "system_label": SOURCE_LABEL[system],
                              "tables": label, "record": source},
                   "staging": stg_out, "transform": transform, "warehouse": fact},
                  scope="One source record followed through staging into the warehouse",
                  provenance=[label, f"etl.{table}", "etl.product_xref", "etl.store_xref",
                              "dw.fact_stock_event"])
