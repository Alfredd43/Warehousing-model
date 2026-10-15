-- =============================================================================
-- demo/video_demo_script.sql
-- PetHaven Data Warehouse Prototype - END-TO-END TEST (recorded video, ~10 min)
-- =============================================================================
-- Purpose : Brief item vi.e. The recorded end-to-end test of the working
--           prototype. It drives one scenario through the three source
--           systems and shows each layer: source -> ETL staging ->
--           transformation and validation -> data warehouse -> reports and
--           dashboard, then a data validation test. Ends with an automatic
--           PASS/FAIL summary (T1-T11).
-- Tutor   : 6 Oct - do not write queries live: record them and play the
--           video. 13 Oct - the video is the prototype: say the business
--           problem very briefly, then show how data is ingested, extracted,
--           transformed, cleaned and validated, and the reports and
--           dashboard. In the presentation it is played sped up
--           (demo/demo_runbook.md).
-- Screens : CloudBeaver at http://localhost:8978 (SQL) and the dashboard at
--           http://localhost:8080 (lines marked DASHBOARD). Start the
--           dashboard first (README, "In the dashboard"). After every
--           >>> WRITE, press Reload on the dashboard before showing it.
-- Database: pethaven_demo (CloudBeaver: host postgres, port 5432,
--           user/password student/student).
-- Run     : one statement at a time (select it, Ctrl+Enter).
-- Before  : rebuild before EVERY take, then reconnect CloudBeaver:
--             docker compose exec python python /workspace/scripts/build.py
--           Keep the automatic website refresh stopped, so the out-of-date
--           website number stays on screen until the manual refresh.
-- Writes  : only the statements marked >>> WRITE change data.
--
-- Test scenario
--   Supplier : SUP-01 order PO-3001, 5 cartons of P001 to Chatswood (NSW-CHATS)
--   Store    : the last aquarium kit (P018) sold at Newtown (104) and Penrith (105)
--   Online   : a Bondi customer tries to buy 1 x P018 while the website still shows 2
--   Refresh  : the website extracts real stock from the store system and
--              corrects its numbers (code name: sync_website_stock)
--   Validate : SUP-02 order PO-3002, 2 cartons of P019 (not on the warehouse
--              product list) to Parramatta, and 1 sold there: the ETL rejects
--              both records; once a data steward adds P019 they load once
--
-- Timing   : Opening 0:30 | 0 Pre-check 0:15 | 1 Baseline 0:30 |
--            2 Test inputs 0:45 | 3 ETL code + results 2:00 | 4 Warehouse 0:45 |
--            5 Reports + dashboard UC1-UC4 3:00 | 6 Traceability 0:30 |
--            7 Validation 1:00 | 8 Result 0:30
--            = about 9:45 (played sped up in the presentation)
-- =============================================================================


-- =============================================================================
-- OPENING: the business problem in brief                              (0:30)
-- =============================================================================
-- DASHBOARD: show the Overview page while saying:
--   "PetHaven has five Sydney stores and a website. Product stock is not
--    updated in real time between in-store and online sales, so stock sold
--    in one channel can still show as available in the other. Our solution
--    shortens the website's data extraction from once a day to every
--    3 minutes, checks real store stock at checkout before payment, and
--    integrates the store, supplier and online systems into one data
--    warehouse, so the dashboard can measure the gap that remains. This
--    video tests that prototype end to end."


-- =============================================================================
-- 0. PRE-CHECK: clean starting point                                  (0:15)
-- =============================================================================
SELECT current_database()                                                    AS db,
       (SELECT scheduler_status FROM dw.rpt_online_staleness)                AS scheduler,
       (SELECT pending_events   FROM dw.rpt_online_staleness)                AS pending_events,
       (SELECT count(*) FROM dw.rpt_reconciliation WHERE status <> 'match')  AS reconciliation_gaps,
       (SELECT count(*) FROM etl.v_data_quality)                             AS rejected_rows,
       (SELECT count(*) FROM supply.supplier_delivery
         WHERE supplier_order_no = 'PO-3001')                                AS po_3001_used;
-- EXPECTED: pethaven_demo | never started | 0 | 0 | 0 | 0   (otherwise rebuild)


-- =============================================================================
-- 1. BASELINE: the source systems before the test                     (0:30)
-- =============================================================================
-- Store system: shelf stock per store number
SELECT store_no, item_no, in_store_quantity AS shelf, reserved_quantity AS reserved
  FROM store_ops.store_stock
 WHERE item_no IN ('P001', 'P018')
 ORDER BY item_no, store_no;
-- EXPECTED: P001 37/27/53/20/46 (total 183); P018 only 1 at 104 and 1 at 105

-- Online system: the website number, matching the stores
SELECT product_code, online_shown AS website, actual_in_store AS actual, status
  FROM dw.rpt_online_vs_actual
 WHERE product_code IN ('P001', 'P018')
 ORDER BY product_code;
-- EXPECTED: P001 183 / 183 matches; P018 2 / 2 matches


-- =============================================================================
-- 2. TEST INPUTS: one event in each source system                     (0:45)
-- =============================================================================
-- >>> WRITE (Supplier): 5 cartons of P001 delivered to Chatswood
SELECT supply.record_supplier_delivery('NSW-CHATS', 'SUP-01', 'PO-3001',
                                       ARRAY['P001'], ARRAY[5]) AS delivery_no;
-- EXPECTED: a new delivery number (31)

-- >>> WRITE (Store): the last P018 sells at Newtown and at Penrith
SELECT store_ops.record_sale('104', ARRAY['P018'], ARRAY[1]) AS newtown_receipt;
SELECT store_ops.record_sale('105', ARRAY['P018'], ARRAY[1]) AS penrith_receipt;
-- EXPECTED: two new receipt numbers (29, 30)

-- >>> WRITE (Online): a Bondi customer (postcode 2026) tries to buy 1 x P018
SELECT online.place_online_order('2026', 'P018', 1) AS order_no;
-- EXPECTED: NULL = checkout blocked before payment (real stock is 0)


-- =============================================================================
-- 3. ETL: the code, then its results                                  (2:00)
-- =============================================================================
-- 3a. SHOW THE CODE (0:45). Nothing to run. Open workspace/db/06_etl.sql in an
--     editor (or in CloudBeaver: pethaven_demo > Schemas > etl > Views /
--     Functions > Source) and point at each step:
--       EXTRACT   capture_supplier_delivery_line() (line ~223): a trigger copies
--                 each new source record into staging, unchanged (cartons, UTC,
--                 the supplier's location code).
--       TRANSFORM etl.v_transform (line ~334): cartons x units per carton,
--                 UTC -> Sydney time, location code -> S01-S05 via store_xref.
--       VALIDATE  reject_reason (line ~418): an unknown item or unmapped store
--                 is rejected with a reason, never guessed.
--       LOAD      etl.run_etl() (line ~434): valid rows into dw.fact_stock_event,
--                 every pass logged in etl.etl_run.
--       WHEN      cdc_run_etl() (line ~534): runs the ETL straight after every
--                 source change (near real time), not on a timer.
--
-- 3b. RESULTS (1:15): the test inputs from section 2 went through those steps.
-- Supplier record: source values kept in staging, transformed for the warehouse
SELECT s.supplier_order_no,
       s.cartons                      AS source_cartons,
       s.cartons * s.units_per_carton AS units,
       s.location_code                AS source_location,
       x.store_code                   AS dw_store,
       s.delivered_at_utc             AS source_utc,
       (s.delivered_at_utc AT TIME ZONE 'UTC') AT TIME ZONE 'Australia/Sydney' AS sydney_time,
       s.load_status
  FROM etl.stg_supplier_delivery_line s
  LEFT JOIN etl.store_xref x ON x.source_system = 'SUPPLY' AND x.source_code = s.location_code
 WHERE s.supplier_order_no = 'PO-3001';
-- EXPECTED: 5 cartons x 4 = 20 units; NSW-CHATS -> S03; UTC + 11 h; loaded

-- Store and online records staged with their own source references
SELECT 'STORE' AS source, store_no AS source_code, item_no, quantity, load_status, source_ref
  FROM etl.stg_store_sale_line
 WHERE stg_id > (SELECT max(stg_id) - 2 FROM etl.stg_store_sale_line)
UNION ALL
SELECT 'ONLINE', pickup_cp_code, item_no, quantity, load_status, source_ref
  FROM etl.stg_checkout_item
 WHERE stg_id = (SELECT max(stg_id) FROM etl.stg_checkout_item);
-- EXPECTED: STORE 104 and 105 (receipts 29, 30); ONLINE CP-BONDI-JUNCTION (attempt 9); all loaded

-- ETL audit: each source change triggered an ETL run automatically
SELECT etl_run_id, trigger_source, rows_read, rows_loaded, rows_rejected
  FROM etl.etl_run
 ORDER BY etl_run_id DESC
 LIMIT 4;
-- EXPECTED: checkout_attempt_item, sale_line x2, supplier_delivery_line; 0 rejected


-- =============================================================================
-- 4. VERIFY DATA WAREHOUSE: one fact table, all three sources         (0:45)
-- =============================================================================
SELECT f.event_id, f.source_system, f.event_type, s.store_code, p.product_code,
       f.quantity_change AS shelf_change, f.units,
       f.event_ts AT TIME ZONE 'Australia/Sydney' AS event_time_sydney,
       f.source_ref
  FROM dw.fact_stock_event f
  JOIN dw.dim_store   s ON s.store_key   = f.store_key
  JOIN dw.dim_product p ON p.product_key = f.product_key
 ORDER BY f.event_id DESC
 LIMIT 4;
-- EXPECTED (newest first):
--   ONLINE checkout_blocked   S02 P018   0  units 1
--   STORE  store_sale         S05 P018  -1
--   STORE  store_sale         S04 P018  -1
--   SUPPLY supplier_delivery  S03 P001 +20  units 20


-- =============================================================================
-- 5. VERIFY REPORTS AND DASHBOARD: the four data use cases           (3:00)
-- =============================================================================
-- Each use case: the report view in SQL, then the same answer on the
-- dashboard. Ordered by impact: UC1 and UC2 (owner, high), UC3 (store
-- managers, medium), UC4 (store staff, low).

-- UC1 Website accuracy (owner, high): the website number vs real stock
SELECT product_code, online_shown AS website, actual_in_store AS actual,
       overstated_by AS discrepancy, status
  FROM dw.rpt_online_vs_actual
 WHERE status <> 'matches'
 ORDER BY product_code;
-- EXPECTED: P001 183 vs 203 (-20, understated); P018 2 vs 0 (+2, overstated)
-- DASHBOARD: Website stock. Banner: "2 of 18 products show the wrong stock on
--   the website: 1 too high ...; 1 too low ...". Status line: automatic
--   refresh not running. Table: P001 "Website too low" by 20, P018
--   "Website too high" by 2.

-- >>> WRITE (Online): refresh the website stock now (manual refresh)
SELECT online.sync_website_stock() AS refresh_no;

SELECT product_code, before_qty, after_qty, difference
  FROM dw.rpt_last_sync_changes
 WHERE measure = 'online_available'
 ORDER BY product_code;
-- EXPECTED: P001 183 -> 203; P018 2 -> 0
-- DASHBOARD: Reload Website stock. Banner: "The website matches the stores
--   for all 18 products." "What the last refresh corrected": P001 183 -> 203,
--   P018 2 -> 0, triggered manually.

-- UC2 Blocked checkouts (owner, high): what the out-of-date number cost
SELECT basket, product_code, quantity_in_bag, pickup_store,
       website_showed, actual_combined_at_checkout AS actual, reason
  FROM dw.rpt_checkout_blocked
 ORDER BY attempted_at DESC
 LIMIT 1;
-- EXPECTED: basket 9, P018, 1, Bondi, website 2, actual 0,
--           'stock sold since the last refresh - website number was out of date'
-- DASHBOARD: Orders & potential lost sales -> Potential lost sales. Click the newest P018 row:
--   the customer checkout card shows "Blocked before payment", pickup at
--   Bondi, website 2 vs stores 0. Say: nobody was charged; this is a
--   potential lost sale.

-- UC3 Low stock (store managers, medium): which stores need replenishment
SELECT store_name,
       count(*) FILTER (WHERE low_stock)                                        AS low_stock_products,
       string_agg(product_code, ', ' ORDER BY product_code) FILTER (WHERE low_stock) AS products
  FROM dw.rpt_current_stock_by_store
 GROUP BY store_code, store_name
 ORDER BY low_stock_products DESC, store_code;
-- EXPECTED: Chatswood 3 and Newtown 3 (P013, P017, P018);
--           Parramatta, Bondi, Penrith 2 each (P013, P018)
-- DASHBOARD: Store stock -> Current stock, tick "Low stock only": P018 is red
--   (0) in every store. Say: the dashboard flags low stock; the reorder
--   itself is made outside this system.

-- UC4 Stock position (store staff, low): where stock is available or reserved
SELECT store_name, in_store_quantity AS available, reserved_quantity AS reserved
  FROM dw.rpt_current_stock_by_store
 WHERE product_code = 'P001'
 ORDER BY store_code;
-- EXPECTED: Chatswood 73 = 53 + 20
-- DASHBOARD: Store stock, Product P001: Chatswood available 73. Click the
--   Chatswood row: its event history lists the supplier delivery
--   (+20, supplier SUP-01 order PO-3001).


-- =============================================================================
-- 6. VERIFY TRACEABILITY: report -> warehouse -> staging -> source    (0:30)
-- =============================================================================
SELECT r.basket          AS report_row,
       f.event_id        AS dw_event,
       f.source_ref,
       s.stg_id          AS staging_row,
       s.load_status,
       a.attempt_no      AS source_attempt,
       a.outcome         AS source_outcome
  FROM dw.rpt_checkout_blocked r
  JOIN dw.fact_stock_event f     ON f.event_type = 'checkout_blocked'
                                AND f.order_ref = r.basket AND f.event_ts = r.attempted_at
  JOIN etl.stg_checkout_item s   ON s.event_id = f.event_id
  JOIN online.checkout_attempt a ON a.attempt_no = s.attempt_no
 ORDER BY r.attempted_at DESC
 LIMIT 1;
-- EXPECTED: basket 9 -> event 150 -> staging row (loaded) -> attempt 9 (blocked)


-- =============================================================================
-- 7. VALIDATION TEST: an unknown item is rejected, then loaded once   (1:00)
-- =============================================================================
-- P019 (Crinkle Cat Tunnel) is a new line: it is in the store and supplier
-- catalogues but not yet on the warehouse product list.

-- >>> WRITE (Supplier): SUP-02 delivers 2 cartons of P019 to Parramatta
SELECT supply.record_supplier_delivery('NSW-PARRA', 'SUP-02', 'PO-3002',
                                       ARRAY['P019'], ARRAY[2]) AS delivery_no;
-- EXPECTED: a new delivery number (32)

-- >>> WRITE (Store): Parramatta sells 1 x P019
SELECT store_ops.record_sale('101', ARRAY['P019'], ARRAY[1]) AS parramatta_receipt;
-- EXPECTED: a new receipt number (31)

-- Both business transactions succeeded, but the ETL rejected their records:
-- kept in staging with a reason, not guessed and not loaded
SELECT source_system, source_ref, reject_reason
  FROM etl.v_data_quality
 ORDER BY source_ref;
-- EXPECTED: 2 rows, STORE receipt 31 and SUPPLY order PO-3002,
--           'Unknown item P019: not on the warehouse product list'
-- DASHBOARD: Reload. A yellow banner on every page: "Some records are
--   missing from the reports (2 source records rejected by the ETL)".

-- >>> WRITE (Data steward): add P019 to the warehouse product list
SELECT etl.add_item('P019');

-- >>> WRITE (ETL): run one pass by hand; the waiting records load
SELECT etl.run_etl('manual') AS etl_run_id;

SELECT etl_run_id, trigger_source, rows_read, rows_loaded, rows_rejected
  FROM etl.etl_run
 ORDER BY etl_run_id DESC
 LIMIT 1;
-- EXPECTED: manual | 2 read, 2 loaded, 0 rejected

-- >>> WRITE (ETL): a second pass finds nothing to do (no duplicates)
SELECT etl.run_etl('manual') AS etl_run_id;
-- EXPECTED: NULL

SELECT f.event_id, f.source_system, f.event_type, s.store_code, p.product_code,
       f.quantity_change AS shelf_change, f.units, f.source_ref
  FROM dw.fact_stock_event f
  JOIN dw.dim_store   s ON s.store_key   = f.store_key
  JOIN dw.dim_product p ON p.product_key = f.product_key
 WHERE p.product_code = 'P019'
 ORDER BY f.event_id;
-- EXPECTED: SUPPLY supplier_delivery S01 P019 +8 units 8;
--           STORE store_sale S01 P019 -1
-- DASHBOARD: Reload. The yellow banner has gone.


-- =============================================================================
-- 8. TEST RESULT: every row must be PASS                              (0:30)
-- =============================================================================
WITH po AS (
    SELECT s.cartons, s.units_per_carton, s.delivered_at_utc, s.event_id,
           f.units, f.event_ts, f.etl_run_id, ds.store_code
      FROM etl.stg_supplier_delivery_line s
      JOIN dw.fact_stock_event f ON f.event_id = s.event_id
      JOIN dw.dim_store ds       ON ds.store_key = f.store_key
     WHERE s.supplier_order_no = 'PO-3001'
), blocked AS (
    SELECT * FROM dw.rpt_checkout_blocked ORDER BY attempted_at DESC LIMIT 1
), checks(test_no, test, passed) AS (
              SELECT 1,  'Supplier: 5 cartons loaded as 20 units',
                         (SELECT bool_and(cartons * units_per_carton = units AND units = 20) FROM po)
    UNION ALL SELECT 2,  'Supplier: NSW-CHATS mapped to S03',
                         (SELECT bool_and(store_code = 'S03') FROM po)
    UNION ALL SELECT 3,  'Supplier: UTC converted to Sydney time',
                         (SELECT bool_and(event_ts = delivered_at_utc AT TIME ZONE 'UTC') FROM po)
    UNION ALL SELECT 4,  'Store: P018 sales at S04 and S05 loaded',
                         (SELECT count(DISTINCT ds.store_code) = 2
                            FROM dw.fact_stock_event f
                            JOIN dw.dim_store ds USING (store_key)
                            JOIN dw.dim_product dp USING (product_key)
                           WHERE f.event_type = 'store_sale' AND dp.product_code = 'P018'
                             AND f.event_id > (SELECT max(event_id) FROM po))
    UNION ALL SELECT 5,  'Online: blocked checkout captured (stale website)',
                         (SELECT product_code = 'P018' AND website_showed = 2
                                 AND actual_combined_at_checkout = 0 FROM blocked)
    UNION ALL SELECT 6,  'UC4: warehouse stock = store system (P001 Chatswood)',
                         (SELECT r.in_store_quantity = ss.in_store_quantity
                            FROM dw.rpt_current_stock_by_store r, store_ops.store_stock ss
                           WHERE r.store_code = 'S03' AND r.product_code = 'P001'
                             AND ss.store_no = '103' AND ss.item_no = 'P001')
    UNION ALL SELECT 7,  'UC1: website matches the stores after the refresh',
                         (SELECT count(*) = 0 FROM dw.rpt_online_vs_actual WHERE status <> 'matches')
    UNION ALL SELECT 8,  'Traceability: no staging row left pending',
                         (SELECT count(*) = 0 FROM etl.v_staging WHERE load_status NOT IN ('loaded', 'skipped'))
    UNION ALL SELECT 9,  'Reconciliation: warehouse matches store system',
                         (SELECT count(*) = 0 FROM dw.rpt_reconciliation WHERE status <> 'match')
    UNION ALL SELECT 10, 'Data quality: no rejected source rows',
                         (SELECT count(*) = 0 FROM etl.v_data_quality)
    UNION ALL SELECT 11, 'Validation: P019 rejected with a reason, then loaded once',
                         (SELECT EXISTS (SELECT 1 FROM etl.etl_run
                                          WHERE rows_rejected > 0
                                            AND etl_run_id > (SELECT max(etl_run_id) FROM po))
                             AND count(*) = 2
                            FROM dw.fact_stock_event f
                            JOIN dw.dim_product dp USING (product_key)
                           WHERE dp.product_code = 'P019')
)
SELECT 'T' || test_no AS test, test AS description,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
  FROM checks
 ORDER BY test_no;
-- EXPECTED: T1-T11 all PASS
-- DASHBOARD: end on the Overview page: the website matches the stores.
-- To record another take: rebuild (build.py), reconnect CloudBeaver, start at 0.
-- =============================================================================
