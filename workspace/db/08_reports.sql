-- =============================================================================
-- 08_reports.sql
-- Purpose: Report views over the warehouse.
-- Design ref: docs/Architecture_and_Data_Model.md section 8.
-- Prerequisites: 05_warehouse.sql, 06_etl.sql.
--
--   Report 1  dw.rpt_current_stock_by_store   in-store vs reserved per store/product
--   Report 2  dw.rpt_online_staleness         time since last sync, pending events
--             dw.rpt_online_vs_actual         website number vs real total per product
--             dw.rpt_last_sync_changes        before/after of the most recent sync
--   Report 3  dw.rpt_checkout_blocked         bag items blocked at checkout although the website showed them
--   Report 4  dw.rpt_daily_sales              units sold per day, store and category
--   Report 5  dw.rpt_open_reservations        click-and-collect order lines not yet collected (incl. transfers)
--   Report 6  dw.rpt_reconciliation           warehouse vs live store system
--             etl.v_data_quality              source records rejected by the ETL (06_etl.sql)
--
-- Reports 1-5 read only the warehouse (and the ETL cross-reference for web
-- SKUs). Report 6 deliberately compares the warehouse with Source 1.
-- =============================================================================

-- Report 1 ------------------------------------------------------------------
CREATE VIEW dw.rpt_current_stock_by_store AS
SELECT s.store_code,
       s.store_name,
       p.product_code,
       p.product_name,
       p.category,
       coalesce(sum(f.quantity_change), 0)                                       AS in_store_quantity,
       coalesce(sum(f.reserved_change), 0)                                       AS reserved_quantity,
       coalesce(sum(f.quantity_change), 0) + coalesce(sum(f.reserved_change), 0) AS total_on_hand,
       coalesce(sum(f.quantity_change), 0) <= 2                                  AS low_stock,
       max(f.event_ts)                                                           AS last_event_at
  FROM dw.dim_store s
 CROSS JOIN dw.dim_product p
  LEFT JOIN dw.fact_stock_event f
         ON f.store_key = s.store_key AND f.product_key = p.product_key
 WHERE s.channel = 'physical'
 GROUP BY s.store_code, s.store_name, p.product_code, p.product_name, p.category;
COMMENT ON VIEW dw.rpt_current_stock_by_store IS
'Report 1. Current stock per store and product, rebuilt from the full event history. low_stock = 2 or fewer on the shelf.';

-- Report 2 ------------------------------------------------------------------
-- What the website shows now = latest synced value minus the website's own
-- reservations since that sync (it deducts those immediately).
CREATE VIEW dw.rpt_online_vs_actual AS
WITH last_synced AS (
    SELECT DISTINCT ON (c.product_key)
           c.product_key, c.after_qty, r.to_event_id, r.run_at
      FROM dw.sync_change c
      JOIN dw.sync_run r ON r.sync_id = c.sync_id
     WHERE c.measure = 'online_available'
     ORDER BY c.product_key, c.sync_id DESC
), shown AS (
    SELECT ls.product_key,
           ls.after_qty - coalesce((SELECT sum(f.units)
                                      FROM dw.fact_stock_event f
                                     WHERE f.product_key = ls.product_key
                                       AND f.event_type = 'reservation'
                                       AND f.event_id > ls.to_event_id), 0) AS online_shown,
           ls.run_at AS synced_at
      FROM last_synced ls
), actual AS (
    SELECT product_key, sum(quantity_change) AS actual_in_store
      FROM dw.fact_stock_event
     GROUP BY product_key
)
SELECT p.product_code,
       p.product_name,
       sh.online_shown,
       coalesce(a.actual_in_store, 0)                    AS actual_in_store,
       sh.online_shown - coalesce(a.actual_in_store, 0)  AS overstated_by,
       CASE
           WHEN sh.online_shown > coalesce(a.actual_in_store, 0) THEN 'overstated - oversell risk'
           WHEN sh.online_shown < coalesce(a.actual_in_store, 0) THEN 'understated - lost sales risk'
           ELSE 'in sync'
       END                                               AS status,
       sh.synced_at
  FROM shown sh
  JOIN dw.dim_product p ON p.product_key = sh.product_key
  LEFT JOIN actual a    ON a.product_key = sh.product_key;
COMMENT ON VIEW dw.rpt_online_vs_actual IS
'Report 2 (detail). Website number next to the real combined in-store stock now, per product sold online. Shows what a sync would correct.';

CREATE VIEW dw.rpt_online_staleness AS
WITH last_sync AS (
    SELECT * FROM dw.sync_run ORDER BY sync_id DESC LIMIT 1
), pending AS (
    SELECT f.event_type
      FROM dw.fact_stock_event f
     WHERE f.event_id > coalesce((SELECT to_event_id FROM last_sync), 0)
)
SELECT ls.sync_id                                                        AS last_sync_id,
       ls.run_at                                                         AS last_sync_at,
       date_trunc('second', now() - ls.run_at)                           AS time_since_sync,
       (SELECT count(*) FROM pending)                                    AS pending_events,
       (SELECT count(*) FROM pending WHERE event_type = 'store_sale')    AS pending_sales,
       (SELECT count(*) FROM pending WHERE event_type = 'delivery')      AS pending_deliveries,
       (SELECT count(*) FROM pending
         WHERE event_type IN ('reservation', 'transfer_out', 'transfer_in', 'collection', 'cancellation'))
                                                                         AS pending_order_events,
       (SELECT count(*) FROM pending WHERE event_type = 'checkout_blocked') AS pending_checkout_blocks,
       (SELECT count(*) FROM dw.rpt_online_vs_actual WHERE status <> 'in sync') AS products_out_of_date,
       (SELECT count(*) FROM etl.v_data_quality)                         AS source_rows_not_loaded
  FROM (SELECT 1) AS one
  LEFT JOIN last_sync ls ON true;
COMMENT ON VIEW dw.rpt_online_staleness IS
'Report 2 (summary). When the website was last synced, how many stock events happened since, how many product numbers are wrong now, and how many source rows the ETL could not load.';

CREATE VIEW dw.rpt_last_sync_changes AS
SELECT r.sync_id,
       r.run_at,
       r.events_processed,
       s.store_name                AS store_or_channel,
       p.product_code,
       p.product_name,
       c.measure,
       c.before_qty,
       c.after_qty,
       c.after_qty - c.before_qty  AS difference
  FROM dw.sync_change c
  JOIN dw.sync_run r    ON r.sync_id = c.sync_id
  JOIN dw.dim_store s   ON s.store_key = c.store_key
  JOIN dw.dim_product p ON p.product_key = c.product_key
 WHERE c.changed
   AND c.sync_id = (SELECT max(sync_id) FROM dw.sync_run);
COMMENT ON VIEW dw.rpt_last_sync_changes IS
'Report 2 (before/after). Every store and website number the most recent sync changed.';

-- Report 3 ------------------------------------------------------------------
CREATE VIEW dw.rpt_checkout_blocked AS
SELECT f.order_ref                                 AS basket,
       f.event_ts                                  AS attempted_at,
       p.product_code,
       p.product_name,
       f.units                                     AS quantity_in_bag,
       s.store_name                                AS pickup_store,
       shown.online_shown                          AS website_showed,
       real_total.actual_in_store                  AS actual_combined_at_checkout,
       CASE
           WHEN real_total.actual_in_store < f.units
               THEN 'stock sold since last sync - online number was stale'
           ELSE 'enough stock in total but no single store had enough'
       END                                         AS reason
  FROM dw.fact_stock_event f
  JOIN dw.dim_product p ON p.product_key = f.product_key
  JOIN dw.dim_store s   ON s.store_key = f.store_key
  -- Website number at checkout: latest sync before it, less the website's
  -- own reservations between that sync and the checkout.
  LEFT JOIN LATERAL (
      SELECT c.after_qty - coalesce((SELECT sum(e.units)
                                       FROM dw.fact_stock_event e
                                      WHERE e.product_key = f.product_key
                                        AND e.event_type = 'reservation'
                                        AND e.event_id > r.to_event_id
                                        AND e.event_id < f.event_id), 0) AS online_shown
        FROM dw.sync_change c
        JOIN dw.sync_run r ON r.sync_id = c.sync_id
       WHERE c.product_key = f.product_key
         AND c.measure = 'online_available'
         AND r.to_event_id < f.event_id
       ORDER BY r.sync_id DESC
       LIMIT 1
  ) shown ON true
  -- Real combined in-store stock at checkout.
  CROSS JOIN LATERAL (
      SELECT coalesce(sum(e.quantity_change), 0) AS actual_in_store
        FROM dw.fact_stock_event e
       WHERE e.product_key = f.product_key AND e.event_id < f.event_id
  ) real_total
 WHERE f.event_type = 'checkout_blocked';
COMMENT ON VIEW dw.rpt_checkout_blocked IS
'Report 3. Items customers put in their bag because the website showed them in stock, but checkout blocked before payment because no single store could supply them: the pickup store, what the website showed versus what was really there, and why. Lost sales caused by stale data.';

-- Report 4 ------------------------------------------------------------------
CREATE VIEW dw.rpt_daily_sales AS
SELECT d.full_date,
       d.day_name,
       d.is_weekend,
       s.store_name,
       p.category,
       sum(f.units)                     AS units_sold,
       count(*)                         AS sale_lines,
       sum(f.units * p.unit_price)      AS sales_value_at_current_price
  FROM dw.fact_stock_event f
  JOIN dw.dim_date d    ON d.date_key = f.date_key
  JOIN dw.dim_store s   ON s.store_key = f.store_key
  JOIN dw.dim_product p ON p.product_key = f.product_key
 WHERE f.event_type = 'store_sale'
 GROUP BY d.full_date, d.day_name, d.is_weekend, s.store_name, p.category;
COMMENT ON VIEW dw.rpt_daily_sales IS
'Report 4. In-store units sold per day, store and category (star-schema roll-up through dim_date). Value uses the current shelf price (dim_product is SCD type 1).';

-- Report 5 ------------------------------------------------------------------
CREATE VIEW dw.rpt_open_reservations AS
WITH line AS (
    -- One row per order line (order + product), from its reservation events.
    SELECT f.order_ref,
           f.product_key,
           max(f.pickup_store_key)                                                 AS pickup_store_key,
           (array_agg(f.store_key ORDER BY f.event_id)
                FILTER (WHERE f.event_type = 'reservation'))[1]                    AS source_store_key,
           max(f.units)                                                            AS units,
           min(f.event_ts) FILTER (WHERE f.event_type = 'reservation')             AS reserved_at,
           (array_agg(f.event_type ORDER BY f.event_id DESC))[1]                   AS last_event
      FROM dw.fact_stock_event f
     WHERE f.event_type IN ('reservation', 'transfer_out', 'transfer_in', 'collection', 'cancellation')
     GROUP BY f.order_ref, f.product_key
), open_line AS (
    SELECT l.*,
           CASE
               WHEN l.last_event = 'transfer_out' THEN 'in transit'
               WHEN l.last_event = 'transfer_in'  THEN 'ready for collection'
               WHEN l.source_store_key = l.pickup_store_key THEN 'ready for collection'
               ELSE 'waiting to be sent'
           END AS line_status
      FROM line l
     WHERE l.last_event NOT IN ('collection', 'cancellation')
)
SELECT o.order_ref                                       AS order_no,
       pk.store_name                                     AS pickup_store,
       p.product_code,
       p.product_name,
       o.units,
       src.store_name                                    AS taken_from,
       o.source_store_key <> o.pickup_store_key          AS is_transfer,
       o.line_status,
       bool_and(o.line_status = 'ready for collection')
           OVER (PARTITION BY o.order_ref)               AS order_ready,
       o.reserved_at,
       date_trunc('minute', now() - o.reserved_at)       AS waiting_for,
       now() - o.reserved_at > interval '3 days'         AS overdue
  FROM open_line o
  JOIN dw.dim_store pk  ON pk.store_key = o.pickup_store_key
  JOIN dw.dim_store src ON src.store_key = o.source_store_key
  JOIN dw.dim_product p ON p.product_key = o.product_key;
COMMENT ON VIEW dw.rpt_open_reservations IS
'Report 5. Click-and-collect order lines not yet collected or cancelled: pickup store, store the stock was taken from, transfer status (waiting to be sent / in transit / ready for collection), whether the whole order is ready, and overdue = waiting more than 3 days.';

-- Report 6 ------------------------------------------------------------------
CREATE VIEW dw.rpt_reconciliation AS
WITH warehouse AS (
    SELECT product_key, store_key,
           sum(quantity_change) AS in_store, sum(reserved_change) AS reserved
      FROM dw.fact_stock_event
     GROUP BY product_key, store_key
)
SELECT ss.store_no,
       ss.barcode,
       sx.store_code,
       px.product_code,
       ss.in_store_quantity       AS source_in_store,
       w.in_store                 AS warehouse_in_store,
       ss.reserved_quantity       AS source_reserved,
       w.reserved                 AS warehouse_reserved,
       CASE
           WHEN sx.store_code IS NULL OR px.product_code IS NULL THEN 'not in warehouse - unmapped code'
           WHEN coalesce(w.in_store, 0) <> ss.in_store_quantity
             OR coalesce(w.reserved, 0) <> ss.reserved_quantity  THEN 'quantity differs'
           ELSE 'match'
       END                        AS status
  FROM store_ops.store_stock ss
  LEFT JOIN etl.store_xref   sx ON sx.source_system = 'STORE' AND sx.source_code = ss.store_no
  LEFT JOIN etl.product_xref px ON px.source_system = 'STORE' AND px.source_code = ss.barcode
  LEFT JOIN dw.dim_store     ds ON ds.store_code = sx.store_code
  LEFT JOIN dw.dim_product   dp ON dp.product_code = px.product_code
  LEFT JOIN warehouse         w ON w.store_key = ds.store_key AND w.product_key = dp.product_key;
COMMENT ON VIEW dw.rpt_reconciliation IS
'Report 6. Live store stock (Source 1) against the warehouse total, per store and product. Anything other than match means the warehouse is missing or disagrees with source data.';
