-- =============================================================================
-- demo/cloudbeaver_demo.sql
-- Purpose: Step-by-step demonstration to run in CloudBeaver (or psql) against
--          the database pethaven_demo. Run one statement at a time
--          (select it, Ctrl+Enter) and talk through the result.
-- Before you start: rebuild a clean database from the repository root with
--   docker compose exec python python /workspace/scripts/build.py
-- then reconnect CloudBeaver. Check: SELECT current_database();  -> pethaven_demo
--
-- PART A (the video): a customer buys in a store (offline) and the website
--   number catches up at the next sync. Steps A0-A4, optional A5.
-- PART B (additional checks): the rest of the prototype - supplier
--   deliveries, online checkout, transfers, data quality, reports.
-- Script order follows docs/demo_runbook.md. The numbers in the comments are
-- what a fresh build shows.
-- =============================================================================


-- =============================================================================
-- PART A. VIDEO: an in-store sale, then the website refreshes
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A0. Ready? Right database, and the automatic sync NOT running (otherwise it
--     could fix the website before you have shown it out of date).
-- -----------------------------------------------------------------------------
SELECT current_database();                                       -- pethaven_demo
SELECT scheduler_status FROM dw.rpt_online_staleness;            -- 'never started' or 'stopped'
-- Only if it says 'running': stop it from here (it stops within 2 seconds).
UPDATE online.sync_schedule SET status = 'stop_requested' WHERE status = 'running';


-- -----------------------------------------------------------------------------
-- A1. Before: the website and the stores agree on P001 (dog food).
-- -----------------------------------------------------------------------------
-- What an online customer sees: one combined number for all five stores.
SELECT p.item_no, p.title, s.available_quantity AS website_shows, s.last_synced_at
  FROM online.product p JOIN online.online_stock s USING (item_no)
 WHERE p.item_no = 'P001';                                       -- 183

-- What is really on the shelves, store by store (store system).
SELECT st.store_no, st.store_name, ss.in_store_quantity, ss.reserved_quantity
  FROM store_ops.store_stock ss JOIN store_ops.store st USING (store_no)
 WHERE ss.item_no = 'P001'
 ORDER BY st.store_no;                                           -- Parramatta 37; total 183

-- Side by side: in sync.
SELECT product_code, product_name, online_shown, actual_in_store, overstated_by, status
  FROM dw.rpt_online_vs_actual WHERE product_code = 'P001';      -- 183 / 183, in sync


-- -----------------------------------------------------------------------------
-- A2. A customer buys 3 bags of P001 at the Parramatta till (store 101).
-- -----------------------------------------------------------------------------
SELECT store_ops.record_sale('101', ARRAY['P001'], ARRAY[3]);   -- returns the receipt number


-- -----------------------------------------------------------------------------
-- A3. The store changed at once; the website did not.
-- -----------------------------------------------------------------------------
-- Parramatta's shelf dropped straight away: 37 -> 34.
SELECT st.store_no, st.store_name, ss.in_store_quantity, ss.updated_at
  FROM store_ops.store_stock ss JOIN store_ops.store st USING (store_no)
 WHERE ss.item_no = 'P001' AND ss.store_no = '101';

-- The warehouse already has the sale too, traced to the receipt number.
SELECT f.event_type, s.store_code, p.product_code, f.quantity_change, f.source_ref
  FROM dw.fact_stock_event f JOIN dw.dim_store s USING (store_key) JOIN dw.dim_product p USING (product_key)
 ORDER BY f.event_id DESC LIMIT 1;                               -- store_sale, S01, -3, STORE:receipt ...

-- But the website still shows 183: the stores have only 180.
SELECT p.item_no, s.available_quantity AS website_shows, s.last_synced_at
  FROM online.product p JOIN online.online_stock s USING (item_no)
 WHERE p.item_no = 'P001';                                       -- still 183
SELECT product_code, online_shown, actual_in_store, overstated_by, status
  FROM dw.rpt_online_vs_actual WHERE product_code = 'P001';      -- 183 / 180, overstated by 3
SELECT last_sync_at, time_since_sync, pending_events, products_out_of_date
  FROM dw.rpt_online_staleness;                                  -- 1 event waiting for the sync


-- -----------------------------------------------------------------------------
-- A4. The website refreshes: the sync takes the real shelf totals from the
--     store system. The scheduler runs exactly this every 3 minutes; here it
--     is run by hand so it happens on camera ("run sync now").
-- -----------------------------------------------------------------------------
SELECT online.sync_website_stock();                              -- returns the sync number

SELECT p.item_no, s.available_quantity AS website_shows, s.last_synced_at
  FROM online.product p JOIN online.online_stock s USING (item_no)
 WHERE p.item_no = 'P001';                                       -- now 180, synced just now
SELECT product_code, online_shown, actual_in_store, overstated_by, status
  FROM dw.rpt_online_vs_actual WHERE product_code = 'P001';      -- 180 / 180, in sync

-- The warehouse's record of that sync: what it changed, before -> after.
SELECT sync_id, run_at, triggered_by, events_processed, numbers_changed, store_mismatches
  FROM dw.sync_run ORDER BY sync_id DESC LIMIT 1;                -- manual, 1 event, 0 mismatches
SELECT store_or_channel, product_code, measure, before_qty, after_qty, difference
  FROM dw.rpt_last_sync_changes ORDER BY measure, product_code, store_or_channel;
                                                                 -- Parramatta 37 -> 34, website 183 -> 180


-- -----------------------------------------------------------------------------
-- A5. (Optional) The same, with nobody pressing anything: the automatic sync
--     every 3 minutes. Start it in a terminal (it is a small program, not SQL):
--       docker compose exec python python /workspace/scripts/demo.py scheduler start
-- -----------------------------------------------------------------------------
SELECT scheduler_status, sync_interval, last_sync_at, next_sync_at
  FROM dw.rpt_online_staleness;                                  -- running, 00:03:00, next sync at ...
SELECT store_ops.record_sale('101', ARRAY['P001'], ARRAY[2]);   -- another in-store sale
SELECT product_code, online_shown, actual_in_store, status
  FROM dw.rpt_online_vs_actual WHERE product_code = 'P001';      -- 180 / 178, overstated
-- ... wait until next_sync_at has passed (at most 3 minutes), then run again:
SELECT product_code, online_shown, actual_in_store, status
  FROM dw.rpt_online_vs_actual WHERE product_code = 'P001';      -- 178 / 178, in sync
SELECT sync_id, run_at, triggered_by, events_processed
  FROM dw.sync_run ORDER BY sync_id DESC LIMIT 1;                -- triggered_by = scheduled
-- Stop it again before Part B (or in the terminal: demo.py scheduler stop).
UPDATE online.sync_schedule SET status = 'stop_requested' WHERE status = 'running';


-- =============================================================================
-- PART B. ADDITIONAL CHECKS: the rest of the prototype
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Three systems, one item number, three transaction IDs, one warehouse
-- -----------------------------------------------------------------------------
-- Every system uses the same item number for a product (P001); the barcode,
-- units per carton and web title are just attributes.
SELECT item_no, description, barcode, shelf_price FROM store_ops.product WHERE item_no = 'P001';
SELECT item_no, item_description, supplier_id, units_per_carton FROM supply.item WHERE item_no = 'P001';
SELECT item_no, title, web_price FROM online.product WHERE item_no = 'P001';
SELECT * FROM etl.v_item_list ORDER BY item_no;                 -- P019 is not on the warehouse product list

-- Store codes still differ per system, so they are mapped to S01..S05.
SELECT * FROM etl.v_store_codes ORDER BY store_code;

-- Each system has its own transaction ID: receipt number (in-store),
-- supplier ID + supplier order number (supplier), order ID (online).
SELECT * FROM supply.supplier ORDER BY supplier_id;

-- Starting point: website in sync, nothing pending, warehouse = stores.
SELECT * FROM dw.rpt_online_staleness;
SELECT status, count(*) FROM dw.rpt_reconciliation GROUP BY status;


-- -----------------------------------------------------------------------------
-- 1. In-store sale (Source 1): 3 items on one receipt at Parramatta (store 101)
--    P003 x2, P005 x1, P009 x1
-- -----------------------------------------------------------------------------
SELECT item_no, in_store_quantity, reserved_quantity
  FROM store_ops.store_stock
 WHERE store_no = '101' AND item_no IN ('P003', 'P005', 'P009')
 ORDER BY item_no;

SELECT store_ops.record_sale('101', ARRAY['P003', 'P005', 'P009'], ARRAY[2, 1, 1]);   -- returns the receipt number

-- Shelf dropped immediately ...
SELECT item_no, in_store_quantity, reserved_quantity
  FROM store_ops.store_stock
 WHERE store_no = '101' AND item_no IN ('P003', 'P005', 'P009')
 ORDER BY item_no;

-- ... the ETL extracted the 3 lines (store 101) and loaded 3 facts (store S01),
-- each traced to the receipt number ...
SELECT stg_id, sale_no AS receipt_number, line_no, store_no, item_no, quantity, load_status, event_id
  FROM etl.stg_store_sale_line ORDER BY stg_id DESC LIMIT 3;
SELECT f.event_id, f.event_type, s.store_code, p.product_code, f.quantity_change, f.source_ref, f.etl_run_id
  FROM dw.fact_stock_event f JOIN dw.dim_store s USING (store_key) JOIN dw.dim_product p USING (product_key)
 ORDER BY f.event_id DESC LIMIT 3;

-- ... but the website still shows the old numbers.
SELECT * FROM dw.rpt_online_vs_actual WHERE status <> 'in sync';


-- -----------------------------------------------------------------------------
-- 2. Supplier delivery (Source 2): supplier SUP-01, supplier order PO-2001,
--    5 cartons of dog food to Chatswood. Recorded in cartons and UTC;
--    arrives on the shelf as units.
-- -----------------------------------------------------------------------------
SELECT supply.record_supplier_delivery('NSW-CHATS', 'SUP-01', 'PO-2001', ARRAY['P001'], ARRAY[5]);

SELECT supplier_id, supplier_order_no, location_code, item_no, cartons, units_per_carton, delivered_at_utc, load_status
  FROM etl.stg_supplier_delivery_line ORDER BY stg_id DESC LIMIT 1;
SELECT event_type, units, event_ts, date_key, source_ref
  FROM dw.fact_stock_event ORDER BY event_id DESC LIMIT 1;      -- 5 cartons x 4 = 20 units, Sydney time


-- -----------------------------------------------------------------------------
-- 3. Online shopping (Source 3): bag -> pickup options -> checkout.
--    Adding to the bag changes nothing. The customer is offered every store
--    that holds at least one bag item (fewest transfers first) and picks one;
--    items that store lacks come from the next-nearest store and are
--    transferred. Checkout checks REAL store stock BEFORE payment; if any
--    item is unavailable, nothing is charged and the bag stays open.
-- -----------------------------------------------------------------------------
-- 3a. One item: Bondi customer (2026) buys 2 x P001 -> paid, held at Bondi.
SELECT online.place_online_order('2026', 'P001', 2);                      -- bag 9 -> order ID 8
SELECT * FROM online.web_order_line WHERE order_no = 8;
SELECT * FROM online.online_stock WHERE item_no = 'P001';                 -- website lowered by 2 at once

-- 3b. Bag with three items: duck (Bondi has it), aquarium kit (Bondi has
--     none, Newtown has 1) and 2 dog beds (no single store has 2).
SELECT store_no, item_no, in_store_quantity, reserved_quantity FROM store_ops.store_stock
 WHERE item_no IN ('P009', 'P018', 'P013') ORDER BY item_no, store_no;
SELECT online.create_basket('2026');                                      -- bag 10
SELECT online.add_to_basket(10, 'P009', 1);
SELECT online.add_to_basket(10, 'P018', 1);
SELECT online.add_to_basket(10, 'P013', 2);
SELECT * FROM online.basket_item WHERE basket_id = 10;                    -- the website showed them in stock

SELECT online.checkout(10);                                               -- NULL = BLOCKED before payment
SELECT a.attempt_no, a.outcome, a.pickup_cp_code, i.item_no, i.quantity, i.website_qty_shown, i.result, i.source_cp_code
  FROM online.checkout_attempt a JOIN online.checkout_attempt_item i USING (attempt_no)
 WHERE a.basket_id = 10 ORDER BY a.attempt_no, i.item_no;               -- beds unavailable; nothing held
SELECT * FROM dw.rpt_checkout_blocked WHERE basket = 'basket 10';         -- reason: split across stores

-- The customer removes the beds and looks at the pickup options:
-- Newtown has both items (no transfer); Bondi has the duck (kit transferred).
SELECT online.remove_from_basket(10, 'P013');
SELECT * FROM online.pickup_options(10);
SELECT online.checkout(10, 'CP-BONDI-JUNCTION');                         -- chooses Bondi -> order ID 9
SELECT * FROM online.web_order_line WHERE order_no = 9;                   -- duck from Bondi, kit from Newtown
SELECT * FROM store_ops.reservation WHERE web_order_ref = '9';

-- 3c. Transfer: Newtown sends the kit, Bondi receives it.
SELECT * FROM dw.rpt_open_reservations WHERE order_no = '9';              -- kit waiting to be sent
SELECT store_ops.dispatch_order_transfers('9');
SELECT * FROM dw.rpt_open_reservations WHERE order_no = '9';              -- in transit
SELECT store_ops.collect_order('9');                                      -- refused: not arrived yet
SELECT store_ops.receive_order_transfers('9');
SELECT * FROM dw.rpt_open_reservations WHERE order_no = '9';              -- ready for collection
-- Every step of the order traces to its order ID (STORE:order 9 line ...).
SELECT f.event_type, s.store_code, pk.store_code AS pickup, f.quantity_change, f.reserved_change, f.source_ref
  FROM dw.fact_stock_event f JOIN dw.dim_store s USING (store_key)
  LEFT JOIN dw.dim_store pk ON pk.store_key = f.pickup_store_key
 WHERE f.order_ref = '9' ORDER BY f.event_id;


-- -----------------------------------------------------------------------------
-- 4. Staleness, then RUN SYNC NOW (manual), then before/after
-- -----------------------------------------------------------------------------
SELECT * FROM dw.rpt_online_staleness;
SELECT * FROM dw.rpt_online_vs_actual WHERE status <> 'in sync';

SELECT online.sync_website_stock();

SELECT * FROM dw.sync_run ORDER BY sync_id DESC LIMIT 1;        -- triggered_by = manual
SELECT * FROM dw.rpt_last_sync_changes ORDER BY measure, product_code, store_or_channel;
SELECT * FROM dw.rpt_online_staleness;                          -- pending 0, out of date 0


-- -----------------------------------------------------------------------------
-- 5. Stale website: sell the last aquarium kit in store, then try to buy it
--    online before the next sync. The website still shows it, so it goes in
--    the bag - but checkout blocks it before payment.
-- -----------------------------------------------------------------------------
SELECT store_no, in_store_quantity, reserved_quantity FROM store_ops.store_stock WHERE item_no = 'P018' ORDER BY store_no;
SELECT store_ops.record_sale('105', ARRAY['P018'], ARRAY[1]);
SELECT * FROM online.online_stock WHERE item_no = 'P018';                 -- still says 1
SELECT online.place_online_order('2026', 'P018', 1);                      -- NULL: blocked, nothing charged
SELECT * FROM dw.rpt_checkout_blocked ORDER BY attempted_at;             -- reason: stale website number


-- -----------------------------------------------------------------------------
-- 6. Click and collect: finish the seed's 3-item order 5; the overdue job
--    cancels order 3 (not collected within 3 days)
-- -----------------------------------------------------------------------------
SELECT * FROM dw.rpt_open_reservations ORDER BY order_no, product_code;  -- order 5 in transit, order 3 overdue
SELECT store_ops.receive_order_transfers('5');
SELECT store_ops.collect_order('5');
SELECT store_ops.cancel_overdue_orders();                                 -- 1: beds back on Parramatta's shelf
SELECT web_order_ref, status, cancel_reason FROM store_ops.reservation WHERE web_order_ref = '3';
SELECT store_ops.collect_order('9');
SELECT * FROM dw.rpt_open_reservations ORDER BY order_no, product_code;


-- -----------------------------------------------------------------------------
-- 7. Data quality: an item the warehouse does not know yet (P019)
-- -----------------------------------------------------------------------------
SELECT supply.record_supplier_delivery('NSW-PARRA', 'SUP-02', 'PO-2002', ARRAY['P019'], ARRAY[2]);
SELECT store_ops.record_sale('101', ARRAY['P019'], ARRAY[1]);

SELECT * FROM etl.v_data_quality;                               -- rejected: Unknown item P019
SELECT * FROM dw.rpt_reconciliation WHERE status <> 'match';    -- store has stock the warehouse lacks

-- Data steward adds the item to the warehouse product list; the next ETL
-- pass loads the waiting rows.
SELECT etl.add_item('P019');
SELECT etl.run_etl();
SELECT * FROM etl.v_data_quality;                               -- empty
SELECT * FROM etl.etl_run ORDER BY etl_run_id DESC LIMIT 5;


-- -----------------------------------------------------------------------------
-- 8. The reports
-- -----------------------------------------------------------------------------
SELECT * FROM dw.rpt_current_stock_by_store WHERE store_code = 'S01' ORDER BY product_code;  -- Report 1
SELECT * FROM dw.rpt_online_staleness;                                                    -- Report 2
SELECT * FROM dw.rpt_checkout_blocked ORDER BY attempted_at;                              -- Report 3
SELECT * FROM dw.rpt_daily_sales ORDER BY full_date, store_name, channel, category;       -- Report 4
SELECT * FROM dw.rpt_open_reservations ORDER BY reserved_at;                              -- Report 5
SELECT * FROM dw.rpt_reconciliation WHERE status <> 'match';                              -- Report 6

-- Finish with a sync so the website is correct again.
SELECT online.sync_website_stock();
SELECT * FROM dw.rpt_last_sync_changes ORDER BY measure, product_code, store_or_channel;
-- (The automatic sync is shown in Part A, step A5.)
