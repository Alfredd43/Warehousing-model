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


def schedule_summary(conn) -> dict:
    """The automatic sync as the staleness report shows it."""
    r = row(conn, """
        SELECT scheduler_status, extract(epoch FROM sync_interval)::integer AS interval_seconds,
               next_sync_at, last_sync_at, last_sync_trigger
          FROM dw.rpt_online_staleness""")
    return r


def status(conn, params) -> Result:
    last = row(conn, """
        SELECT sync_id, source_sync_no::text AS source_sync_no, run_at, triggered_by
          FROM dw.sync_run ORDER BY sync_id DESC LIMIT 1""")
    return Result({"last_sync": last, "schedule": schedule_summary(conn), "quality": quality_summary(conn)},
                  provenance=["dw.sync_run", "dw.rpt_online_staleness", "etl.v_data_quality",
                              "dw.rpt_reconciliation"])


def health(conn, params) -> Result:
    r = row(conn, "SELECT current_database() AS database, now() AS server_time, version() AS version")
    r["database_available"] = True
    return Result(r)


# --- Overview: what the admin needs to act on -----------------------------------------
def overview(conn, params) -> Result:
    """Headline numbers and attention lists, all from the existing report views."""
    website = row(conn, """
        SELECT count(*)                                                   AS products,
               count(*) FILTER (WHERE status <> 'in sync')                AS out_of_date,
               count(*) FILTER (WHERE overstated_by > 0)                  AS overstated,
               count(*) FILTER (WHERE overstated_by < 0)                  AS understated
          FROM dw.rpt_online_vs_actual""")
    website["rows"] = rows(conn, """
        SELECT product_code, product_name, online_shown, actual_in_store, overstated_by AS difference
          FROM dw.rpt_online_vs_actual WHERE status <> 'in sync'
         ORDER BY abs(overstated_by) DESC, product_code LIMIT 6""")
    sync = row(conn, """
        SELECT scheduler_status, extract(epoch FROM sync_interval)::integer AS interval_seconds,
               next_sync_at, last_sync_at, last_sync_trigger, pending_events
          FROM dw.rpt_online_staleness""")
    stock = row(conn, """
        SELECT count(*) FILTER (WHERE in_store_quantity = 0)          AS out_of_stock,
               count(*) FILTER (WHERE in_store_quantity BETWEEN 1 AND 2) AS low_stock
          FROM dw.rpt_current_stock_by_store""")
    stock["rows"] = rows(conn, """
        SELECT store_code, store_name, product_code, product_name, in_store_quantity AS available,
               reserved_quantity AS reserved
          FROM dw.rpt_current_stock_by_store WHERE low_stock
         ORDER BY in_store_quantity, product_code, store_code LIMIT 8""")
    lost = row(conn, """
        SELECT count(*) AS items, coalesce(sum(quantity_in_bag), 0) AS units
          FROM dw.rpt_checkout_blocked WHERE attempted_at > now() - interval '7 days'""")
    lost["rows"] = rows(conn, """
        SELECT attempted_at, product_code, product_name, quantity_in_bag AS units, pickup_store,
               CASE WHEN starts_with(reason, 'stock sold since last sync') THEN 'stale' ELSE 'split' END AS reason_code
          FROM dw.rpt_checkout_blocked ORDER BY attempted_at DESC LIMIT 4""")
    orders = row(conn, """
        SELECT count(DISTINCT order_no)                                   AS open_orders,
               count(DISTINCT order_no) FILTER (WHERE order_ready)        AS ready,
               count(DISTINCT order_no) FILTER (WHERE NOT order_ready)    AS not_ready,
               count(DISTINCT order_no) FILTER (WHERE overdue)            AS overdue
          FROM dw.rpt_open_reservations""")
    sales = rows(conn, """
        SELECT channel, sum(units_sold)::integer AS units
          FROM dw.rpt_daily_sales WHERE full_date > current_date - 7
         GROUP BY channel ORDER BY channel""")
    return Result({"website": website, "sync": sync, "stock": stock, "lost_sales": lost, "orders": orders,
                   "sales_7_days": {r["channel"]: r["units"] for r in sales}, "quality": quality_summary(conn)},
                  scope="All five stores; lost sales and sales over the last 7 days",
                  provenance=["dw.rpt_online_vs_actual", "dw.rpt_online_staleness", "dw.rpt_current_stock_by_store",
                              "dw.rpt_checkout_blocked", "dw.rpt_open_reservations", "dw.rpt_daily_sales"])


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
    staleness = row(conn, """
        SELECT s.*, extract(epoch FROM s.sync_interval)::integer AS interval_seconds
          FROM dw.rpt_online_staleness s""")
    unlisted_online = value(conn, """
        SELECT count(*) FROM online.product p
         WHERE NOT EXISTS (SELECT 1 FROM etl.item_list l WHERE l.item_no = p.item_no)""")
    warnings = []
    if unlisted_online:
        warnings.append(f"{unlisted_online} online item(s) are not on the warehouse product list and are not compared.")
    return Result(
        {"comparison": comparison, "staleness": staleness, "quality": quality_summary(conn),
         "unmapped_online_products": unlisted_online},
        scope="All five stores combined; items on the warehouse product list",
        provenance=["dw.rpt_online_vs_actual (online.online_stock + dw.fact_stock_event)",
                    "dw.rpt_online_staleness"],
        warnings=warnings)


def sync_latest(conn, params) -> Result:
    sync_id = int_param(params, "sync_id", None, 1)
    runs = rows(conn, """
        SELECT sync_id, source_sync_no::text AS source_sync_no, run_at, triggered_by, events_processed,
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
        SELECT i.item_no, p.title, i.item_no AS product_code, i.quantity, i.website_qty_shown, i.result,
               i.source_cp_code, cp.cp_name AS source_cp_name,
               s.stg_id::text AS stg_id, s.load_status, s.note, s.event_id::text AS event_id
          FROM online.checkout_attempt_item i
          JOIN online.product p ON p.item_no = i.item_no
          LEFT JOIN online.collection_point cp ON cp.cp_code = i.source_cp_code
          LEFT JOIN etl.stg_checkout_item s ON s.attempt_no = i.attempt_no AND s.item_no = i.item_no
         WHERE i.attempt_no = %s
         ORDER BY i.item_no""", (int(attempt_no),))
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
