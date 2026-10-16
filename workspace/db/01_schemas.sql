-- =============================================================================
-- 01_schemas.sql
-- Purpose: Create the five PetHaven schemas: three operational source
--          systems, the ETL layer and the integrated data warehouse.
-- Design ref: docs/Architecture_and_Data_Model.md section 2.
-- Prerequisites: An empty database (scripts/build.py creates one).
-- Rerun behaviour: Not rerunnable; build.py recreates the database from empty.
--
-- Medallion view of the layers (naming only; the schema names stay the same):
--   SOURCES  store_ops, supply, online   operational systems (not a layer)
--   BRONZE   etl.stg_*                    source records as captured, in their
--                                         source format (cartons, UTC, source
--                                         codes) with source_ref and load status
--   SILVER   etl validation + transform   product list check, approved store-code
--                                         mapping, cartons -> units, UTC -> Sydney;
--                                         rejects in etl.v_data_quality. Applied
--                                         during the load, not stored as a
--                                         separate table.
--   GOLD     dw                           star schema (fact_stock_event + dims),
--                                         sync log and rpt_* report views read
--                                         by the dashboard
-- =============================================================================

-- Each source stands for a separate operational system. All three use the
-- same item number (P001) for a product; each has its own store codes and
-- its own transaction ID (receipt number, supplier order number, order ID).
-- The lab hosts them as separate schemas in one PostgreSQL database.
CREATE SCHEMA store_ops;   -- Source 1: store system (POS tills + store stock), 5 stores
CREATE SCHEMA supply;      -- Source 2: supplier delivery system
CREATE SCHEMA online;      -- Source 3: online store

-- Integration layers. Not business sources.
CREATE SCHEMA etl;         -- BRONZE + SILVER: staging (extracted rows), product list, store-code mapping, ETL run log
CREATE SCHEMA dw;          -- GOLD: integrated data warehouse: star schema, sync log, reports

COMMENT ON SCHEMA store_ops IS
'Source 1 - store system. Stores (store number), product catalogue (item number, with the EAN-13 barcode as an attribute), live stock per store (in-store and reserved), till sales (receipt number) and click-and-collect reservations (order ID).';
COMMENT ON SCHEMA supply IS
'Source 2 - supplier delivery system. Suppliers (supplier ID), supplier delivery locations (location code), items (item number, units per carton) and supplier deliveries (supplier order number) recorded in cartons with UTC timestamps.';
COMMENT ON SCHEMA online IS
'Source 3 - online store. Web catalogue (item number), one combined available quantity per product, collection points, customer postcodes, online orders (order ID), the website sync log and the sync scheduler''s registration.';
COMMENT ON SCHEMA etl IS
'ETL layer. Staging tables hold each source change in its source format (extract); the warehouse product list and the approved store-code mapping are used to transform it; run log and rejected rows give lineage and data quality.';
COMMENT ON SCHEMA dw IS
'Integrated data warehouse. Conformed product, store and date dimensions, one fact table of every stock-changing event, the online sync log and the report views.';
