-- =============================================================================
-- 05_warehouse.sql
-- Purpose: The integrated data warehouse (star schema plus online sync log).
-- Design ref: docs/Architecture_and_Data_Model.md section 6.
-- Prerequisites: 01_schemas.sql.
-- Outputs: dim_product, dim_store, dim_date (populated), fact_stock_event,
--          sync_run, sync_change, indexes.
-- Keys: every dimension has a warehouse surrogate key (integer) and a
--       conformed business code (P001, S01) that belongs to the warehouse,
--       not to any source. etl.product_xref / etl.store_xref map each
--       source's own codes to these conformed codes.
-- =============================================================================

CREATE TABLE dw.dim_product (
    product_key   integer       GENERATED ALWAYS AS IDENTITY,
    product_code  text          NOT NULL,
    product_name  text          NOT NULL,
    category      text          NOT NULL,
    unit_price    numeric(10,2) NOT NULL,
    CONSTRAINT pk_dim_product PRIMARY KEY (product_key),
    CONSTRAINT uq_dim_product_code UNIQUE (product_code)
);
COMMENT ON TABLE dw.dim_product IS
'Conformed product dimension, one row per product. Attributes come from the store catalogue (system of record), overwritten on change (SCD type 1).';

CREATE TABLE dw.dim_store (
    store_key   integer GENERATED ALWAYS AS IDENTITY,
    store_code  text    NOT NULL,
    store_name  text    NOT NULL,
    channel     text    NOT NULL,
    suburb      text,
    postcode    text,
    CONSTRAINT pk_dim_store PRIMARY KEY (store_key),
    CONSTRAINT uq_dim_store_code UNIQUE (store_code),
    CONSTRAINT ck_dim_store_channel CHECK (channel IN ('physical', 'online'))
);
COMMENT ON TABLE dw.dim_store IS
'Conformed store dimension: the 5 physical stores (S01-S05) plus ONLINE for the online channel. Stock events always belong to a physical store; ONLINE labels the website number in the sync log.';

CREATE TABLE dw.dim_date (
    date_key      integer NOT NULL,
    full_date     date    NOT NULL,
    day_of_month  integer NOT NULL,
    day_name      text    NOT NULL,
    is_weekend    boolean NOT NULL,
    week_of_year  integer NOT NULL,
    month_number  integer NOT NULL,
    month_name    text    NOT NULL,
    quarter       integer NOT NULL,
    year          integer NOT NULL,
    CONSTRAINT pk_dim_date PRIMARY KEY (date_key),
    CONSTRAINT uq_dim_date_full_date UNIQUE (full_date)
);
COMMENT ON TABLE dw.dim_date IS 'Calendar dimension, date_key = YYYYMMDD (Sydney business date). Covers 2020-2035.';

INSERT INTO dw.dim_date
SELECT to_char(d, 'YYYYMMDD')::integer,
       d::date,
       extract(day FROM d)::integer,
       trim(to_char(d, 'Day')),
       extract(isodow FROM d) IN (6, 7),
       extract(week FROM d)::integer,
       extract(month FROM d)::integer,
       trim(to_char(d, 'Month')),
       extract(quarter FROM d)::integer,
       extract(year FROM d)::integer
  FROM generate_series(date '2020-01-01', date '2035-12-31', interval '1 day') AS d;

CREATE TABLE dw.fact_stock_event (
    event_id         bigint      GENERATED ALWAYS AS IDENTITY,
    event_type       text        NOT NULL,
    product_key      integer     NOT NULL,
    store_key        integer     NOT NULL,
    date_key         integer     NOT NULL,
    event_ts         timestamptz NOT NULL,
    quantity_change  integer     NOT NULL,
    reserved_change  integer     NOT NULL,
    units            integer     NOT NULL,
    order_ref        text,
    pickup_store_key integer,
    source_system    text        NOT NULL,
    source_ref       text        NOT NULL,
    etl_run_id       integer     NOT NULL,
    loaded_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pk_fact_stock_event PRIMARY KEY (event_id),
    CONSTRAINT fk_fact_product FOREIGN KEY (product_key) REFERENCES dw.dim_product (product_key),
    CONSTRAINT fk_fact_store FOREIGN KEY (store_key) REFERENCES dw.dim_store (store_key),
    CONSTRAINT fk_fact_date FOREIGN KEY (date_key) REFERENCES dw.dim_date (date_key),
    CONSTRAINT fk_fact_pickup_store FOREIGN KEY (pickup_store_key) REFERENCES dw.dim_store (store_key),
    -- Online order events carry the order and its pickup store; others carry neither.
    CONSTRAINT ck_fact_order_context CHECK ((order_ref IS NULL) = (pickup_store_key IS NULL)),
    CONSTRAINT uq_fact_source_ref UNIQUE (source_ref),
    CONSTRAINT ck_fact_units CHECK (units > 0),
    CONSTRAINT ck_fact_source_system CHECK (source_system IN ('STORE', 'SUPPLY', 'ONLINE')),
    -- Each event type has a fixed effect on the store's two quantities.
    CONSTRAINT ck_fact_signs CHECK (
           (event_type = 'store_sale'   AND quantity_change = -units AND reserved_change = 0      AND order_ref IS NULL)
        OR (event_type = 'delivery'     AND quantity_change =  units AND reserved_change = 0      AND order_ref IS NULL)
        OR (event_type = 'reservation'  AND quantity_change = -units AND reserved_change =  units AND order_ref IS NOT NULL)
        OR (event_type = 'transfer_out' AND quantity_change = 0      AND reserved_change = -units AND order_ref IS NOT NULL)
        OR (event_type = 'transfer_in'  AND quantity_change = 0      AND reserved_change =  units AND order_ref IS NOT NULL)
        OR (event_type = 'collection'   AND quantity_change = 0      AND reserved_change = -units AND order_ref IS NOT NULL)
        OR (event_type = 'cancellation' AND quantity_change =  units AND reserved_change = -units AND order_ref IS NOT NULL)
        OR (event_type = 'shortfall'    AND quantity_change = 0      AND reserved_change = 0      AND order_ref IS NOT NULL)
    )
);
COMMENT ON TABLE dw.fact_stock_event IS
'Grain: one stock-changing event for one product at one physical store. Transaction fact table and the single history that every report and the sync read from. Summing quantity_change / reserved_change per store and product gives that store''s in-store / reserved stock.';
COMMENT ON COLUMN dw.fact_stock_event.event_type IS 'store_sale, delivery, reservation, transfer_out, transfer_in, collection, cancellation or shortfall.';
COMMENT ON COLUMN dw.fact_stock_event.quantity_change IS 'Signed change to in-store (shelf) stock.';
COMMENT ON COLUMN dw.fact_stock_event.reserved_change IS 'Signed change to reserved stock (held for an online order, at the pickup store or waiting to be sent there). Units in transit between stores are in no store.';
COMMENT ON COLUMN dw.fact_stock_event.units IS 'Units involved, always positive. For a shortfall: units ordered that no store could supply.';
COMMENT ON COLUMN dw.fact_stock_event.order_ref IS 'Degenerate dimension: online order number for every online order event (reservation, transfer_out, transfer_in, collection, cancellation, shortfall).';
COMMENT ON COLUMN dw.fact_stock_event.store_key IS 'Store where the stock changed. For a shortfall: the pickup store the order was meant to be collected from.';
COMMENT ON COLUMN dw.fact_stock_event.pickup_store_key IS 'Role-playing store dimension: the store where the customer collects the order. Differs from store_key when the stock comes from another store and is transferred.';
COMMENT ON COLUMN dw.fact_stock_event.source_ref IS 'Lineage: source system and record, e.g. STORE:sale 12 line 1. Unique, so a source record is never loaded twice.';
COMMENT ON COLUMN dw.fact_stock_event.etl_run_id IS 'ETL run that loaded this row (etl.etl_run).';

CREATE INDEX ix_fact_product_store ON dw.fact_stock_event (product_key, store_key);
CREATE INDEX ix_fact_date ON dw.fact_stock_event (date_key);
CREATE INDEX ix_fact_type ON dw.fact_stock_event (event_type);
CREATE INDEX ix_fact_order_ref ON dw.fact_stock_event (order_ref) WHERE order_ref IS NOT NULL;

CREATE TABLE dw.sync_run (
    sync_id           integer     GENERATED ALWAYS AS IDENTITY,
    run_at            timestamptz NOT NULL,
    from_event_id     bigint      NOT NULL,
    to_event_id       bigint      NOT NULL,
    events_processed  integer     NOT NULL,
    numbers_changed   integer     NOT NULL,
    store_mismatches  integer     NOT NULL,
    CONSTRAINT pk_sync_run PRIMARY KEY (sync_id),
    CONSTRAINT ck_sync_run_window CHECK (to_event_id >= from_event_id)
);
COMMENT ON TABLE dw.sync_run IS
'One row per manual sync. It processed fact events with from_event_id < event_id <= to_event_id.';
COMMENT ON COLUMN dw.sync_run.numbers_changed IS 'Store and online numbers this sync changed (rows in sync_change with changed = true).';
COMMENT ON COLUMN dw.sync_run.store_mismatches IS 'Reconciliation: store/product pairs where the warehouse differs from the live store system (see dw.rpt_reconciliation). Expected 0.';

CREATE TABLE dw.sync_change (
    sync_id      integer NOT NULL,
    product_key  integer NOT NULL,
    store_key    integer NOT NULL,
    measure      text    NOT NULL,
    before_qty   integer NOT NULL,
    after_qty    integer NOT NULL,
    changed      boolean GENERATED ALWAYS AS (before_qty <> after_qty) STORED,
    CONSTRAINT pk_sync_change PRIMARY KEY (sync_id, product_key, store_key, measure),
    CONSTRAINT fk_sync_change_run FOREIGN KEY (sync_id) REFERENCES dw.sync_run (sync_id),
    CONSTRAINT fk_sync_change_product FOREIGN KEY (product_key) REFERENCES dw.dim_product (product_key),
    CONSTRAINT fk_sync_change_store FOREIGN KEY (store_key) REFERENCES dw.dim_store (store_key),
    CONSTRAINT ck_sync_change_measure CHECK (measure IN ('in_store', 'reserved', 'online_available'))
);
COMMENT ON TABLE dw.sync_change IS
'Before/after of each number a sync recalculated. Store measures are logged when the sync window touched them; online_available is logged for every online product on every sync.';
