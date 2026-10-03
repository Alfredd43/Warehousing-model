-- =============================================================================
-- 07_sync.sql
-- Purpose: The manual "run sync now" job, dw.run_sync().
-- Design ref: docs/Architecture_and_Data_Model.md section 7.
-- Prerequisites: 04_online.sql, 05_warehouse.sql, 06_etl.sql.
-- What it does, in one transaction:
--   1. Runs an ETL pass, so any staged rows (e.g. previously rejected rows
--      whose mapping has since been approved) are in the warehouse.
--   2. Takes every fact event after the previous sync's last event.
--   3. Recalculates each touched store/product running total (in_store,
--      reserved) from the fact history and logs before/after.
--   4. Recalculates the combined online available quantity per product
--      (sum of in-store stock over the 5 stores; reserved stock is not
--      available) and logs before (what the website shows) and after.
--   5. Publishes the new numbers to Source 3 (online.online_stock), translating
--      conformed product codes back to web SKUs.
--   6. Reconciles the warehouse against the live store system.
-- Run on demand only: SELECT dw.run_sync();
-- p_run_at lets the seed script record a sync in the past.
-- =============================================================================

CREATE FUNCTION dw.run_sync(p_run_at timestamptz DEFAULT now()) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_from        bigint;
    v_to          bigint;
    v_sync_id     integer;
    v_online_key  integer;
BEGIN
    PERFORM etl.run_etl('sync');
    PERFORM etl.load_dimensions();
    SELECT store_key INTO v_online_key FROM dw.dim_store WHERE store_code = 'ONLINE';

    -- Hold new events back until this sync commits, so the window
    -- (v_from, v_to] is complete. One sync runs at a time.
    LOCK TABLE dw.fact_stock_event IN SHARE MODE;
    LOCK TABLE dw.sync_run IN EXCLUSIVE MODE;

    SELECT coalesce(max(to_event_id), 0) INTO v_from FROM dw.sync_run;
    SELECT coalesce(max(event_id), v_from) INTO v_to FROM dw.fact_stock_event;

    INSERT INTO dw.sync_run (run_at, from_event_id, to_event_id, events_processed, numbers_changed, store_mismatches)
    SELECT p_run_at, v_from, v_to, count(*), 0, 0
      FROM dw.fact_stock_event
     WHERE event_id > v_from AND event_id <= v_to
    RETURNING sync_id INTO v_sync_id;

    -- 3. Store running totals for every store/product the new events touched.
    INSERT INTO dw.sync_change (sync_id, product_key, store_key, measure, before_qty, after_qty)
    WITH touched AS (
        SELECT DISTINCT product_key, store_key
          FROM dw.fact_stock_event
         WHERE event_id > v_from AND event_id <= v_to
    ), totals AS (
        SELECT t.product_key, t.store_key,
               coalesce(sum(f.quantity_change) FILTER (WHERE f.event_id <= v_from), 0) AS in_before,
               sum(f.quantity_change)                                                  AS in_after,
               coalesce(sum(f.reserved_change) FILTER (WHERE f.event_id <= v_from), 0) AS res_before,
               sum(f.reserved_change)                                                  AS res_after
          FROM touched t
          JOIN dw.fact_stock_event f
            ON f.product_key = t.product_key AND f.store_key = t.store_key AND f.event_id <= v_to
         GROUP BY t.product_key, t.store_key
    )
    SELECT v_sync_id, product_key, store_key, 'in_store', in_before, in_after FROM totals
    UNION ALL
    SELECT v_sync_id, product_key, store_key, 'reserved', res_before, res_after FROM totals
     WHERE res_before <> 0 OR res_after <> 0;

    -- 4. Combined online number for every product sold online:
    --    what the website shows now -> recalculated value.
    INSERT INTO dw.sync_change (sync_id, product_key, store_key, measure, before_qty, after_qty)
    SELECT v_sync_id, p.product_key, v_online_key, 'online_available',
           coalesce(os.available_quantity, 0),
           coalesce((SELECT sum(f.quantity_change)
                       FROM dw.fact_stock_event f
                      WHERE f.product_key = p.product_key AND f.event_id <= v_to), 0)
      FROM dw.dim_product p
      JOIN etl.product_xref x ON x.product_code = p.product_code AND x.source_system = 'ONLINE'
      LEFT JOIN online.online_stock os ON os.web_sku = x.source_code;

    -- 5. Publish to Source 3 in its own codes.
    INSERT INTO online.online_stock (web_sku, available_quantity, last_synced_at)
    SELECT x.source_code, c.after_qty, p_run_at
      FROM dw.sync_change c
      JOIN dw.dim_product p ON p.product_key = c.product_key
      JOIN etl.product_xref x ON x.product_code = p.product_code AND x.source_system = 'ONLINE'
     WHERE c.sync_id = v_sync_id AND c.measure = 'online_available'
    ON CONFLICT (web_sku) DO UPDATE
       SET available_quantity = EXCLUDED.available_quantity,
           last_synced_at     = EXCLUDED.last_synced_at;

    -- 6. Summary counts and reconciliation with the store system.
    UPDATE dw.sync_run
       SET numbers_changed  = (SELECT count(*) FROM dw.sync_change c
                                WHERE c.sync_id = v_sync_id AND c.changed),
           store_mismatches = (SELECT count(*) FROM dw.rpt_reconciliation
                                WHERE status <> 'match')
     WHERE sync_id = v_sync_id;

    RETURN v_sync_id;
END;
$$;
