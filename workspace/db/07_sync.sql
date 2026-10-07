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
--   EXTRACTED  into etl.stg_website_sync_line (source format),
--   TRANSFORMED to warehouse products by item number,
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
    item_no       text        NOT NULL,
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
'Extract of online.stock_sync_line for each finished website sync. Lines for an item not on the warehouse product list are skipped with a note.';


-- Load one finished website sync into the warehouse.
CREATE FUNCTION dw.load_website_sync(p_sync_no bigint) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_run_at      timestamptz;
    v_trigger     text;
    v_from        bigint;
    v_to          bigint;
    v_sync_id     integer;
    v_online_key  integer;
BEGIN
    SELECT run_at, triggered_by INTO v_run_at, v_trigger FROM online.stock_sync WHERE sync_no = p_sync_no;

    -- EXTRACT: the sync log, unchanged.
    INSERT INTO etl.stg_website_sync_line (sync_no, run_at, item_no, before_qty, after_qty, source_ref)
    SELECT l.sync_no, v_run_at, l.item_no, l.before_qty, l.after_qty,
           format('ONLINE:sync %s item %s', l.sync_no, l.item_no)
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

    INSERT INTO dw.sync_run (source_sync_no, run_at, triggered_by, from_event_id, to_event_id, events_processed,
                             numbers_changed, store_mismatches)
    SELECT p_sync_no, v_run_at, v_trigger, v_from, v_to, count(*), 0, 0
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

    -- TRANSFORM + LOAD: the website numbers, matched to warehouse products
    -- by item number (the same in every system).
    INSERT INTO dw.sync_change (sync_id, product_key, store_key, measure, before_qty, after_qty)
    SELECT v_sync_id, p.product_key, v_online_key, 'online_available', s.before_qty, s.after_qty
      FROM etl.stg_website_sync_line s
      JOIN dw.dim_product p ON p.product_code = s.item_no
     WHERE s.sync_no = p_sync_no;

    UPDATE etl.stg_website_sync_line s
       SET load_status  = CASE WHEN p.product_code IS NULL THEN 'skipped' ELSE 'loaded' END,
           note         = CASE WHEN p.product_code IS NULL
                               THEN format('Unknown item %s: not on the warehouse product list', s.item_no) END,
           processed_at = clock_timestamp()
      FROM etl.stg_website_sync_line s2
      LEFT JOIN dw.dim_product p ON p.product_code = s2.item_no
     WHERE s2.stg_id = s.stg_id AND s2.sync_no = p_sync_no;

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
