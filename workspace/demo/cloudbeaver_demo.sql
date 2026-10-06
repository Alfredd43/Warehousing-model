-- =============================================================================
-- demo/cloudbeaver_demo.sql
-- Purpose: Step-by-step demonstration to run in CloudBeaver (or psql) against
--          the database pethaven_demo. Run one statement at a time
--          (select it, Ctrl+Enter) and talk through the result.
-- Before you start: rebuild a clean database from the repository root with
--   docker compose exec python python /workspace/scripts/build.py
-- then reconnect CloudBeaver. Check: SELECT current_database();  -> pethaven_demo
-- Script order follows docs/demo_runbook.md.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Three systems, three sets of codes, one warehouse
-- -----------------------------------------------------------------------------
SELECT * FROM etl.v_store_codes   ORDER BY store_code;
SELECT * FROM etl.v_product_codes ORDER BY product_code;

-- The same product as each system sees it:
SELECT barcode, description, shelf_price FROM store_ops.product WHERE barcode = '9300601001019';
SELECT supplier_sku, item_description, units_per_carton FROM supply.item WHERE supplier_sku = 'PF-DOG-ADT-3K';
SELECT web_sku, title, web_price FROM online.product WHERE web_sku = 'WEB-10001';

-- Starting point: website in sync, nothing pending, warehouse = stores.
SELECT * FROM dw.rpt_online_staleness;
SELECT status, count(*) FROM dw.rpt_reconciliation GROUP BY status;


-- -----------------------------------------------------------------------------
-- 1. In-store sale (Source 1): 3 items on one receipt at Parramatta (store 101)
--    P003 x2, P005 x1, P009 x1
-- -----------------------------------------------------------------------------
SELECT barcode, in_store_quantity, reserved_quantity
  FROM store_ops.store_stock
 WHERE store_no = '101' AND barcode IN ('9300601001033', '9300601001057', '9300601001095')
 ORDER BY barcode;

SELECT store_ops.record_sale('101',
       ARRAY['9300601001033', '9300601001057', '9300601001095'],
       ARRAY[2, 1, 1]);

-- Shelf dropped immediately ...
SELECT barcode, in_store_quantity, reserved_quantity
  FROM store_ops.store_stock
 WHERE store_no = '101' AND barcode IN ('9300601001033', '9300601001057', '9300601001095')
 ORDER BY barcode;

-- ... the ETL extracted the 3 lines (store codes) and loaded 3 facts (warehouse codes) ...
SELECT stg_id, sale_no, line_no, store_no, barcode, quantity, load_status, event_id
  FROM etl.stg_store_sale_line ORDER BY stg_id DESC LIMIT 3;
SELECT f.event_id, f.event_type, s.store_code, p.product_code, f.quantity_change, f.source_ref, f.etl_run_id
  FROM dw.fact_stock_event f JOIN dw.dim_store s USING (store_key) JOIN dw.dim_product p USING (product_key)
 ORDER BY f.event_id DESC LIMIT 3;

-- ... but the website still shows the old numbers.
SELECT * FROM dw.rpt_online_vs_actual WHERE status <> 'in sync';


-- -----------------------------------------------------------------------------
-- 2. Supplier delivery (Source 2): 5 cartons of dog food to Chatswood.
--    Recorded in cartons and UTC; arrives on the shelf as units.
-- -----------------------------------------------------------------------------
SELECT supply.record_supplier_delivery('NSW-CHATS', 'Pawfect Foods', ARRAY['PF-DOG-ADT-3K'], ARRAY[5]);

SELECT delivery_no, location_code, supplier_sku, cartons, units_per_carton, delivered_at_utc, load_status
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
-- 3a. One item: Bondi customer (2026) buys 2 x WEB-10001 -> paid, held at Bondi.
SELECT online.place_online_order('2026', 'WEB-10001', 2);                 -- bag 9 -> order 8
SELECT * FROM online.web_order_line WHERE order_no = 8;
SELECT * FROM online.online_stock WHERE web_sku = 'WEB-10001';           -- website lowered by 2 at once

-- 3b. Bag with three items: duck (Bondi has it), aquarium kit (Bondi has
--     none, Newtown has 1) and 2 dog beds (no single store has 2).
SELECT store_no, barcode, in_store_quantity, reserved_quantity FROM store_ops.store_stock
 WHERE barcode IN ('9300601001095', '9300601001187', '9300601001132') ORDER BY barcode, store_no;
SELECT online.create_basket('2026');                                      -- bag 10
SELECT online.add_to_basket(10, 'WEB-10009', 1);
SELECT online.add_to_basket(10, 'WEB-10018', 1);
SELECT online.add_to_basket(10, 'WEB-10013', 2);
SELECT * FROM online.basket_item WHERE basket_id = 10;                    -- the website showed them in stock

SELECT online.checkout(10);                                               -- NULL = BLOCKED before payment
SELECT a.attempt_no, a.outcome, a.pickup_cp_code, i.web_sku, i.quantity, i.website_qty_shown, i.result, i.source_cp_code
  FROM online.checkout_attempt a JOIN online.checkout_attempt_item i USING (attempt_no)
 WHERE a.basket_id = 10 ORDER BY a.attempt_no, i.web_sku;               -- beds unavailable; nothing held
SELECT * FROM dw.rpt_checkout_blocked WHERE basket = 'basket 10';         -- reason: split across stores

-- The customer removes the beds and looks at the pickup options:
-- Newtown has both items (no transfer); Bondi has the duck (kit transferred).
SELECT online.remove_from_basket(10, 'WEB-10013');
SELECT * FROM online.pickup_options(10);
SELECT online.checkout(10, 'CP-BONDI-JUNCTION');                         -- chooses Bondi -> order 9
SELECT * FROM online.web_order_line WHERE order_no = 9;                   -- duck from Bondi, kit from Newtown
SELECT * FROM store_ops.reservation WHERE web_order_ref = '9';

-- 3c. Transfer: Newtown sends the kit, Bondi receives it.
SELECT * FROM dw.rpt_open_reservations WHERE order_no = '9';              -- kit waiting to be sent
SELECT store_ops.dispatch_order_transfers('9');
SELECT * FROM dw.rpt_open_reservations WHERE order_no = '9';              -- in transit
SELECT store_ops.collect_order('9');                                      -- refused: not arrived yet
SELECT store_ops.receive_order_transfers('9');
SELECT * FROM dw.rpt_open_reservations WHERE order_no = '9';              -- ready for collection
SELECT f.event_type, s.store_code, pk.store_code AS pickup, f.quantity_change, f.reserved_change, f.source_ref
  FROM dw.fact_stock_event f JOIN dw.dim_store s USING (store_key)
  LEFT JOIN dw.dim_store pk ON pk.store_key = f.pickup_store_key
 WHERE f.order_ref = '9' ORDER BY f.event_id;


-- -----------------------------------------------------------------------------
-- 4. Staleness, then RUN SYNC NOW, then before/after
-- -----------------------------------------------------------------------------
SELECT * FROM dw.rpt_online_staleness;
SELECT * FROM dw.rpt_online_vs_actual WHERE status <> 'in sync';

SELECT online.sync_website_stock();

SELECT * FROM dw.sync_run ORDER BY sync_id DESC LIMIT 1;
SELECT * FROM dw.rpt_last_sync_changes ORDER BY measure, product_code, store_or_channel;
SELECT * FROM dw.rpt_online_staleness;                          -- pending 0, out of date 0


-- -----------------------------------------------------------------------------
-- 5. Stale website: sell the last aquarium kit in store, then try to buy it
--    online before the next sync. The website still shows it, so it goes in
--    the bag - but checkout blocks it before payment.
-- -----------------------------------------------------------------------------
SELECT store_no, in_store_quantity, reserved_quantity FROM store_ops.store_stock WHERE barcode = '9300601001187' ORDER BY store_no;
SELECT store_ops.record_sale('105', ARRAY['9300601001187'], ARRAY[1]);
SELECT * FROM online.online_stock WHERE web_sku = 'WEB-10018';           -- still says 1
SELECT online.place_online_order('2026', 'WEB-10018', 1);                 -- NULL: blocked, nothing charged
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
-- 7. Data quality: a new product the warehouse has not approved yet
-- -----------------------------------------------------------------------------
SELECT supply.record_supplier_delivery('NSW-PARRA', 'PlayPets Wholesale', ARRAY['PP-CAT-TUNNEL'], ARRAY[2]);
SELECT store_ops.record_sale('101', ARRAY['9300601001194'], ARRAY[1]);

SELECT * FROM etl.v_data_quality;                               -- rejected, with the reason
SELECT * FROM dw.rpt_reconciliation WHERE status <> 'match';    -- store has stock the warehouse lacks

-- Data steward approves the mappings; the next ETL pass loads the waiting rows.
SELECT etl.approve_product_mapping('SUPPLY', 'PP-CAT-TUNNEL', 'P019');
SELECT etl.approve_product_mapping('STORE', '9300601001194', 'P019');
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
