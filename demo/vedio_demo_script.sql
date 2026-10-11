-- =============================================================================
-- demo/vedio_demo_script.sql
-- PetHaven Data Warehouse Prototype
-- RECORDED END-TO-END TESTING DEMO (brief item vi.e) - runbook + SQL in one file
-- =============================================================================
-- Follows demo/demo_runbook.md, sections 1-7. Every step says:
--   [SCREEN]  what is on screen (CloudBeaver or a dashboard page)
--   [SAY]     what to say
--   [RUN]     the SQL (select one statement, Ctrl+Enter)
--   EXPECTED  what a fresh build shows (the test's pass condition)
--
-- The test drives ONE scenario through all three source systems, then proves
-- it arrived in the warehouse, the reports and the dashboard:
--   Supplier : 5 cartons of P001 delivered to Chatswood (NSW-CHATS, PO-3001)
--   Store    : the last 2 aquarium kits (P018) sold at Newtown and Penrith
--   Online   : a customer tries to buy P018 - website still shows 2 - blocked
--   Sync     : the website sync corrects the website numbers
-- Section 7 ends with an automatic PASS/FAIL test summary.
--
-- Target length: about 10 minutes. Database: pethaven_demo.
-- Writes happen only in the steps marked >>> WRITE. Everything else is
-- read-only and safe to repeat. No order, bag, event or run number is
-- hard-coded: queries find "the latest" or use the supplier order PO-3001.
-- =============================================================================


-- =============================================================================
-- BEFORE RECORDING (off camera, once)
-- =============================================================================
-- 1. From the repository root:
--      docker compose up -d
--      docker compose exec python python /workspace/tests/check_demo.py        (FAIL 0)
--      docker compose exec python python /workspace/tests/check_scheduler.py   (FAIL 0)
--      docker compose exec python python /workspace/tests/check_dashboard.py   (FAIL 0)
-- 2. Build a clean demo database (again right before every take):
--      docker compose exec python python /workspace/scripts/build.py
-- 3. Start the dashboard and open http://localhost:8080 :
--      docker compose -f docker-compose.yml -f workspace/dashboard/compose.dashboard.yml up -d dashboard
-- 4. CloudBeaver (http://localhost:8978): connection host postgres, port 5432,
--    database pethaven_demo, user/password student/student. Reconnect after
--    every rebuild, then open this file in the SQL editor.
-- 5. Do NOT start the automatic sync: it would fix the website before the
--    stale number has been shown on camera.

-- 0.1 | PRE-FLIGHT: right database, clean starting point, scheduler not running.
SELECT current_database()                                   AS connected_database,
       (SELECT scheduler_status   FROM dw.rpt_online_staleness) AS scheduler,
       (SELECT pending_events     FROM dw.rpt_online_staleness) AS pending_events,
       (SELECT products_out_of_date FROM dw.rpt_online_staleness) AS website_out_of_date,
       (SELECT count(*) FROM dw.rpt_reconciliation WHERE status <> 'match') AS reconciliation_gaps,
       (SELECT count(*) FROM etl.v_data_quality)              AS rejected_rows,
       (SELECT count(*) FROM supply.supplier_delivery WHERE supplier_order_no = 'PO-3001') AS po_3001_already_used;
-- EXPECTED: pethaven_demo | never started | 0 | 0 | 0 | 0 | 0
-- Only if scheduler = 'running', stop it (it stops within 2 seconds):
-- UPDATE online.sync_schedule SET status = 'stop_requested' WHERE status = 'running';
-- If po_3001_already_used <> 0 or any other value differs: rebuild (step 2).


-- =============================================================================
-- 1. BUSINESS PROBLEM                                              (~1 min)
-- =============================================================================
-- [SCREEN] Dashboard > Overview.
-- [SAY] "PetHaven sells pet products through five Sydney stores and an online
--        store. Its inventory data lives in three separate systems: Supplier,
--        Store and Online. One visible symptom is that the website stock can
--        be stale between synchronisations. The real problem is a data
--        problem: inventory data is fragmented, so it is hard to get one
--        integrated view, measure stock discrepancies and see their business
--        impact."
-- [SAY] "The Data Warehouse does not perform checkout or the stock sync. Its
--        role is to integrate data from the three systems so PetHaven can
--        analyse inventory from one consistent view. This video tests that
--        end to end: we create real events in each source system and follow
--        them through ETL, the warehouse and the dashboard."


-- =============================================================================
-- 2. THE THREE SOURCE SYSTEMS                                      (~1 min)
-- =============================================================================
-- [SCREEN] CloudBeaver.
-- [SAY] "Same inventory process, three systems, three structures."

-- 2.1 | SUPPLIER SYSTEM: deliveries in CARTONS, UTC time, supplier location codes.
SELECT d.delivery_no, d.supplier_id, d.supplier_order_no,
       d.location_code AS supplier_location_code,
       l.item_no, l.cartons, i.units_per_carton, d.delivered_at_utc
  FROM supply.supplier_delivery d
  JOIN supply.supplier_delivery_line l ON l.delivery_no = d.delivery_no
  JOIN supply.item i ON i.item_no = l.item_no
 ORDER BY d.delivery_no DESC, l.line_no
 LIMIT 5;
-- EXPECTED: latest is delivery 30 (SUP-04, PO-1202, NSW-PENRI, P014, 3 cartons x 4).

-- 2.2 | STORE SYSTEM: shelf and reserved stock per store number (101..105).
SELECT st.store_no, st.store_name, ss.item_no, ss.in_store_quantity AS shelf, ss.reserved_quantity AS reserved
  FROM store_ops.store_stock ss JOIN store_ops.store st USING (store_no)
 WHERE ss.item_no IN ('P001', 'P018')
 ORDER BY ss.item_no, st.store_no;
-- EXPECTED: P001 shelf 37/27/53/20/46 (total 183); P018 only Newtown 1 and Penrith 1.

-- 2.3 | ONLINE SYSTEM: ONE combined website number per product, plus its sync log.
SELECT p.item_no, p.title, s.available_quantity AS website_shows,
       s.last_synced_at AT TIME ZONE 'Australia/Sydney' AS last_synced_sydney
  FROM online.product p JOIN online.online_stock s USING (item_no)
 WHERE p.item_no IN ('P001', 'P018')
 ORDER BY p.item_no;
-- EXPECTED: P001 183, P018 2.
SELECT sync_no, run_at AT TIME ZONE 'Australia/Sydney' AS run_at_sydney, triggered_by, status, products_changed
  FROM online.stock_sync ORDER BY sync_no DESC LIMIT 3;
-- EXPECTED: 2 seed syncs; the latest changed 16 products.
-- [SAY] "Different codes for the same store (101, NSW-CHATS, CP-CHATSWOOD),
--        different units (cartons vs units) and different clocks (UTC vs
--        Sydney). That is why the data has to be integrated."


-- =============================================================================
-- 3. ETL AND DATA TRANSFORMATION                                   (~2 min)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Example 1 - supplier delivery
-- -----------------------------------------------------------------------------
-- 3.1 | >>> WRITE (Supplier system): supplier SUP-01, order PO-3001,
--       5 cartons of P001 (dog food) delivered to Chatswood.
-- [SAY] "A supplier delivers 5 cartons of dog food to Chatswood. The supplier
--        system records cartons, its own location code, and UTC time."
SELECT supply.record_supplier_delivery('NSW-CHATS', 'SUP-01', 'PO-3001', ARRAY['P001'], ARRAY[5]) AS delivery_no;
-- EXPECTED: a new delivery number (31 on a fresh build).

-- 3.2 | STAGING: the ETL captured the row automatically, still in source format.
SELECT stg_id, supplier_id, supplier_order_no,
       location_code    AS original_location,
       item_no, cartons, units_per_carton,
       delivered_at_utc AS original_utc,
       load_status, event_id AS loaded_dw_event_id, source_ref
  FROM etl.stg_supplier_delivery_line
 WHERE supplier_order_no = 'PO-3001';
-- EXPECTED: NSW-CHATS, P001, 5 cartons x 4, load_status = loaded,
--           source_ref = SUPPLY:supplier SUP-01 order PO-3001 line 1.

-- 3.3 | TRANSFORMATION - BEFORE / AFTER side by side.
-- [SAY] "Cartons become units, UTC becomes Sydney business time, and the
--        source location code is mapped to the approved warehouse store."
SELECT s.supplier_order_no,
       s.item_no,
       s.cartons                          AS before_cartons,
       s.units_per_carton,
       s.cartons * s.units_per_carton     AS after_units,
       s.location_code                    AS before_location_code,
       x.store_code                       AS after_dw_store,
       s.delivered_at_utc                 AS before_time_utc,
       (s.delivered_at_utc AT TIME ZONE 'UTC') AT TIME ZONE 'Australia/Sydney' AS after_time_sydney,
       s.load_status
  FROM etl.stg_supplier_delivery_line s
  LEFT JOIN etl.store_xref x ON x.source_system = 'SUPPLY' AND x.source_code = s.location_code
 WHERE s.supplier_order_no = 'PO-3001';
-- EXPECTED: 5 cartons x 4 = 20 units; NSW-CHATS -> S03; UTC +11 h = Sydney time.
-- (etl.v_transform lists only pending/rejected rows, so a loaded row has left
--  it; this query applies the same documented rules to the stored values.)

-- 3.4 | APPROVED MAPPING: three operational codes -> one warehouse store.
SELECT store_code, store_name, store_no, location_code, cp_code
  FROM etl.v_store_codes ORDER BY store_code;
-- EXPECTED: 5 rows, e.g. S03 = 103 (Store) = NSW-CHATS (Supplier) = CP-CHATSWOOD (Online).
-- [SAY] "Only approved mappings are used. Product item numbers (P001) are the
--        same in all systems; store codes are what needs mapping."

-- -----------------------------------------------------------------------------
-- Example 2 - store and online events
-- -----------------------------------------------------------------------------
-- 3.5 | >>> WRITE (Store system): the last aquarium kit (P018) is sold at
--       Newtown (104) and the last one at Penrith (105).
-- [SAY] "Now two in-store sales. The store shelves drop at once, but the
--        website number only changes at the next sync."
SELECT store_ops.record_sale('104', ARRAY['P018'], ARRAY[1]) AS newtown_receipt;
SELECT store_ops.record_sale('105', ARRAY['P018'], ARRAY[1]) AS penrith_receipt;
-- EXPECTED: two new receipt numbers (29 and 30 on a fresh build).

-- 3.6 | >>> WRITE (Online system): a Bondi customer (postcode 2026) tries to
--       buy 1 x P018. The website still shows 2, so it goes in the bag, but
--       checkout checks real store stock BEFORE payment.
SELECT online.place_online_order('2026', 'P018', 1) AS order_no;
-- EXPECTED: NULL = checkout blocked; nothing charged, nothing reserved.

-- 3.7 | Both events were staged by the ETL with their own source references.
SELECT 'STORE'  AS source_system, sale_no::text AS source_id, store_no AS source_store_code,
       item_no, quantity, load_status, event_id, source_ref
  FROM etl.stg_store_sale_line WHERE item_no = 'P018'
   AND stg_id > (SELECT max(stg_id) - 2 FROM etl.stg_store_sale_line)
UNION ALL
SELECT 'ONLINE', attempt_no::text, pickup_cp_code, item_no, quantity, load_status, event_id, source_ref
  FROM etl.stg_checkout_item WHERE stg_id = (SELECT max(stg_id) FROM etl.stg_checkout_item)
 ORDER BY source_system DESC, source_id;
-- EXPECTED: STORE receipt 29 (104) and 30 (105); ONLINE checkout attempt 9 at
--           CP-BONDI-JUNCTION; all loaded, each with its own source_ref.

-- 3.8 | ETL AUDIT: each source change triggered a near-real-time ETL run.
SELECT etl_run_id, trigger_source, started_at AT TIME ZONE 'Australia/Sydney' AS started_sydney, rows_read, rows_loaded, rows_rejected, rows_skipped
  FROM etl.etl_run ORDER BY etl_run_id DESC LIMIT 6;
-- EXPECTED: newest runs triggered by cdc:online.checkout_attempt_item,
--           cdc:store_ops.sale_line (x2), cdc:supply.supplier_delivery_line; rows_rejected 0.
-- [SAY] "The ETL layer standardises data from different operational systems,
--        validates it and loads it, so the records can be reliably combined.
--        Staging keeps the link between each source record and its warehouse row."


-- =============================================================================
-- 4. THE INTEGRATED DATA WAREHOUSE                                 (~1 min)
-- =============================================================================

-- 4.1 | ONE FACT TABLE, events from all three systems in one model.
SELECT f.event_id, f.source_system, f.event_type,
       ds.store_code, ds.store_name, dp.product_code,
       f.quantity_change AS shelf_change, f.reserved_change, f.units,
       f.event_ts AT TIME ZONE 'Australia/Sydney' AS event_time_sydney,
       f.source_ref
  FROM dw.fact_stock_event f
  JOIN dw.dim_store   ds ON ds.store_key   = f.store_key
  JOIN dw.dim_product dp ON dp.product_key = f.product_key
 ORDER BY f.event_id DESC
 LIMIT 4;
-- EXPECTED (newest first):
--   ONLINE checkout_blocked   S02 P018  shelf  0  units 1   (pickup store Bondi)
--   STORE  store_sale         S05 P018  shelf -1
--   STORE  store_sale         S04 P018  shelf -1
--   SUPPLY supplier_delivery  S03 P001  shelf +20 units 20

-- 4.2 | SUPPLIER LINEAGE: source -> staging -> warehouse, same source_ref.
SELECT d.delivery_no                     AS source_delivery,
       s.cartons                         AS source_cartons,
       s.location_code                   AS source_location,
       s.stg_id                          AS staging_row,
       f.event_id                        AS dw_event,
       ds.store_code                     AS dw_store,
       f.units                           AS dw_units,
       f.event_ts AT TIME ZONE 'Australia/Sydney' AS dw_time_sydney,
       f.source_ref
  FROM supply.supplier_delivery d
  JOIN etl.stg_supplier_delivery_line s ON s.delivery_no = d.delivery_no
  JOIN dw.fact_stock_event f            ON f.event_id = s.event_id
  JOIN dw.dim_store ds                  ON ds.store_key = f.store_key
 WHERE d.supplier_order_no = 'PO-3001';
-- EXPECTED: delivery 31, 5 cartons NSW-CHATS -> staging row -> dw event, S03, 20 units, Sydney time.

-- 4.3 | CROSS-SYSTEM INTEGRATION: events per source in the one fact table.
SELECT source_system, event_type, count(*) AS event_count
  FROM dw.fact_stock_event
 GROUP BY source_system, event_type
 ORDER BY source_system, event_type;
-- EXPECTED: ONLINE checkout_blocked 2 | STORE cancellation 1, collection 2,
--           reservation 9, store_sale 38, transfer_out 2 | SUPPLY supplier_delivery 96.

-- 4.4 | DIMENSIONAL MODEL: conformed product, store and date (Sydney business date).
SELECT f.event_id, dp.product_code, dp.category, ds.store_code, ds.channel,
       dd.full_date AS sydney_business_date, dd.day_name, f.event_type
  FROM dw.fact_stock_event f
  JOIN dw.dim_product dp ON dp.product_key = f.product_key
  JOIN dw.dim_store   ds ON ds.store_key   = f.store_key
  JOIN dw.dim_date    dd ON dd.date_key    = f.date_key
 ORDER BY f.event_id DESC
 LIMIT 4;
-- [SAY] "The warehouse provides a consistent analytical layer across the
--        three source systems. That is what lets the dashboard answer
--        cross-system inventory questions."


-- =============================================================================
-- 5. DASHBOARD - FOUR BUSINESS QUESTIONS                         (~3.5 min)
-- =============================================================================
-- For each question: show the dashboard page first, then (optionally) the
-- SQL view behind it, to prove the page reads the warehouse.

-- -----------------------------------------------------------------------------
-- Q1. Where is stock available or reserved?
-- -----------------------------------------------------------------------------
-- [SCREEN] Dashboard > Store stock, product filter P001.
-- [SAY] "This view brings shelf and reservation information together so
--        managers can understand the stock position across stores. The
--        Chatswood delivery we just recorded is already included."
SELECT store_code, store_name, product_code,
       in_store_quantity AS shelf_available,
       reserved_quantity AS reserved,
       total_on_hand, low_stock
  FROM dw.rpt_current_stock_by_store
 WHERE product_code = 'P001'
 ORDER BY store_code;
-- EXPECTED: 37 / 27 / 73 / 20 / 46 - Chatswood (S03) 73 = 53 + 20 from PO-3001. Reserved 0.
-- NOTE: shelf (in_store_quantity) is already available-to-sell; reserved
--       units are held separately. Do NOT compute shelf - reserved.

-- Reserved stock exists elsewhere (open click-and-collect orders):
SELECT store_code, store_name,
       sum(in_store_quantity) AS shelf_units,
       sum(reserved_quantity) AS reserved_units
  FROM dw.rpt_current_stock_by_store
 GROUP BY store_code, store_name
 ORDER BY store_code;
-- EXPECTED: reserved 3 Parramatta, 2 Bondi, 2 Chatswood (seed click-and-collect orders).

-- -----------------------------------------------------------------------------
-- Q4. Which stores have lower stock levels?
-- -----------------------------------------------------------------------------
-- [SCREEN] Dashboard > Store stock, compare the five stores (one product).
-- [SAY] "The integrated view lets managers compare locations and quickly see
--        stores with lower stock. The dashboard identifies low stock; it does
--        not decide or execute replenishment."
SELECT rank() OVER (ORDER BY in_store_quantity) AS lowest_rank,
       store_name, in_store_quantity AS available_units,
       repeat('#', (in_store_quantity / 4)::int) AS bar
  FROM dw.rpt_current_stock_by_store
 WHERE product_code = 'P001'
 ORDER BY in_store_quantity;
-- EXPECTED: 1 Newtown 20, 2 Bondi 27, 3 Parramatta 37, 4 Penrith 46, 5 Chatswood 73.

-- Low-stock alerts (2 or fewer on the shelf) per store:
SELECT store_name, count(*) FILTER (WHERE low_stock) AS low_stock_products,
       string_agg(product_code, ', ' ORDER BY product_code) FILTER (WHERE low_stock) AS products
  FROM dw.rpt_current_stock_by_store
 GROUP BY store_name
 ORDER BY low_stock_products DESC, store_name;
-- EXPECTED: P018 low in all 5 stores (0 after the two sales); also P013 everywhere,
--           P017 at Chatswood and Newtown.

-- -----------------------------------------------------------------------------
-- Q2. How inaccurate is website stock?
-- -----------------------------------------------------------------------------
-- [SCREEN] Dashboard > Website stock.
-- [SAY] "The website still shows the numbers from the last sync. The
--        warehouse compares them with real store stock."
SELECT product_code, product_name, online_shown AS website_stock,
       actual_in_store AS actual_store_stock, overstated_by AS discrepancy, status
  FROM dw.rpt_online_vs_actual
 WHERE status <> 'in sync'
 ORDER BY product_code;
-- EXPECTED: P001 website 183 vs actual 203 (-20, understated - lost sales risk)
--           P018 website 2   vs actual 0   (+2,  overstated - oversell risk)
SELECT last_sync_at AT TIME ZONE 'Australia/Sydney' AS last_sync_sydney, time_since_sync, scheduler_status, pending_events,
       pending_sales, pending_supplier_deliveries, pending_checkout_blocks, products_out_of_date
  FROM dw.rpt_online_staleness;
-- EXPECTED: pending_events 4 (2 sales, 1 delivery, 1 blocked checkout), 2 products out of date.

-- 5.Q2b | >>> WRITE (Online system): the operational sync corrects the website.
-- [SCREEN] Dashboard > Demo actions > "Sync website stock now", or run:
SELECT online.sync_website_stock() AS sync_no;

-- Sync correction, recorded by the warehouse (before -> after):
SELECT store_or_channel, product_code, measure, before_qty, after_qty, difference
  FROM dw.rpt_last_sync_changes
 WHERE measure = 'online_available'
 ORDER BY product_code;
-- EXPECTED: P001 183 -> 203 (+20), P018 2 -> 0 (-2).
SELECT product_code, online_shown, actual_in_store, status
  FROM dw.rpt_online_vs_actual WHERE product_code IN ('P001', 'P018') ORDER BY product_code;
-- EXPECTED: both in sync.
-- [SAY] "The operational sync corrects the website stock; the warehouse
--        records and analyses the discrepancy."

-- -----------------------------------------------------------------------------
-- Q3. What is the business impact?
-- -----------------------------------------------------------------------------
-- [SCREEN] Dashboard > Orders & lost sales.
-- [SAY] "Website showed stock -> customer attempted checkout -> real stock
--        was insufficient -> checkout blocked -> event captured for analysis."
SELECT basket, attempted_at AT TIME ZONE 'Australia/Sydney' AS attempted_sydney, product_code, product_name, quantity_in_bag,
       pickup_store, website_showed, actual_combined_at_checkout, reason
  FROM dw.rpt_checkout_blocked
 ORDER BY attempted_at DESC
 LIMIT 3;
-- EXPECTED (top row): basket 9, P018, quantity 1, pickup Bondi, website_showed 2,
--           actual 0, reason 'stock sold since last sync - online number was stale'.
--           (2nd row basket 5 is from the seed history.)

-- Source record from the online system for the same attempt:
SELECT a.attempt_no, a.basket_id, a.outcome, a.attempted_at AT TIME ZONE 'Australia/Sydney' AS attempted_sydney,
       i.item_no, i.quantity, i.website_qty_shown, i.result
  FROM online.checkout_attempt a
  JOIN online.checkout_attempt_item i USING (attempt_no)
 WHERE a.attempt_no = (SELECT max(attempt_no) FROM online.checkout_attempt);
-- EXPECTED: attempt 9, basket 9, outcome blocked, P018, website_qty_shown 2, result unavailable.
-- [SAY] "The warehouse does not block the checkout - the operational system
--        does. The warehouse lets PetHaven analyse these checkout events
--        together with inventory. A blocked checkout is a potential lost
--        sale, not a confirmed one."


-- =============================================================================
-- 6. DATA INTEGRATION / TRACEABILITY                               (~1 min)
-- =============================================================================
-- [SCREEN] Dashboard > Data & integration (ETL runs, staging, data quality,
--          reconciliation, trace). Then CloudBeaver.

-- 6.1 | TRACE A DASHBOARD RESULT BACK: Q3 blocked item -> fact -> staging -> source.
SELECT r.basket            AS report_q3_basket,
       r.product_code      AS report_product,
       f.event_id          AS dw_event,
       f.source_system,
       f.source_ref,
       s.stg_id            AS staging_row,
       s.load_status,
       s.etl_run_id,
       a.attempt_no        AS online_source_attempt,
       a.outcome           AS online_source_outcome
  FROM dw.rpt_checkout_blocked r
  JOIN dw.fact_stock_event f ON f.event_type = 'checkout_blocked'
                            AND f.order_ref = r.basket AND f.event_ts = r.attempted_at
  JOIN dw.dim_product dp     ON dp.product_key = f.product_key AND dp.product_code = r.product_code
  JOIN etl.stg_checkout_item s ON s.event_id = f.event_id
  JOIN online.checkout_attempt a ON a.attempt_no = s.attempt_no
 ORDER BY r.attempted_at DESC
 LIMIT 1;
-- EXPECTED: basket 9 / P018 -> dw event -> staging row (loaded) -> online attempt 9 (blocked).

-- 6.2 | RECONCILIATION: warehouse totals vs the live store system.
SELECT status, count(*) AS store_product_pairs
  FROM dw.rpt_reconciliation GROUP BY status;
-- EXPECTED: match 90 (18 products x 5 stores) - nothing else.

-- 6.3 | DATA QUALITY: rejected source rows (validation before loading).
SELECT source_system, source_ref, reject_reason, captured_at
  FROM etl.v_data_quality;
-- EXPECTED: no rows.

-- 6.4 | OPTIONAL validation test (+1 min) - an item the warehouse does not know.
--  >>> WRITE: a delivery and a sale of P019, which is NOT on the warehouse product list.
-- SELECT supply.record_supplier_delivery('NSW-PARRA', 'SUP-02', 'PO-3002', ARRAY['P019'], ARRAY[2]);
-- SELECT store_ops.record_sale('101', ARRAY['P019'], ARRAY[1]);
-- SELECT source_system, source_ref, reject_reason FROM etl.v_data_quality;   -- 2 rows: Unknown item P019
-- SELECT * FROM dw.rpt_reconciliation WHERE status <> 'match';                 -- store has stock the DW lacks
--  >>> WRITE: the data steward approves the item, the next ETL pass loads the waiting rows.
-- SELECT etl.add_item('P019');
-- SELECT etl.run_etl();
-- SELECT count(*) AS still_rejected FROM etl.v_data_quality;                   -- 0
-- [SAY] "The dashboard is not simply reading one operational system. Its
--        results are supported by the ETL and warehouse integration layer."


-- =============================================================================
-- 7. FINAL SUMMARY + END-TO-END TEST RESULT                        (~1 min)
-- =============================================================================
-- 7.1 | AUTOMATIC TEST SUMMARY: every row must say PASS.
WITH po AS (
    SELECT s.*, f.units AS dw_units, f.event_ts, ds.store_code
      FROM etl.stg_supplier_delivery_line s
      JOIN dw.fact_stock_event f ON f.event_id = s.event_id
      JOIN dw.dim_store ds       ON ds.store_key = f.store_key
     WHERE s.supplier_order_no = 'PO-3001'
), blocked AS (
    SELECT * FROM dw.rpt_checkout_blocked ORDER BY attempted_at DESC LIMIT 1
), checks(test_no, test, passed) AS (
    SELECT 'T1', 'Supplier: 5 cartons loaded as 20 units',
           (SELECT bool_and(cartons * units_per_carton = dw_units AND dw_units = 20) FROM po)
    UNION ALL
    SELECT 'T2', 'Supplier: NSW-CHATS mapped to S03',
           (SELECT bool_and(store_code = 'S03') FROM po)
    UNION ALL
    SELECT 'T3', 'Supplier: UTC converted to Sydney time',
           (SELECT bool_and(event_ts = delivered_at_utc AT TIME ZONE 'UTC'
                            AND date_trunc('day', (delivered_at_utc AT TIME ZONE 'UTC') AT TIME ZONE 'Australia/Sydney')::date
                                = (SELECT full_date FROM dw.dim_date d JOIN dw.fact_stock_event f ON f.date_key = d.date_key WHERE f.event_id = po.event_id))
              FROM po)
    UNION ALL
    SELECT 'T4', 'Store: P018 sales at S04 and S05 in warehouse',
           (SELECT count(DISTINCT ds.store_code) = 2
              FROM dw.fact_stock_event f JOIN dw.dim_store ds USING (store_key) JOIN dw.dim_product dp USING (product_key)
             WHERE f.event_type = 'store_sale' AND dp.product_code = 'P018' AND ds.store_code IN ('S04', 'S05')
               AND f.event_id > (SELECT max(event_id) FROM po))
    UNION ALL
    SELECT 'T5', 'Online: blocked checkout captured (stale website)',
           (SELECT product_code = 'P018' AND website_showed = 2 AND actual_combined_at_checkout = 0
                   AND reason LIKE 'stock sold since last sync%' FROM blocked)
    UNION ALL
    SELECT 'T6', 'Q1: warehouse stock = store system (P001 Chatswood)',
           (SELECT r.in_store_quantity = ss.in_store_quantity
              FROM dw.rpt_current_stock_by_store r, store_ops.store_stock ss
             WHERE r.store_code = 'S03' AND r.product_code = 'P001' AND ss.store_no = '103' AND ss.item_no = 'P001')
    UNION ALL
    SELECT 'T7', 'Q2: sync corrected website; all products in sync',
           (SELECT count(*) = 0 FROM dw.rpt_online_vs_actual WHERE status <> 'in sync')
    UNION ALL
    SELECT 'T8', 'Traceability: no staging row left pending',
           (SELECT count(*) = 0 FROM etl.v_staging WHERE load_status NOT IN ('loaded', 'skipped'))
    UNION ALL
    SELECT 'T9', 'Reconciliation: warehouse matches store system',
           (SELECT count(*) = 0 FROM dw.rpt_reconciliation WHERE status <> 'match')
    UNION ALL
    SELECT 'T10', 'Data quality: no rejected source rows',
           (SELECT count(*) = 0 FROM etl.v_data_quality)
)
SELECT test_no, test, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
  FROM checks
 ORDER BY length(test_no), test_no;
-- EXPECTED: T1-T10 all PASS.

-- [SCREEN] Finish on Dashboard > Overview.
-- [SAY] "PetHaven's operational systems generate inventory data separately
--        across Supplier, Store and Online. This prototype uses ETL, data
--        transformation, approved mappings and a Data Warehouse to integrate
--        these records into one analytical model. The Dashboard then shows
--        where stock is available or reserved, which stores are low, how
--        inaccurate the website is, and the impact on checkout outcomes -
--        and every number traces back to its source record."
--
--   Supplier -+
--   Store ----+--> ETL --> Data Warehouse --> Dashboard
--   Online ---+                                |-- Q1 Stock position
--                                              |-- Q4 Low-stock stores
--                                              |-- Q2 Stock discrepancy
--                                              +-- Q3 Business impact
--
-- TIMING: 1 Problem 1:00 | 2 Sources 1:00 | 3 ETL 2:00 | 4 DW 1:00 |
--         5 Q1 1:00, Q4 0:30, Q2 1:00, Q3 1:00 | 6 Trace 1:00 | 7 Summary 0:30
--         = about 10 minutes (+1 min with the optional 6.4).
-- To record another take: rebuild (build.py), reconnect CloudBeaver, start at 0.1.
-- =============================================================================
