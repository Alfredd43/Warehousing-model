-- ============================================================================
-- PetHaven | Demo Sections 3 & 4 | CloudBeaver / PostgreSQL 15
-- Verified against GitHub main: 03_supply.sql, 05_warehouse.sql, 06_etl.sql,
-- 08_reports.sql and demo/vedio_demo_script.sql (checked 2026-10-11).
-- Connection: database pethaven_demo (NOT lab / pethaven_check).
-- Run each SELECT separately (highlight statement, Ctrl+Enter).
-- All statements below are READ-ONLY and safe to repeat.
-- ============================================================================

-- 00 | CHECK CONNECTION ------------------------------------------------------
SELECT current_database() AS connected_database;
-- Expected: pethaven_demo. If not, change the CloudBeaver connection.

-- SECTION 3 | ETL: SOURCE -> STAGING -> TRANSFORMATION -----------------------

-- 3.1 | SOURCE: supplier deliveries are recorded in CARTONS and UTC.
-- Use the latest actual delivery line; no hard-coded delivery ID.
SELECT d.delivery_no,
       d.supplier_id,
       d.supplier_order_no,
       d.location_code AS supplier_location_code,
       l.item_no,
       l.cartons,
       i.units_per_carton,
       d.delivered_at_utc
FROM supply.supplier_delivery d
JOIN supply.supplier_delivery_line l ON l.delivery_no = d.delivery_no
JOIN supply.item i ON i.item_no = l.item_no
ORDER BY d.delivery_no DESC, l.line_no
LIMIT 10;

-- 3.2 | STAGING: source format retained, plus status and traceability.
SELECT stg_id,
       supplier_id,
       supplier_order_no,
       location_code AS original_location,
       item_no,
       cartons,
       units_per_carton,
       delivered_at_utc AS original_utc,
       load_status,
       event_id AS loaded_dw_event_id,
       source_ref
FROM etl.stg_supplier_delivery_line
ORDER BY stg_id DESC
LIMIT 10;

-- 3.3 | TRANSFORMATION PROOF: side-by-side BEFORE / AFTER for actual rows.
-- IMPORTANT: etl.v_transform includes only PENDING / REJECTED rows.
-- Successfully loaded rows have left that view; this query reconstructs the
-- same documented conversion rules using the stored staging values.
SELECT s.supplier_order_no,
       s.item_no,
       s.cartons AS source_cartons,
       s.units_per_carton,
       (s.cartons * s.units_per_carton) AS transformed_units,
       s.location_code AS source_location_code,
       x.store_code AS mapped_dw_store_code,
       s.delivered_at_utc AS source_time_utc,
       (s.delivered_at_utc AT TIME ZONE 'UTC'
          AT TIME ZONE 'Australia/Sydney') AS sydney_local_time,
       s.load_status,
       s.event_id AS dw_event_id
FROM etl.stg_supplier_delivery_line s
LEFT JOIN etl.store_xref x
       ON x.source_system = 'SUPPLY' AND x.source_code = s.location_code
ORDER BY s.stg_id DESC
LIMIT 10;

-- 3.4 | APPROVED MAPPING: three operational location codes -> one DW store.
SELECT store_code, store_name, store_no, location_code, cp_code
FROM etl.v_store_codes
ORDER BY store_code;

-- 3.5 | ETL AUDIT: source changes trigger near-real-time ETL automatically.
SELECT etl_run_id,
       trigger_source,
       started_at,
       finished_at,
       rows_read,
       rows_loaded,
       rows_rejected,
       rows_skipped
FROM etl.etl_run
ORDER BY etl_run_id DESC
LIMIT 10;

-- OPTIONAL | View only rows still pending/rejected (often ZERO after build).
-- Do not use this as the main before/after demo: successful rows disappear.
SELECT stg_table, source_system, item_no, store_source_code,
       store_code, units, quantity_change, reject_reason
FROM etl.v_transform
LIMIT 10;

-- SECTION 4 | INTEGRATED DATA WAREHOUSE -------------------------------------

-- 4.1 | WAREHOUSE FACT: events from multiple operational systems share a model.
SELECT f.event_id,
       f.source_system,
       f.event_type,
       ds.store_code,
       ds.store_name,
       dp.product_code,
       dp.product_name,
       f.quantity_change AS shelf_change,
       f.reserved_change,
       f.units,
       f.event_ts AT TIME ZONE 'Australia/Sydney' AS event_time_sydney,
       f.source_ref
FROM dw.fact_stock_event f
JOIN dw.dim_store ds ON ds.store_key = f.store_key
JOIN dw.dim_product dp ON dp.product_key = f.product_key
ORDER BY f.event_id DESC
LIMIT 25;

-- 4.2 | SUPPLIER LINEAGE: exact source -> staging -> DW row, same source_ref.
SELECT s.supplier_order_no,
       s.item_no AS source_item,
       s.cartons AS source_cartons,
       (s.cartons * s.units_per_carton) AS expected_units,
       s.location_code AS source_location,
       ds.store_code AS dw_store,
       f.event_id,
       f.event_type,
       f.units AS dw_units,
       f.quantity_change AS dw_shelf_change,
       f.source_system,
       f.source_ref,
       s.load_status
FROM etl.stg_supplier_delivery_line s
LEFT JOIN dw.fact_stock_event f ON f.event_id = s.event_id
LEFT JOIN dw.dim_store ds ON ds.store_key = f.store_key
ORDER BY s.stg_id DESC
LIMIT 10;

-- 4.3 | CROSS-SYSTEM INTEGRATION: event counts by source in ONE fact table.
SELECT source_system,
       event_type,
       count(*) AS event_count
FROM dw.fact_stock_event
GROUP BY source_system, event_type
ORDER BY source_system, event_type;

-- 4.4 | DIMENSIONAL MODEL: conformed product + store + date keys.
SELECT f.event_id,
       dp.product_code,
       ds.store_code,
       dd.full_date AS sydney_business_date,
       f.event_type,
       f.quantity_change,
       f.reserved_change
FROM dw.fact_stock_event f
JOIN dw.dim_product dp ON dp.product_key = f.product_key
JOIN dw.dim_store ds ON ds.store_key = f.store_key
JOIN dw.dim_date dd ON dd.date_key = f.date_key
ORDER BY f.event_id DESC
LIMIT 15;

-- 4.5 | BUSINESS-FACING REPORT: integrated stock by store and product.
-- 'in_store_quantity' = shelf/available-to-sell units in this model.
-- 'reserved_quantity' = separately held units (already removed from shelf).
-- DO NOT calculate available as in_store_quantity - reserved_quantity.
SELECT store_code,
       store_name,
       product_code,
       product_name,
       in_store_quantity AS shelf_available_units,
       reserved_quantity AS reserved_units,
       total_on_hand,
       low_stock
FROM dw.rpt_current_stock_by_store
WHERE product_code = 'P001'
ORDER BY in_store_quantity ASC, store_code;

-- 4.6 | OPTIONAL: reconciliation against the live store source.
SELECT *
FROM dw.rpt_reconciliation
LIMIT 15;

-- 4.7 | OPTIONAL: rejected records, if any.
SELECT source_system, source_ref, reject_reason, captured_at
FROM etl.v_data_quality
LIMIT 15;

-- ============================================================================
-- PRESENTER'S RECOMMENDED PATH (2–2.5 minutes):
--   3.1 Supplier source -> 3.2 Staging -> 3.3 Before/After -> 3.4 Store mapping
--   -> 4.2 Source-to-DW lineage -> 4.1 Integrated events -> 4.5 Stock report
--   -> Dashboard Q1/Q4/Q2/Q3.
--
-- ACCURACY NOTES:
-- * Supplier delivery operational trigger also updates store stock immediately.
--   ETL separately captures and loads the supplier event for analytics.
-- * ETL auto-runs on source statements. A read-only demo needs no manual ETL.
-- * The model shares product item numbers (P001 etc.) across sources;
--   store/location codes are mapped, not product SKUs.
-- * All three source systems feed the ETL, but online events in the stock fact
--   are mainly blocked checkout attempts; online sync logs are separate.
-- * No SQL here has been executed against your local pethaven_demo database.
-- ============================================================================
