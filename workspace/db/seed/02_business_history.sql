-- =============================================================================
-- seed/02_business_history.sql
-- Purpose: A week of realistic trading, created through the source systems'
--          own operations so that every change is extracted, transformed and
--          loaded by the ETL exactly as live activity would be.
-- Design ref: docs/Architecture_and_Data_Model.md section 9.
-- Prerequisites: seed/01_reference_data.sql.
-- Timeline (Sydney time, relative to the day the build runs):
--   7 days ago 07:00  opening stock: one delivery docket per store and supplier
--   7 days ago 08:00  sync #1 - the website gets its first real numbers
--   6..1 days ago     till sales (some multi-item receipts), restock deliveries,
--                     8 online orders (one sourced from another store and
--                     transferred, one 3-item order with 2 lines coming from
--                     another store and still in transit, one shortfall caused
--                     by the stale website number), 2 collections,
--                     1 cancellation, 1 overdue collection
--   now               sync #2 - the "initial" sync for the demo; the website is
--                     correct and nothing is pending
-- The helper functions below translate the warehouse codes used in this file
-- into each source's own codes, so the history reads clearly.
-- =============================================================================

-- Sydney local time N days before today, and the same instant in UTC
-- (the delivery system records UTC).
CREATE FUNCTION pg_temp.ts(days_ago integer, hhmm text) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
    SELECT ((current_date - days_ago) + hhmm::time) AT TIME ZONE 'Australia/Sydney';
$$;
CREATE FUNCTION pg_temp.utc(days_ago integer, hhmm text) RETURNS timestamp
LANGUAGE sql STABLE AS $$
    SELECT pg_temp.ts(days_ago, hhmm) AT TIME ZONE 'UTC';
$$;

-- Product code -> store barcode / supplier SKU / web SKU.
CREATE FUNCTION pg_temp.bc(p_codes text[]) RETURNS text[]
LANGUAGE sql STABLE AS $$
    SELECT array_agg(x.source_code ORDER BY c.n)
      FROM unnest(p_codes) WITH ORDINALITY AS c (code, n)
      JOIN etl.product_xref x ON x.product_code = c.code AND x.source_system = 'STORE';
$$;
CREATE FUNCTION pg_temp.sku(p_codes text[]) RETURNS text[]
LANGUAGE sql STABLE AS $$
    SELECT array_agg(x.source_code ORDER BY c.n)
      FROM unnest(p_codes) WITH ORDINALITY AS c (code, n)
      JOIN etl.product_xref x ON x.product_code = c.code AND x.source_system = 'SUPPLY';
$$;
CREATE FUNCTION pg_temp.web(p_code text) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT source_code FROM etl.product_xref WHERE product_code = p_code AND source_system = 'ONLINE';
$$;


-- ---------------------------------------------------------------------------
-- 7 days ago 07:00: opening stock in CARTONS.
-- Columns: product, Parramatta, Bondi, Chatswood, Newtown, Penrith.
-- (P001 at Parramatta: 10 cartons x 4 = 40 units.)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE opening_cartons (product_code text, s01 int, s02 int, s03 int, s04 int, s05 int);
INSERT INTO opening_cartons VALUES
    ('P001', 10, 7, 9, 5, 12),
    ('P002',  4, 3, 5, 2,  6),
    ('P003',  6, 7, 5, 8,  4),
    ('P004',  3, 4, 3, 5,  2),
    ('P005',  5, 3, 4, 3,  5),
    ('P006',  5, 4, 5, 3,  6),
    ('P007',  2, 3, 1, 3,  2),
    ('P008',  4, 3, 3, 2,  4),
    ('P009',  4, 3, 4, 2,  3),
    ('P010',  3, 3, 2, 4,  2),
    ('P011',  2, 2, 3, 1,  2),
    ('P012',  2, 2, 3, 1,  2),
    ('P013',  2, 1, 3, 1,  1),
    ('P014',  8, 5, 6, 9,  7),
    ('P015',  4, 3, 3, 3,  4),
    ('P016',  2, 1, 2, 1,  2),
    ('P017',  4, 3, 5, 2,  6),
    ('P018',  2, 1, 2, 1,  1);

DO $$
DECLARE
    d record;
BEGIN
    -- One docket per delivery location and supplier.
    FOR d IN
        SELECT loc.location_code,
               CASE left(x.source_code, 2)
                   WHEN 'PF' THEN 'Pawfect Foods'
                   WHEN 'PP' THEN 'PlayPets Wholesale'
                   WHEN 'PG' THEN 'PetGear Supply Co'
                   WHEN 'VC' THEN 'VetCare Distributors'
                   WHEN 'AW' THEN 'AquaWorld Supplies'
               END                                         AS supplier_name,
               array_agg(x.source_code ORDER BY o.product_code) AS skus,
               array_agg(c.cartons     ORDER BY o.product_code) AS cartons
          FROM opening_cartons o
         CROSS JOIN LATERAL (VALUES ('S01', o.s01), ('S02', o.s02), ('S03', o.s03),
                                    ('S04', o.s04), ('S05', o.s05)) AS c (store_code, cartons)
          JOIN etl.product_xref x ON x.product_code = o.product_code AND x.source_system = 'SUPPLY'
          JOIN etl.store_xref loc_x ON loc_x.store_code = c.store_code AND loc_x.source_system = 'SUPPLY'
          JOIN supply.location loc ON loc.location_code = loc_x.source_code
         GROUP BY loc.location_code, 2
         ORDER BY loc.location_code, 2
    LOOP
        PERFORM supply.record_delivery(d.location_code, d.supplier_name, d.skus, d.cartons,
                                       pg_temp.utc(7, '07:00'));
    END LOOP;
END;
$$;
DROP TABLE opening_cartons;

-- 7 days ago 08:00: first sync, so the website starts with real numbers.
SELECT dw.run_sync(pg_temp.ts(7, '08:00'));


-- ---------------------------------------------------------------------------
-- 6 days ago
-- ---------------------------------------------------------------------------
SELECT store_ops.record_sale('101', pg_temp.bc('{P001,P012}'),      '{2,1}', pg_temp.ts(6, '09:42'));
SELECT store_ops.record_sale('102', pg_temp.bc('{P003}'),           '{3}',   pg_temp.ts(6, '10:15'));
SELECT store_ops.record_sale('104', pg_temp.bc('{P007}'),           '{2}',   pg_temp.ts(6, '11:30'));
SELECT store_ops.record_sale('103', pg_temp.bc('{P005,P010}'),      '{4,2}', pg_temp.ts(6, '13:05'));
SELECT store_ops.record_sale('105', pg_temp.bc('{P014}'),           '{2}',   pg_temp.ts(6, '15:48'));

-- ---------------------------------------------------------------------------
-- 5 days ago
-- ---------------------------------------------------------------------------
SELECT store_ops.record_sale('101', pg_temp.bc('{P005}'),           '{3}',   pg_temp.ts(5, '09:20'));
SELECT store_ops.record_sale('102', pg_temp.bc('{P009,P010}'),      '{2,1}', pg_temp.ts(5, '10:55'));
SELECT store_ops.record_sale('103', pg_temp.bc('{P001}'),           '{3}',   pg_temp.ts(5, '12:10'));
SELECT store_ops.record_sale('104', pg_temp.bc('{P004,P011}'),      '{2,1}', pg_temp.ts(5, '14:25'));
SELECT store_ops.record_sale('105', pg_temp.bc('{P002,P008}'),      '{1,2}', pg_temp.ts(5, '16:40'));

SELECT online.place_online_order('2000', pg_temp.web('P003'), 2, pg_temp.ts(5, '19:12'));  -- #1 CBD -> Bondi Junction (closest)
SELECT online.place_online_order('2112', pg_temp.web('P006'), 1, pg_temp.ts(5, '20:30'));  -- #2 Ryde -> Chatswood

-- ---------------------------------------------------------------------------
-- 4 days ago
-- ---------------------------------------------------------------------------
SELECT supply.record_delivery('NSW-BONDI', 'Pawfect Foods',        pg_temp.sku('{P003}'), '{4}', pg_temp.utc(4, '06:30'));
SELECT supply.record_delivery('NSW-NEWTN', 'Pawfect Foods',        pg_temp.sku('{P002}'), '{3}', pg_temp.utc(4, '06:45'));
SELECT supply.record_delivery('NSW-PARRA', 'VetCare Distributors', pg_temp.sku('{P016}'), '{1}', pg_temp.utc(4, '07:10'));

SELECT store_ops.record_sale('101', pg_temp.bc('{P003}'),           '{3}',   pg_temp.ts(4, '10:05'));
SELECT store_ops.record_sale('102', pg_temp.bc('{P001}'),           '{1}',   pg_temp.ts(4, '11:20'));
SELECT store_ops.record_sale('103', pg_temp.bc('{P017}'),           '{1}',   pg_temp.ts(4, '12:45'));
SELECT store_ops.record_sale('104', pg_temp.bc('{P003,P009}'),      '{4,1}', pg_temp.ts(4, '15:15'));
SELECT store_ops.record_sale('105', pg_temp.bc('{P001,P006}'),      '{2,2}', pg_temp.ts(4, '17:30'));

SELECT store_ops.collect_order('1', pg_temp.ts(4, '18:00'));                               -- #1 collected

-- #3 Penrith customer wants 2 dog beds: Penrith (the pickup store) has 1, so
-- the beds are taken from the next-nearest store with 2 (Parramatta) and
-- transferred to Penrith. They arrive, but are never collected, so the order
-- shows as overdue in the open reservations report.
SELECT online.place_online_order('2750', pg_temp.web('P013'), 2, pg_temp.ts(4, '19:05'));
SELECT store_ops.dispatch_order_transfers('3', pg_temp.ts(3, '08:30'));
SELECT store_ops.receive_order_transfers('3', pg_temp.ts(3, '11:45'));

-- ---------------------------------------------------------------------------
-- 3 days ago: the aquarium kit sells out at three stores (website still says 7)
-- ---------------------------------------------------------------------------
SELECT store_ops.record_sale('101', pg_temp.bc('{P018}'),           '{2}',   pg_temp.ts(3, '10:10'));
SELECT store_ops.record_sale('103', pg_temp.bc('{P018}'),           '{2}',   pg_temp.ts(3, '11:35'));
SELECT store_ops.record_sale('102', pg_temp.bc('{P018}'),           '{1}',   pg_temp.ts(3, '13:50'));
SELECT store_ops.record_sale('104', pg_temp.bc('{P011}'),           '{1}',   pg_temp.ts(3, '14:20'));
SELECT store_ops.record_sale('105', pg_temp.bc('{P008}'),           '{2}',   pg_temp.ts(3, '16:05'));

SELECT online.place_online_order('2026', pg_temp.web('P012'), 1, pg_temp.ts(3, '20:05'));  -- #4 Bondi -> Bondi Junction

-- ---------------------------------------------------------------------------
-- 2 days ago
-- ---------------------------------------------------------------------------
-- #5 Bondi customer orders 3 aquarium kits. The website (stale) says 7, but
-- only 2 are left in total -> shortfall at the nearest store (Bondi).
SELECT online.place_online_order('2026', pg_temp.web('P018'), 3, pg_temp.ts(2, '09:15'));

SELECT store_ops.record_sale('101', pg_temp.bc('{P002}'),           '{2}',   pg_temp.ts(2, '10:30'));
SELECT store_ops.record_sale('102', pg_temp.bc('{P015}'),           '{1}',   pg_temp.ts(2, '11:45'));
SELECT store_ops.record_sale('103', pg_temp.bc('{P014}'),           '{2}',   pg_temp.ts(2, '13:00'));
SELECT store_ops.record_sale('104', pg_temp.bc('{P005}'),           '{3}',   pg_temp.ts(2, '15:30'));
SELECT store_ops.record_sale('105', pg_temp.bc('{P016}'),           '{1}',   pg_temp.ts(2, '16:50'));

SELECT store_ops.collect_order('2', pg_temp.ts(2, '17:00'));                               -- #2 collected

-- ---------------------------------------------------------------------------
-- 1 day ago
-- ---------------------------------------------------------------------------
SELECT supply.record_delivery('NSW-CHATS', 'Pawfect Foods',        pg_temp.sku('{P001}'), '{5}', pg_temp.utc(1, '06:20'));
SELECT supply.record_delivery('NSW-PENRI', 'VetCare Distributors', pg_temp.sku('{P014}'), '{3}', pg_temp.utc(1, '06:50'));

SELECT store_ops.record_sale('101', pg_temp.bc('{P001,P006}'),      '{1,1}', pg_temp.ts(1, '09:35'));
SELECT store_ops.cancel_order('4', 'Customer cancelled', pg_temp.ts(1, '10:00'));         -- #4 cancelled

-- #6 Bondi customer orders 3 different items, collected at
-- Bondi Junction: the cat food is at Bondi; the dog beds and the scratching
-- posts are not, so both come from Chatswood. They were sent this afternoon
-- and are still in transit, so the order is not ready yet.
SELECT online.place_online_order('2026', ARRAY[pg_temp.web('P003'), pg_temp.web('P013'), pg_temp.web('P017')],
                                 ARRAY[2, 2, 4], pg_temp.ts(1, '11:05'));
SELECT store_ops.dispatch_order_transfers('6', pg_temp.ts(1, '15:30'));
SELECT store_ops.record_sale('103', pg_temp.bc('{P010}'),           '{2}',   pg_temp.ts(1, '12:15'));
SELECT store_ops.record_sale('104', pg_temp.bc('{P007}'),           '{1}',   pg_temp.ts(1, '14:05'));

SELECT online.place_online_order('2067', pg_temp.web('P004'), 2, pg_temp.ts(1, '19:45'));  -- #7 Chatswood
SELECT online.place_online_order('2170', pg_temp.web('P008'), 1, pg_temp.ts(1, '21:10'));  -- #8 Liverpool -> Parramatta


-- ---------------------------------------------------------------------------
-- Now: initial sync for the demo. Website numbers become correct.
-- ---------------------------------------------------------------------------
SELECT dw.run_sync();
