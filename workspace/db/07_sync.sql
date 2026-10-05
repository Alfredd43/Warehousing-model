-- =============================================================================
-- 07_sync.sql
-- Purpose: Load each website stock sync into the warehouse, for reporting.
-- Design ref: docs/Architecture_and_Data_Model.md section 7.
-- Prerequisites: 04_online.sql, 05_warehouse.sql, 06_etl.sql.
--
-- The sync itself is OPERATIONAL and does not use the warehouse:
-- online.sync_website_stock() (04_online.sql) takes the real shelf totals from
-- the store system and writes them to the website, logging before/after in
-- online.stock_sync / stock_sync_line.
--
-- This file is the ANALYTICAL side. When a sync finishes, its log is
--   EXTRACTED  into etl.stg_website_sync_line (source format: web SKUs),
--   TRANSFORMED to warehouse products through the approved cross-reference,
--   LOADED     into dw.sync_run / dw.sync_change, together with what the
--              warehouse knows about that moment: the stock events since the
--              previous sync, the store totals they changed, and a
--              reconciliation of the warehouse against the store system.
-- Like the rest of the ETL it runs in the same transaction, straight after
-- the sync, so the reports always include the latest sync.
-- =============================================================================

CREATE TABLE etl.stg_website_sync_line (
    stg_id        bigint      GENERATED ALWAYS AS IDENTITY,
    sync_no       bigint      NOT NULL,
    run_at        timestamptz NOT NULL,
    web_sku       text        NOT NULL,
    before_qty    integer     NOT NULL,
    after_qty     integer     NOT NULL,
    source_ref    text        NOT NULL,
    load_status   text        NOT NULL DEFAULT 'pending',
    note          text,
    captured_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    processed_at  timestamptz,
    CONSTRAINT pk_stg_website_sync_line PRIMARY KEY (stg_id),
    CONSTRAINT uq_stg_website_sync_line_ref UNIQUE (source_ref),
    CONSTRAINT ck_stg_website_sync_line_status CHECK (load_status IN ('pending', 'loaded', 'skipped'))
);
COMMENT ON TABLE etl.stg_website_sync_line IS
'Extract of online.stock_sync_line for each finished website sync, in online-store codes. Lines whose web SKU has no approved mapping are skipped with a note.';


-- Load one finished website sync into the warehouse.
CREATE FUNCTION dw.load_website_sync(p_sync_no bigint) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_run_at      timestamptz;
    v_from        bigint;
    v_to          bigint;
    v_sync_id     integer;
    v_online_key  integer;
BEGIN
    SELECT run_at INTO v_run_at FROM online.stock_sync WHERE sync_no = p_sync_no;

    -- EXTRACT: the sync log, unchanged.
    INSERT INTO etl.stg_website_sync_line (sync_no, run_at, web_sku, before_qty, after_qty, source_ref)
    SELECT l.sync_no, v_run_at, l.web_sku, l.before_qty, l.after_qty,
           format('ONLINE:sync %s %s', l.sync_no, l.web_sku)
      FROM online.stock_sync_line l
     WHERE l.sync_no = p_sync_no;

    -- Make sure every stock event so far is in the warehouse.
    PERFORM etl.run_etl('sync');
    PERFORM etl.load_dimensions();
    SELECT store_key INTO v_online_key FROM dw.dim_store WHERE store_code = 'ONLINE';

    -- The stock events between the previous sync and this one.
    LOCK TABLE dw.sync_run IN EXCLUSIVE MODE;
    SELECT coalesce(max(to_event_id), 0) INTO v_from FROM dw.sync_run;
    SELECT coalesce(max(event_id), v_from) INTO v_to FROM dw.fact_stock_event;

    INSERT INTO dw.sync_run (source_sync_no, run_at, from_event_id, to_event_id, events_processed,
                             numbers_changed, store_mismatches)
    SELECT p_sync_no, v_run_at, v_from, v_to, count(*), 0, 0
      FROM dw.fact_stock_event
     WHERE event_id > v_from AND event_id <= v_to
    RETURNING sync_id INTO v_sync_id;

    -- Store totals touched since the previous sync (from the warehouse history).
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

    -- TRANSFORM + LOAD: the website numbers, web SKU -> warehouse product.
    INSERT INTO dw.sync_change (sync_id, product_key, store_key, measure, before_qty, after_qty)
    SELECT v_sync_id, p.product_key, v_online_key, 'online_available', s.before_qty, s.after_qty
      FROM etl.stg_website_sync_line s
      JOIN etl.product_xref x ON x.source_system = 'ONLINE' AND x.source_code = s.web_sku
      JOIN dw.dim_product p   ON p.product_code = x.product_code
     WHERE s.sync_no = p_sync_no;

    UPDATE etl.stg_website_sync_line s
       SET load_status  = CASE WHEN x.product_code IS NULL THEN 'skipped' ELSE 'loaded' END,
           note         = CASE WHEN x.product_code IS NULL
                               THEN format('No approved ONLINE product mapping for %s', s.web_sku) END,
           processed_at = clock_timestamp()
      FROM (SELECT s2.stg_id, x2.product_code
              FROM etl.stg_website_sync_line s2
              LEFT JOIN etl.product_xref x2 ON x2.source_system = 'ONLINE' AND x2.source_code = s2.web_sku
             WHERE s2.sync_no = p_sync_no) x
     WHERE s.stg_id = x.stg_id;

    -- Summary counts and reconciliation of the warehouse with the store system.
    UPDATE dw.sync_run
       SET numbers_changed  = (SELECT count(*) FROM dw.sync_change c
                                WHERE c.sync_id = v_sync_id AND c.changed),
           store_mismatches = (SELECT count(*) FROM dw.rpt_reconciliation
                                WHERE status <> 'match')
     WHERE sync_id = v_sync_id;

    RETURN v_sync_id;
END;
$$;

-- CDC: load the sync into the warehouse as soon as the online store marks it done.
CREATE FUNCTION etl.cdc_website_sync() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM dw.load_website_sync(NEW.sync_no);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_stock_sync_to_dw
AFTER UPDATE OF status ON online.stock_sync
FOR EACH ROW WHEN (NEW.status = 'done' AND OLD.status IS DISTINCT FROM 'done')
EXECUTE FUNCTION etl.cdc_website_sync();
