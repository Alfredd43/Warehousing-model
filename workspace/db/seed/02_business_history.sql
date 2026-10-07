-- =============================================================================
-- seed/02_business_history.sql
-- Purpose: A week of realistic trading, created through the source systems'
--          own operations so that every change is extracted, transformed and
--          loaded by the ETL exactly as live activity would be.
-- Design ref: docs/Architecture_and_Data_Model.md section 9.
-- Prerequisites: seed/01_reference_data.sql.
-- Timeline (Sydney time, relative to the day the build runs):
--   7 days ago 07:00  opening stock: one supplier delivery docket per store and supplier
--   7 days ago 08:00  sync #1 - the website gets its first real numbers
--   6..1 days ago     till sales (some multi-item receipts), restock supplier deliveries,
--                     7 paid online orders (one 3-item order collected at
--                     the customer's chosen store with 2 items coming from
--                     another store and still in transit), 1 checkout
--                     blocked before payment because the website number was
--                     stale, 2 collections, 1 cancellation, 1 overdue collection
--   now               sync #2 - the "initial" sync for the demo; the website is
--                     correct and nothing is pending
-- Products are given by item number, which every system shares. Stores are
-- given in each system's own store code (store 101, NSW-PARRA, ...).
-- =============================================================================

-- Sydney local time N days before today, and the same instant in UTC
-- (the supplier delivery system records UTC).
CREATE FUNCTION pg_temp.ts(days_ago integer, hhmm text) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
    SELECT ((current_date - days_ago) + hhmm::time) AT TIME ZONE 'Australia/Sydney';
$$;
CREATE FUNCTION pg_temp.utc(days_ago integer, hhmm text) RETURNS timestamp
LANGUAGE sql STABLE AS $$
    SELECT pg_temp.ts(days_ago, hhmm) AT TIME ZONE 'UTC';
$$;


-- ---------------------------------------------------------------------------
-- 7 days ago 07:00: opening stock in CARTONS, one supplier order per store
-- and supplier (supplier order numbers PO-1001 onwards).
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
    d     record;
    v_po  integer := 1000;
BEGIN
    -- One docket (supplier order) per supplier delivery location and supplier.
    FOR d IN
        SELECT loc.location_code,
               i.supplier_id,
               array_agg(o.product_code ORDER BY o.product_code) AS item_nos,
               array_agg(c.cartons      ORDER BY o.product_code) AS cartons
          FROM opening_cartons o
         CROSS JOIN LATERAL (VALUES ('S01', o.s01), ('S02', o.s02), ('S03', o.s03),
                                    ('S04', o.s04), ('S05', o.s05)) AS c (store_code, cartons)
          JOIN supply.item i ON i.item_no = o.product_code
          JOIN etl.store_xref loc_x ON loc_x.store_code = c.store_code AND loc_x.source_system = 'SUPPLY'
          JOIN supply.location loc ON loc.location_code = loc_x.source_code
         GROUP BY loc.location_code, i.supplier_id
         ORDER BY loc.location_code, i.supplier_id
    LOOP
        v_po := v_po + 1;
        PERFORM supply.record_supplier_delivery(d.location_code, d.supplier_id, 'PO-' || v_po,
                                                d.item_nos, d.cartons, pg_temp.utc(7, '07:00'));
    END LOOP;
END;
$$;
DROP TABLE opening_cartons;

-- 7 days ago 08:00: first sync, so the website starts with real numbers.
SELECT online.sync_website_stock(pg_temp.ts(7, '08:00'), 'seed');


-- ---------------------------------------------------------------------------
-- 6 days ago
-- ---------------------------------------------------------------------------
SELECT store_ops.record_sale('101', '{P001,P012}',      '{2,1}', pg_temp.ts(6, '09:42'));
SELECT store_ops.record_sale('102', '{P003}',           '{3}',   pg_temp.ts(6, '10:15'));
SELECT store_ops.record_sale('104', '{P007}',           '{2}',   pg_temp.ts(6, '11:30'));
SELECT store_ops.record_sale('103', '{P005,P010}',      '{4,2}', pg_temp.ts(6, '13:05'));
SELECT store_ops.record_sale('105', '{P014}',           '{2}',   pg_temp.ts(6, '15:48'));

-- ---------------------------------------------------------------------------
-- 5 days ago
-- ---------------------------------------------------------------------------
SELECT store_ops.record_sale('101', '{P005}',           '{3}',   pg_temp.ts(5, '09:20'));
SELECT store_ops.record_sale('102', '{P009,P010}',      '{2,1}', pg_temp.ts(5, '10:55'));
SELECT store_ops.record_sale('103', '{P001}',           '{3}',   pg_temp.ts(5, '12:10'));
SELECT store_ops.record_sale('104', '{P004,P011}',      '{2,1}', pg_temp.ts(5, '14:25'));
SELECT store_ops.record_sale('105', '{P002,P008}',      '{1,2}', pg_temp.ts(5, '16:40'));

SELECT online.place_online_order('2000', 'P003', 2, pg_temp.ts(5, '19:12'));  -- #1 CBD -> Bondi Junction (closest)
SELECT online.place_online_order('2112', 'P006', 1, pg_temp.ts(5, '20:30'));  -- #2 Ryde -> Chatswood

-- ---------------------------------------------------------------------------
-- 4 days ago
-- ---------------------------------------------------------------------------
SELECT supply.record_supplier_delivery('NSW-BONDI', 'SUP-01', 'PO-1101', '{P003}', '{4}', pg_temp.utc(4, '06:30'));
SELECT supply.record_supplier_delivery('NSW-NEWTN', 'SUP-01', 'PO-1102', '{P002}', '{3}', pg_temp.utc(4, '06:45'));
SELECT supply.record_supplier_delivery('NSW-PARRA', 'SUP-04', 'PO-1103', '{P016}', '{1}', pg_temp.utc(4, '07:10'));

SELECT store_ops.record_sale('101', '{P003}',           '{3}',   pg_temp.ts(4, '10:05'));
SELECT store_ops.record_sale('102', '{P001}',           '{1}',   pg_temp.ts(4, '11:20'));
SELECT store_ops.record_sale('103', '{P017}',           '{1}',   pg_temp.ts(4, '12:45'));
SELECT store_ops.record_sale('104', '{P003,P009}',      '{4,1}', pg_temp.ts(4, '15:15'));
SELECT store_ops.record_sale('105', '{P001,P006}',      '{2,2}', pg_temp.ts(4, '17:30'));

SELECT store_ops.collect_order('1', pg_temp.ts(4, '18:00'));                               -- #1 collected

-- #3 Penrith customer wants 2 dog beds: Penrith has only 1, so it is not
-- offered as a pickup store; the best option is Parramatta (has both, nearest)
-- and the customer collects there. They never collect, so the order becomes
-- overdue (cancelled by store_ops.cancel_overdue_orders when it is run).
SELECT online.place_online_order('2750', 'P013', 2, pg_temp.ts(4, '19:05'));

-- ---------------------------------------------------------------------------
-- 3 days ago: the aquarium kit sells out at three stores (website still says 7)
-- ---------------------------------------------------------------------------
SELECT store_ops.record_sale('101', '{P018}',           '{2}',   pg_temp.ts(3, '10:10'));
SELECT store_ops.record_sale('103', '{P018}',           '{2}',   pg_temp.ts(3, '11:35'));
SELECT store_ops.record_sale('102', '{P018}',           '{1}',   pg_temp.ts(3, '13:50'));
SELECT store_ops.record_sale('104', '{P011}',           '{1}',   pg_temp.ts(3, '14:20'));
SELECT store_ops.record_sale('105', '{P008}',           '{2}',   pg_temp.ts(3, '16:05'));

SELECT online.place_online_order('2026', 'P012', 1, pg_temp.ts(3, '20:05'));  -- #4 Bondi -> Bondi Junction

-- ---------------------------------------------------------------------------
-- 2 days ago
-- ---------------------------------------------------------------------------
-- A Bondi customer puts 3 aquarium kits in the bag: the website (stale) says
-- 7, but only 2 are left in total. Checkout is BLOCKED before payment, nothing
-- is charged or held, and the customer leaves the bag (no order is created).
SELECT online.place_online_order('2026', 'P018', 3, pg_temp.ts(2, '09:15'));

SELECT store_ops.record_sale('101', '{P002}',           '{2}',   pg_temp.ts(2, '10:30'));
SELECT store_ops.record_sale('102', '{P015}',           '{1}',   pg_temp.ts(2, '11:45'));
SELECT store_ops.record_sale('103', '{P014}',           '{2}',   pg_temp.ts(2, '13:00'));
SELECT store_ops.record_sale('104', '{P005}',           '{3}',   pg_temp.ts(2, '15:30'));
SELECT store_ops.record_sale('105', '{P016}',           '{1}',   pg_temp.ts(2, '16:50'));

SELECT store_ops.collect_order('2', pg_temp.ts(2, '17:00'));                               -- #2 collected

-- ---------------------------------------------------------------------------
-- 1 day ago
-- ---------------------------------------------------------------------------
SELECT supply.record_supplier_delivery('NSW-CHATS', 'SUP-01', 'PO-1201', '{P001}', '{5}', pg_temp.utc(1, '06:20'));
SELECT supply.record_supplier_delivery('NSW-PENRI', 'SUP-04', 'PO-1202', '{P014}', '{3}', pg_temp.utc(1, '06:50'));

SELECT store_ops.record_sale('101', '{P001,P006}',      '{1,1}', pg_temp.ts(1, '09:35'));
SELECT store_ops.cancel_order('4', 'Customer cancelled', pg_temp.ts(1, '10:00'));         -- #4 cancelled

-- #5 Bondi customer orders 3 different items. Pickup options: Chatswood has
-- all three (no transfers), Bondi has only the cat food. The customer chooses
-- Bondi Junction, so the dog beds and scratching posts are taken from
-- Chatswood and sent to Bondi. They are still in transit, so the order is not
-- ready yet.
SELECT online.place_online_order('2026', ARRAY['P003', 'P013', 'P017'],
                                 ARRAY[2, 2, 4], pg_temp.ts(1, '11:05'), 'CP-BONDI-JUNCTION');
SELECT store_ops.record_sale('103', '{P010}',           '{2}',   pg_temp.ts(1, '12:15'));
SELECT store_ops.record_sale('104', '{P007}',           '{1}',   pg_temp.ts(1, '14:05'));
SELECT store_ops.dispatch_order_transfers('5', pg_temp.ts(1, '15:30'));

SELECT online.place_online_order('2067', 'P004', 2, pg_temp.ts(1, '19:45'));  -- #6 Chatswood
SELECT online.place_online_order('2170', 'P008', 1, pg_temp.ts(1, '21:10'));  -- #7 Liverpool -> Parramatta


-- ---------------------------------------------------------------------------
-- Now: initial sync for the demo. Website numbers become correct.
-- ---------------------------------------------------------------------------
SELECT online.sync_website_stock(now(), 'seed');
