-- =============================================================================
-- 01_schemas.sql
-- Purpose: Create the five PetHaven schemas: three operational source
--          systems, the ETL layer and the integrated data warehouse.
-- Design ref: docs/Architecture_and_Data_Model.md section 2.
-- Prerequisites: An empty database (scripts/build.py creates one).
-- Rerun behaviour: Not rerunnable; build.py recreates the database from empty.
-- =============================================================================

-- Each source stands for a separate operational system with its own codes.
-- The lab hosts them as separate schemas in one PostgreSQL database.
CREATE SCHEMA store_ops;   -- Source 1: store system (POS tills + store stock), 5 stores
CREATE SCHEMA supply;      -- Source 2: supplier delivery system
CREATE SCHEMA online;      -- Source 3: online store

-- Integration layers. Not business sources.
CREATE SCHEMA etl;         -- staging (extracted rows), code cross-references, ETL run log
CREATE SCHEMA dw;          -- integrated data warehouse: star schema, sync log, reports

COMMENT ON SCHEMA store_ops IS
'Source 1 - store system. Stores (store number), product catalogue (EAN-13 barcode), live stock per store (in-store and reserved), till sales and click-and-collect reservations.';
COMMENT ON SCHEMA supply IS
'Source 2 - supplier delivery system. Supplier delivery locations (location code), supplier items (supplier SKU, cartons) and supplier deliveries recorded in cartons with UTC timestamps.';
COMMENT ON SCHEMA online IS
'Source 3 - online store. Web catalogue (web SKU), one combined available quantity per product, collection points, customer postcodes and online orders.';
COMMENT ON SCHEMA etl IS
'ETL layer. Staging tables hold each source change in its source format (extract); the approved cross-reference tables map source codes to warehouse codes (transform); run log and rejected rows give lineage and data quality.';
COMMENT ON SCHEMA dw IS
'Integrated data warehouse. Conformed product, store and date dimensions, one fact table of every stock-changing event, the online sync log and the report views.';
