-- =============================================================================
-- 06_etl.sql
-- Purpose: ETL from the three sources into the warehouse.
-- Design ref: docs/Architecture_and_Data_Model.md section 5.
-- Prerequisites: 02-05.
--
-- Pipeline (one pass = one row in etl.etl_run):
--
--   EXTRACT    Change-data-capture triggers copy every new source record,
--              unchanged and in its SOURCE format (the source's store code,
--              cartons, UTC), into a per-source staging table with
--              load_status = 'pending'. Each row keeps its transaction ID
--              (receipt number, order ID or supplier order number).
--   TRANSFORM  etl.v_transform: check the item number against the
--              warehouse product list, map the source's store code to the
--              warehouse store code through the approved cross-reference,
--              convert cartons to units and UTC to Sydney time, derive the
--              event type and signed quantities, look up surrogate keys.
--   VALIDATE   Same view: a row that cannot be loaded gets a reject_reason
--              (e.g. "Unknown item P019"). It is NOT guessed and NOT loaded;
--              it stays in staging as 'rejected' and is retried on every
--              run, so it loads as soon as a data steward adds the item to
--              the product list.
--   LOAD       etl.run_etl(): refresh dimensions (SCD 1), insert valid rows
--              into dw.fact_stock_event, mark staging rows loaded / rejected /
--              skipped, record counts in etl.etl_run.
--
-- When it runs: a statement-level trigger on each source table calls
-- etl.run_etl() straight after the source change, in the same transaction
-- (near-real-time micro-batch), so the warehouse is never behind the stores.
-- It can also be run by hand: SELECT etl.run_etl();  (e.g. after adding an
-- item). Loading a website sync (07_sync.sql) runs it first as well.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Reference data maintained by a data steward.
--    Items: all three systems use the same item number, so there is no
--    product mapping. The warehouse accepts only items on its product list;
--    a record for any other item is rejected as "Unknown item".
--    Stores: each system still has its own store code, so store codes are
--    mapped to the warehouse store code (S01...) through an approved list.
-- -----------------------------------------------------------------------------
CREATE TABLE etl.item_list (
    item_no   text        NOT NULL,
    added_by  text        NOT NULL DEFAULT current_user,
    added_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_item_list PRIMARY KEY (item_no)
);
COMMENT ON TABLE etl.item_list IS
'The warehouse product list: item numbers the warehouse accepts. Records for an item not on the list are rejected with "Unknown item" and load once a data steward adds it.';

-- Data-steward action: add an item to the warehouse product list. The item
-- must exist in the store catalogue, the system of record for products.
-- Example: SELECT etl.add_item('P019');
CREATE FUNCTION etl.add_item(p_item_no text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM store_ops.product WHERE item_no = p_item_no) THEN
        RAISE EXCEPTION 'Item % is not in the store catalogue', p_item_no;
    END IF;
    IF EXISTS (SELECT 1 FROM etl.item_list WHERE item_no = p_item_no) THEN
        RAISE EXCEPTION 'Item % is already on the warehouse product list', p_item_no;
    END IF;
    INSERT INTO etl.item_list (item_no) VALUES (p_item_no);
END;
$$;

CREATE TABLE etl.store_xref (
    source_system  text        NOT NULL,
    source_code    text        NOT NULL,
    store_code     text        NOT NULL,
    approved_by    text        NOT NULL DEFAULT current_user,
    approved_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_store_xref PRIMARY KEY (source_system, source_code),
    CONSTRAINT uq_store_xref_code UNIQUE (source_system, store_code),
    CONSTRAINT ck_store_xref_system CHECK (source_system IN ('STORE', 'SUPPLY', 'ONLINE'))
);
COMMENT ON TABLE etl.store_xref IS
'Approved mapping of each source''s store code (STORE store number, SUPPLY location code, ONLINE collection point) to the warehouse store code (S01...).';


-- -----------------------------------------------------------------------------
-- 2. ETL run log (audit).
-- -----------------------------------------------------------------------------
CREATE TABLE etl.etl_run (
    etl_run_id     integer     GENERATED ALWAYS AS IDENTITY,
    trigger_source text        NOT NULL,
    started_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at    timestamptz,
    rows_read      integer,
    rows_loaded    integer,
    rows_rejected  integer,
    rows_skipped   integer,
    CONSTRAINT pk_etl_run PRIMARY KEY (etl_run_id)
);
COMMENT ON TABLE etl.etl_run IS
'One row per ETL pass: what started it (cdc:<source table>, sync or manual), when, and how many staged rows it loaded, rejected or skipped.';

ALTER TABLE dw.fact_stock_event
    ADD CONSTRAINT fk_fact_etl_run FOREIGN KEY (etl_run_id) REFERENCES etl.etl_run (etl_run_id);


-- -----------------------------------------------------------------------------
-- 3. Staging tables: one per source record type, in SOURCE format.
--    Common columns: source_ref (lineage: system + transaction ID, unique),
--    load_status, note, etl_run_id / event_id (where it went),
--    captured_at / processed_at.
-- -----------------------------------------------------------------------------
CREATE TABLE etl.stg_store_sale_line (
    stg_id        bigint      GENERATED ALWAYS AS IDENTITY,
    sale_no       bigint      NOT NULL,
    line_no       integer     NOT NULL,
    store_no      text,
    item_no       text,
    quantity      integer,
    sold_at       timestamptz,
    source_ref    text        NOT NULL,
    load_status   text        NOT NULL DEFAULT 'pending',
    note          text,
    etl_run_id    integer,
    event_id      bigint,
    captured_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    processed_at  timestamptz,
    CONSTRAINT pk_stg_store_sale_line PRIMARY KEY (stg_id),
    CONSTRAINT uq_stg_store_sale_line_ref UNIQUE (source_ref),
    CONSTRAINT ck_stg_store_sale_line_status CHECK (load_status IN ('pending', 'loaded', 'rejected', 'skipped'))
);
COMMENT ON TABLE etl.stg_store_sale_line IS 'Extract of store_ops.sale_line joined to its receipt, in store-system codes. sale_no = receipt number.';

CREATE TABLE etl.stg_supplier_delivery_line (
    stg_id             bigint      GENERATED ALWAYS AS IDENTITY,
    delivery_no        bigint      NOT NULL,
    line_no            integer     NOT NULL,
    supplier_id        text,
    supplier_order_no  text,
    location_code      text,
    item_no            text,
    cartons            integer,
    units_per_carton   integer,
    delivered_at_utc   timestamp,
    source_ref         text        NOT NULL,
    load_status        text        NOT NULL DEFAULT 'pending',
    note               text,
    etl_run_id         integer,
    event_id           bigint,
    captured_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    processed_at       timestamptz,
    CONSTRAINT pk_stg_supplier_delivery_line PRIMARY KEY (stg_id),
    CONSTRAINT uq_stg_supplier_delivery_line_ref UNIQUE (source_ref),
    CONSTRAINT ck_stg_supplier_delivery_line_status CHECK (load_status IN ('pending', 'loaded', 'rejected', 'skipped'))
);
COMMENT ON TABLE etl.stg_supplier_delivery_line IS
'Extract of supply.supplier_delivery_line joined to its docket and item, in supplier delivery-system format: cartons and UTC time, not yet converted. supplier_id + supplier_order_no = the supplier transaction ID.';

CREATE TABLE etl.stg_reservation_change (
    stg_id          bigint      GENERATED ALWAYS AS IDENTITY,
    reservation_no  bigint      NOT NULL,
    change_type     text        NOT NULL,
    store_no        text,
    pickup_store_no text,
    item_no         text,
    quantity        integer,
    web_order_ref   text,
    web_line_no     integer,
    changed_at      timestamptz,
    source_ref      text        NOT NULL,
    load_status     text        NOT NULL DEFAULT 'pending',
    note            text,
    etl_run_id      integer,
    event_id        bigint,
    captured_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    processed_at    timestamptz,
    CONSTRAINT pk_stg_reservation_change PRIMARY KEY (stg_id),
    CONSTRAINT uq_stg_reservation_change_ref UNIQUE (source_ref),
    CONSTRAINT ck_stg_reservation_change_type CHECK (change_type IN ('held', 'in_transit', 'arrived', 'collected', 'cancelled')),
    CONSTRAINT ck_stg_reservation_change_status CHECK (load_status IN ('pending', 'loaded', 'rejected', 'skipped'))
);
COMMENT ON TABLE etl.stg_reservation_change IS
'Extract of each store_ops.reservation status change (held, in_transit, arrived, collected, cancelled), identified by the order ID and line. store_no = the store where this step changed stock; pickup_store_no = where the customer collects.';

CREATE TABLE etl.stg_checkout_item (
    stg_id           bigint      GENERATED ALWAYS AS IDENTITY,
    attempt_no       bigint      NOT NULL,
    basket_id        bigint      NOT NULL,
    item_no          text,
    quantity         integer,
    pickup_cp_code   text,
    result           text,
    attempted_at     timestamptz,
    source_ref       text        NOT NULL,
    load_status      text        NOT NULL DEFAULT 'pending',
    note             text,
    etl_run_id       integer,
    event_id         bigint,
    captured_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    processed_at     timestamptz,
    CONSTRAINT pk_stg_checkout_item PRIMARY KEY (stg_id),
    CONSTRAINT uq_stg_checkout_item_ref UNIQUE (source_ref),
    CONSTRAINT ck_stg_checkout_item_status CHECK (load_status IN ('pending', 'loaded', 'rejected', 'skipped'))
);
COMMENT ON TABLE etl.stg_checkout_item IS
'Extract of online.checkout_attempt_item joined to its attempt, in online-store codes. Unavailable items become checkout_blocked facts; available items are skipped (if paid, their stock movement is loaded from the store reservation under the order ID).';


-- -----------------------------------------------------------------------------
-- 4. EXTRACT: change-data-capture triggers (row level, copy as-is).
-- -----------------------------------------------------------------------------
CREATE FUNCTION etl.capture_sale_line() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO etl.stg_store_sale_line (sale_no, line_no, store_no, item_no, quantity, sold_at, source_ref)
    SELECT NEW.sale_no, NEW.line_no, s.store_no, NEW.item_no, NEW.quantity, s.sold_at,
           format('STORE:receipt %s line %s', NEW.sale_no, NEW.line_no)
      FROM store_ops.sale s WHERE s.sale_no = NEW.sale_no;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_sale_line_extract
AFTER INSERT ON store_ops.sale_line
FOR EACH ROW EXECUTE FUNCTION etl.capture_sale_line();

CREATE FUNCTION etl.capture_supplier_delivery_line() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO etl.stg_supplier_delivery_line
        (delivery_no, line_no, supplier_id, supplier_order_no, location_code, item_no,
         cartons, units_per_carton, delivered_at_utc, source_ref)
    SELECT NEW.delivery_no, NEW.line_no, d.supplier_id, d.supplier_order_no, d.location_code, NEW.item_no,
           NEW.cartons, i.units_per_carton, d.delivered_at_utc,
           format('SUPPLY:supplier %s order %s line %s', d.supplier_id, d.supplier_order_no, NEW.line_no)
      FROM supply.supplier_delivery d
      JOIN supply.item i ON i.item_no = NEW.item_no
     WHERE d.delivery_no = NEW.delivery_no;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_supplier_delivery_line_extract
AFTER INSERT ON supply.supplier_delivery_line
FOR EACH ROW EXECUTE FUNCTION etl.capture_supplier_delivery_line();

CREATE FUNCTION etl.capture_reservation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO etl.stg_reservation_change
        (reservation_no, change_type, store_no, pickup_store_no, item_no, quantity,
         web_order_ref, web_line_no, changed_at, source_ref)
    VALUES
        (NEW.reservation_no, NEW.status,
         -- Where this step changed stock: held / sent at the source store;
         -- arrived / collected at the pickup store; cancelled wherever it was.
         CASE
             WHEN NEW.status IN ('held', 'in_transit') THEN NEW.store_no
             WHEN NEW.status IN ('arrived', 'collected') THEN NEW.pickup_store_no
             WHEN TG_OP = 'UPDATE' AND OLD.status = 'arrived' THEN NEW.pickup_store_no
             ELSE NEW.store_no
         END,
         NEW.pickup_store_no, NEW.item_no, NEW.quantity, NEW.web_order_ref, NEW.web_line_no,
         CASE NEW.status
             WHEN 'held'       THEN NEW.reserved_at
             WHEN 'in_transit' THEN NEW.dispatched_at
             WHEN 'arrived'    THEN NEW.arrived_at
             ELSE NEW.closed_at
         END,
         -- One order line passes through each status at most once.
         format('STORE:order %s line %s %s', NEW.web_order_ref, NEW.web_line_no, NEW.status));
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_reservation_extract_insert
AFTER INSERT ON store_ops.reservation
FOR EACH ROW EXECUTE FUNCTION etl.capture_reservation();
CREATE TRIGGER trg_reservation_extract_update
AFTER UPDATE OF status ON store_ops.reservation
FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION etl.capture_reservation();

CREATE FUNCTION etl.capture_checkout_item() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- A blocked checkout never becomes an order, so it has no order ID; the
    -- checkout attempt and the bag identify it instead.
    INSERT INTO etl.stg_checkout_item
        (attempt_no, basket_id, item_no, quantity, pickup_cp_code, result, attempted_at, source_ref)
    SELECT NEW.attempt_no, a.basket_id, NEW.item_no, NEW.quantity, a.pickup_cp_code, NEW.result, a.attempted_at,
           format('ONLINE:checkout attempt %s item %s', NEW.attempt_no, NEW.item_no)
      FROM online.checkout_attempt a WHERE a.attempt_no = NEW.attempt_no;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_checkout_item_extract
AFTER INSERT ON online.checkout_attempt_item
FOR EACH ROW EXECUTE FUNCTION etl.capture_checkout_item();


-- -----------------------------------------------------------------------------
-- 5. Dimension load (SCD type 1) from the store system, the system of record
--    for product and store attributes. Products: every item on the
--    warehouse product list. Only rows that change are updated.
-- -----------------------------------------------------------------------------
CREATE FUNCTION etl.load_dimensions() RETURNS void
LANGUAGE sql AS $$
    INSERT INTO dw.dim_product (product_code, product_name, category, unit_price)
    SELECT p.item_no, p.description, p.category, p.shelf_price
      FROM etl.item_list l
      JOIN store_ops.product p ON p.item_no = l.item_no
    ON CONFLICT (product_code) DO UPDATE
       SET product_name = EXCLUDED.product_name,
           category     = EXCLUDED.category,
           unit_price   = EXCLUDED.unit_price
     WHERE (dw.dim_product.product_name, dw.dim_product.category, dw.dim_product.unit_price)
           IS DISTINCT FROM (EXCLUDED.product_name, EXCLUDED.category, EXCLUDED.unit_price);

    INSERT INTO dw.dim_store (store_code, store_name, channel, suburb, postcode)
    SELECT x.store_code, s.store_name, 'physical', s.suburb, s.postcode
      FROM etl.store_xref x
      JOIN store_ops.store s ON s.store_no = x.source_code
     WHERE x.source_system = 'STORE'
    UNION ALL
    SELECT 'ONLINE', 'PetHaven Online', 'online', NULL, NULL
    ON CONFLICT (store_code) DO UPDATE
       SET store_name = EXCLUDED.store_name,
           suburb     = EXCLUDED.suburb,
           postcode   = EXCLUDED.postcode
     WHERE (dw.dim_store.store_name, dw.dim_store.suburb, dw.dim_store.postcode)
           IS DISTINCT FROM (EXCLUDED.store_name, EXCLUDED.suburb, EXCLUDED.postcode);
$$;


-- -----------------------------------------------------------------------------
-- 6. TRANSFORM + VALIDATE: every staged row still to process, in warehouse
--    terms. event_type NULL = nothing to load (skip_reason says why).
-- -----------------------------------------------------------------------------
CREATE VIEW etl.v_transform AS
WITH staged AS (
    -- In-store till sale lines: units as recorded.
    SELECT 'stg_store_sale_line'::text AS stg_table, s.stg_id, 'STORE'::text AS source_system,
           s.source_ref, 'store_sale'::text AS event_type, NULL::text AS skip_reason,
           s.store_no AS store_source_code, s.item_no,
           s.quantity AS units, s.sold_at AS event_ts, NULL::text AS order_ref,
           NULL::text AS pickup_source_code
      FROM etl.stg_store_sale_line s
     WHERE s.load_status IN ('pending', 'rejected')
    UNION ALL
    -- Supplier deliveries: cartons -> units, UTC -> timestamptz.
    SELECT 'stg_supplier_delivery_line', d.stg_id, 'SUPPLY', d.source_ref, 'supplier_delivery', NULL,
           d.location_code, d.item_no,
           d.cartons * d.units_per_carton, d.delivered_at_utc AT TIME ZONE 'UTC', NULL, NULL
      FROM etl.stg_supplier_delivery_line d
     WHERE d.load_status IN ('pending', 'rejected')
    UNION ALL
    -- Order line steps -> reservation / transfer_out / transfer_in /
    -- collection / cancellation, at the store where the step changed stock.
    SELECT 'stg_reservation_change', r.stg_id, 'STORE', r.source_ref,
           CASE r.change_type WHEN 'held'       THEN 'reservation'
                              WHEN 'in_transit' THEN 'transfer_out'
                              WHEN 'arrived'    THEN 'transfer_in'
                              WHEN 'collected'  THEN 'collection'
                              WHEN 'cancelled'  THEN 'cancellation' END,
           NULL,
           r.store_no, r.item_no, r.quantity, r.changed_at, r.web_order_ref, r.pickup_store_no
      FROM etl.stg_reservation_change r
     WHERE r.load_status IN ('pending', 'rejected')
    UNION ALL
    -- Checkout items: an unavailable item is a checkout_blocked event (at the
    -- pickup store). Available items moved no stock here.
    SELECT 'stg_checkout_item', w.stg_id, 'ONLINE', w.source_ref,
           CASE WHEN w.result = 'unavailable' THEN 'checkout_blocked' END,
           CASE WHEN w.result = 'available'
                THEN 'Available at checkout: if paid, its stock movement is loaded from the store reservation' END,
           w.pickup_cp_code, w.item_no, w.quantity, w.attempted_at, 'basket ' || w.basket_id, w.pickup_cp_code
      FROM etl.stg_checkout_item w
     WHERE w.load_status IN ('pending', 'rejected')
)
SELECT st.stg_table,
       st.stg_id,
       st.source_system,
       st.source_ref,
       st.event_type,
       st.skip_reason,
       st.store_source_code,
       st.item_no,
       il.item_no AS product_code,
       sx.store_code,
       dp.product_key,
       ds.store_key,
       pk.store_key AS pickup_store_key,
       dd.date_key,
       st.event_ts,
       st.units,
       st.order_ref,
       CASE st.event_type
           WHEN 'store_sale'        THEN -st.units
           WHEN 'supplier_delivery' THEN  st.units
           WHEN 'reservation'       THEN -st.units
           WHEN 'cancellation'      THEN  st.units
           ELSE 0
       END AS quantity_change,
       CASE st.event_type
           WHEN 'reservation'  THEN  st.units
           WHEN 'transfer_out' THEN -st.units
           WHEN 'transfer_in'  THEN  st.units
           WHEN 'collection'   THEN -st.units
           WHEN 'cancellation' THEN -st.units
           ELSE 0
       END AS reserved_change,
       CASE
           WHEN st.event_type IS NULL       THEN NULL
           WHEN il.item_no IS NULL          THEN format('Unknown item %s: not on the warehouse product list', st.item_no)
           WHEN sx.store_code IS NULL       THEN format('No approved %s store mapping for code %s', st.source_system, st.store_source_code)
           WHEN dp.product_key IS NULL      THEN format('Item %s is not in dim_product yet', st.item_no)
           WHEN ds.store_key IS NULL        THEN format('Store %s is not in dim_store (no STORE mapping)', sx.store_code)
           WHEN st.pickup_source_code IS NOT NULL AND pk.store_key IS NULL
                                            THEN format('No approved %s store mapping for pickup store %s', st.source_system, st.pickup_source_code)
           WHEN st.units IS NULL OR st.units <= 0 THEN 'Quantity must be positive'
           WHEN st.event_ts IS NULL         THEN 'Missing event time'
           WHEN dd.date_key IS NULL         THEN 'Event date outside dim_date'
       END AS reject_reason
  FROM staged st
  LEFT JOIN etl.item_list    il ON il.item_no = st.item_no
  LEFT JOIN etl.store_xref   sx ON sx.source_system = st.source_system AND sx.source_code = st.store_source_code
  LEFT JOIN dw.dim_product   dp ON dp.product_code = il.item_no
  LEFT JOIN dw.dim_store     ds ON ds.store_code = sx.store_code AND ds.channel = 'physical'
  LEFT JOIN etl.store_xref   sx2 ON sx2.source_system = st.source_system AND sx2.source_code = st.pickup_source_code
  LEFT JOIN dw.dim_store     pk ON pk.store_code = sx2.store_code AND pk.channel = 'physical'
  LEFT JOIN dw.dim_date      dd ON dd.full_date = (st.event_ts AT TIME ZONE 'Australia/Sydney')::date;
COMMENT ON VIEW etl.v_transform IS
'Transform and validate step: each staged row still to process, translated into warehouse keys, units and signed quantities, with reject_reason when it cannot be loaded (e.g. an item not on the warehouse product list).';


-- -----------------------------------------------------------------------------
-- 7. LOAD: one ETL pass. Returns the etl_run_id, or NULL if nothing to do.
-- -----------------------------------------------------------------------------
CREATE FUNCTION etl.run_etl(p_trigger text DEFAULT 'manual') RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_run    integer;
    v_table  text;
BEGIN
    -- One ETL pass at a time.
    PERFORM pg_advisory_xact_lock(hashtext('pethaven.etl'));

    IF NOT EXISTS (SELECT 1 FROM etl.v_transform) THEN
        RETURN NULL;
    END IF;

    INSERT INTO etl.etl_run (trigger_source) VALUES (p_trigger)
    RETURNING etl_run_id INTO v_run;

    PERFORM etl.load_dimensions();

    -- Load valid rows in business-time order.
    INSERT INTO dw.fact_stock_event
        (event_type, product_key, store_key, date_key, event_ts,
         quantity_change, reserved_change, units, order_ref, pickup_store_key,
         source_system, source_ref, etl_run_id)
    SELECT event_type, product_key, store_key, date_key, event_ts,
           quantity_change, reserved_change, units, order_ref, pickup_store_key,
           source_system, source_ref, v_run
      FROM etl.v_transform
     WHERE event_type IS NOT NULL AND reject_reason IS NULL
     ORDER BY event_ts, stg_table, stg_id;

    -- Record the outcome on every staged row this pass handled.
    FOREACH v_table IN ARRAY ARRAY['stg_store_sale_line', 'stg_supplier_delivery_line',
                                   'stg_reservation_change', 'stg_checkout_item']
    LOOP
        EXECUTE format(
            'UPDATE etl.%I s
                SET load_status = ''loaded'', note = NULL, event_id = f.event_id,
                    etl_run_id = $1, processed_at = clock_timestamp()
               FROM dw.fact_stock_event f
              WHERE f.source_ref = s.source_ref
                AND s.load_status IN (''pending'', ''rejected'')', v_table)
        USING v_run;

        EXECUTE format(
            'UPDATE etl.%I s
                SET load_status = CASE WHEN v.event_type IS NULL THEN ''skipped'' ELSE ''rejected'' END,
                    note = coalesce(v.reject_reason, v.skip_reason),
                    etl_run_id = $1, processed_at = clock_timestamp()
               FROM etl.v_transform v
              WHERE v.stg_table = %L AND v.stg_id = s.stg_id', v_table, v_table)
        USING v_run;
    END LOOP;

    UPDATE etl.etl_run r
       SET finished_at   = clock_timestamp(),
           rows_read     = c.n_read,
           rows_loaded   = c.n_loaded,
           rows_rejected = c.n_rejected,
           rows_skipped  = c.n_skipped
      FROM (SELECT count(*)                                         AS n_read,
                   count(*) FILTER (WHERE load_status = 'loaded')   AS n_loaded,
                   count(*) FILTER (WHERE load_status = 'rejected') AS n_rejected,
                   count(*) FILTER (WHERE load_status = 'skipped')  AS n_skipped
              FROM etl.v_staging WHERE etl_run_id = v_run) c
     WHERE r.etl_run_id = v_run;

    RETURN v_run;
END;
$$;

-- All staged rows across sources, with their outcome (lineage and data quality).
CREATE VIEW etl.v_staging AS
SELECT 'stg_store_sale_line' AS stg_table, stg_id, 'STORE' AS source_system, source_ref,
       load_status, note, etl_run_id, event_id, captured_at, processed_at
  FROM etl.stg_store_sale_line
UNION ALL
SELECT 'stg_supplier_delivery_line', stg_id, 'SUPPLY', source_ref,
       load_status, note, etl_run_id, event_id, captured_at, processed_at
  FROM etl.stg_supplier_delivery_line
UNION ALL
SELECT 'stg_reservation_change', stg_id, 'STORE', source_ref,
       load_status, note, etl_run_id, event_id, captured_at, processed_at
  FROM etl.stg_reservation_change
UNION ALL
SELECT 'stg_checkout_item', stg_id, 'ONLINE', source_ref,
       load_status, note, etl_run_id, event_id, captured_at, processed_at
  FROM etl.stg_checkout_item;
COMMENT ON VIEW etl.v_staging IS 'Every extracted source record and what the ETL did with it (loaded -> event_id, rejected/skipped -> note).';

CREATE VIEW etl.v_data_quality AS
SELECT source_system, source_ref, note AS reject_reason, captured_at, processed_at AS last_attempt_at
  FROM etl.v_staging
 WHERE load_status = 'rejected';
COMMENT ON VIEW etl.v_data_quality IS 'Source records the warehouse could not load yet, and why. Empty when all source data is integrated.';


-- -----------------------------------------------------------------------------
-- 8. Near-real-time scheduling: run one ETL pass after each source statement.
--    (Row-level extract triggers fire first, then this statement trigger.)
-- -----------------------------------------------------------------------------
CREATE FUNCTION etl.cdc_run_etl() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM etl.run_etl('cdc:' || TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_sale_line_load AFTER INSERT ON store_ops.sale_line
FOR EACH STATEMENT EXECUTE FUNCTION etl.cdc_run_etl();
CREATE TRIGGER trg_supplier_delivery_line_load AFTER INSERT ON supply.supplier_delivery_line
FOR EACH STATEMENT EXECUTE FUNCTION etl.cdc_run_etl();
CREATE TRIGGER trg_reservation_load AFTER INSERT OR UPDATE ON store_ops.reservation
FOR EACH STATEMENT EXECUTE FUNCTION etl.cdc_run_etl();
CREATE TRIGGER trg_checkout_item_load AFTER INSERT ON online.checkout_attempt_item
FOR EACH STATEMENT EXECUTE FUNCTION etl.cdc_run_etl();


-- -----------------------------------------------------------------------------
-- 9. Look-ups for people.
-- -----------------------------------------------------------------------------
-- Every item in any catalogue: one item number, each system's attributes,
-- and whether the warehouse accepts it yet.
CREATE VIEW etl.v_item_list AS
SELECT p.item_no,
       p.description,
       p.category,
       p.barcode,
       i.supplier_id,
       i.units_per_carton,
       o.title                 AS web_title,
       o.item_no IS NOT NULL   AS sold_online,
       l.item_no IS NOT NULL   AS on_product_list,
       l.added_by,
       l.added_at
  FROM store_ops.product p
  LEFT JOIN supply.item    i ON i.item_no = p.item_no
  LEFT JOIN online.product o ON o.item_no = p.item_no
  LEFT JOIN etl.item_list  l ON l.item_no = p.item_no;
COMMENT ON VIEW etl.v_item_list IS
'Each item number with its attributes in every system (store barcode, supplier and units per carton, web title) and whether it is on the warehouse product list.';

CREATE VIEW etl.v_store_codes AS
SELECT d.store_code,
       d.store_name,
       max(x.source_code) FILTER (WHERE x.source_system = 'STORE')  AS store_no,
       max(x.source_code) FILTER (WHERE x.source_system = 'SUPPLY') AS location_code,
       max(x.source_code) FILTER (WHERE x.source_system = 'ONLINE') AS cp_code
  FROM dw.dim_store d
  LEFT JOIN etl.store_xref x ON x.store_code = d.store_code
 WHERE d.channel = 'physical'
 GROUP BY d.store_code, d.store_name;
COMMENT ON VIEW etl.v_store_codes IS 'Each warehouse store with its store code in every source system.';
