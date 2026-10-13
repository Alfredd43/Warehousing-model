# PetHaven Data Warehouse Prototype: End-to-End Test and Demo Runbook

This runbook is the script for the recorded end-to-end testing video (brief item vi.e). It drives one scenario through the three source systems and follows it through ETL, the data warehouse and the dashboard. It ends with an automatic PASS/FAIL summary.

```text
Supplier ─┐
Store ────┼──→ ETL (staging → validation → transformation) ──→ Data Warehouse ──→ Dashboard
Online ───┘                                                                        ├─ Q1 Stock position
                                                                                   ├─ Q4 Low-stock stores
                                                                                   ├─ Q2 Website stock discrepancy
                                                                                   └─ Q3 Business impact
```

**Key message:** the data warehouse does not run checkout or the website sync. Its job is to integrate data from the three systems so PetHaven can analyse inventory from one consistent view.

## Test scenario

| Step | System | Action | What it proves |
|---|---|---|---|
| 1 | Supplier | SUP-01, order PO-3001: 5 cartons of P001 delivered to Chatswood (`NSW-CHATS`) | Cartons → units, UTC → Sydney time, location code → store `S03` |
| 2 | Store | The last aquarium kit (P018) sold at Newtown and at Penrith | Store sales reach the warehouse at once; the website becomes stale |
| 3 | Online | A customer tries to buy 1 × P018 while the website still shows 2 | Checkout is blocked before payment, and the event is captured for analysis |
| 4 | Online | Run the website sync | The website is corrected, and the warehouse records the correction |

## Before recording

1. Start the lab and check that all automated tests pass (`FAIL 0`):
   ```bash
   docker compose up -d
   docker compose exec python python /workspace/tests/check_demo.py
   docker compose exec python python /workspace/tests/check_scheduler.py
   docker compose exec python python /workspace/tests/check_dashboard.py
   ```
2. Build a clean database before **every** take, then reconnect CloudBeaver to `pethaven_demo`:
   ```bash
   docker compose exec python python /workspace/scripts/build.py
   ```
3. Open the dashboard at <http://localhost:8080>. Do **not** start the automatic sync, because it would fix the website before the stale number is shown.
4. Check the starting point:
   ```sql
   SELECT current_database()                                              AS db,
          (SELECT scheduler_status FROM dw.rpt_online_staleness)          AS scheduler,
          (SELECT pending_events   FROM dw.rpt_online_staleness)          AS pending,
          (SELECT count(*) FROM dw.rpt_reconciliation WHERE status <> 'match') AS gaps,
          (SELECT count(*) FROM supply.supplier_delivery WHERE supplier_order_no = 'PO-3001') AS po_used;
   ```
   Expected: `pethaven_demo | never started | 0 | 0 | 0`. If anything differs, rebuild.

Run each SQL block in CloudBeaver one statement at a time. Steps marked **WRITE** change data; everything else is read-only.

## 1. Business problem (1:00)

**Screen:** Dashboard → Overview.

**Say:** "PetHaven sells through five Sydney stores and a website. Its inventory data is split across three systems: Supplier, Store and Online. The visible symptom is that website stock can be stale between syncs. The real problem is that the data is fragmented, so there is no single view of stock, its discrepancies or their impact. We now test the prototype end to end."

## 2. Three source systems (1:00)

**Screen:** CloudBeaver. **Say:** "One process, three systems, three formats."

```sql
-- Store system: shelf and reserved stock per store number
SELECT store_no, item_no, in_store_quantity AS shelf, reserved_quantity AS reserved
  FROM store_ops.store_stock WHERE item_no IN ('P001', 'P018') ORDER BY item_no, store_no;

-- Online system: one combined website number per product
SELECT item_no, available_quantity AS website_shows FROM online.online_stock
 WHERE item_no IN ('P001', 'P018') ORDER BY item_no;
```

Expected: P001 shelf 37/27/53/20/46 (total 183); P018 only 1 at Newtown (104) and 1 at Penrith (105). Website: P001 183, P018 2.

## 3. ETL and data transformation (2:00)

**Example 1: supplier delivery.**

```sql
-- WRITE (Supplier): 5 cartons of P001 to Chatswood
SELECT supply.record_supplier_delivery('NSW-CHATS', 'SUP-01', 'PO-3001', ARRAY['P001'], ARRAY[5]);

-- Before / after: staging keeps the source format; the rules give the warehouse values
SELECT s.cartons, s.units_per_carton, s.cartons * s.units_per_carton AS units,
       s.location_code, x.store_code,
       s.delivered_at_utc,
       (s.delivered_at_utc AT TIME ZONE 'UTC') AT TIME ZONE 'Australia/Sydney' AS sydney_time,
       s.load_status, s.source_ref
  FROM etl.stg_supplier_delivery_line s
  LEFT JOIN etl.store_xref x ON x.source_system = 'SUPPLY' AND x.source_code = s.location_code
 WHERE s.supplier_order_no = 'PO-3001';

-- Approved mapping: one warehouse store code for three operational codes
SELECT store_code, store_name, store_no, location_code, cp_code FROM etl.v_store_codes ORDER BY store_code;
```

Expected: 5 cartons × 4 = **20 units**, `NSW-CHATS` → **S03**, UTC + 11 h = Sydney time, `loaded`.

**Say:** "Cartons become units, UTC becomes Sydney time, and the location code is mapped through an approved mapping before loading."

**Example 2: store and online events.**

```sql
-- WRITE (Store): the last P018 sells at Newtown and at Penrith
SELECT store_ops.record_sale('104', ARRAY['P018'], ARRAY[1]);
SELECT store_ops.record_sale('105', ARRAY['P018'], ARRAY[1]);

-- WRITE (Online): a customer tries to buy 1 x P018; the website still shows 2
SELECT online.place_online_order('2026', 'P018', 1);

-- ETL audit: each source change triggered an ETL run automatically
SELECT etl_run_id, trigger_source, rows_read, rows_loaded, rows_rejected
  FROM etl.etl_run ORDER BY etl_run_id DESC LIMIT 4;
```

Expected: two receipt numbers; the order returns **NULL** (blocked before payment); four new ETL runs with 0 rejected.

## 4. Integrated data warehouse (1:00)

```sql
-- One fact table: events from all three systems in one model
SELECT f.event_id, f.source_system, f.event_type, s.store_code, p.product_code,
       f.quantity_change AS shelf_change, f.units, f.source_ref
  FROM dw.fact_stock_event f
  JOIN dw.dim_store s   ON s.store_key = f.store_key
  JOIN dw.dim_product p ON p.product_key = f.product_key
 ORDER BY f.event_id DESC LIMIT 4;
```

Expected (newest first): ONLINE `checkout_blocked` S02 P018; STORE `store_sale` S05 P018 −1; STORE `store_sale` S04 P018 −1; SUPPLY `supplier_delivery` S03 P001 +20.

**Say:** "The warehouse gives one consistent analytical layer across the three systems, and every row keeps its source reference."

## 5. Dashboard: four business questions (3:30)

Show the dashboard page first, then the view behind it.

**Q1. Where is stock available or reserved?** Dashboard → Store stock (product P001).

```sql
SELECT store_name, in_store_quantity AS available, reserved_quantity AS reserved, total_on_hand
  FROM dw.rpt_current_stock_by_store WHERE product_code = 'P001' ORDER BY store_code;
```

Expected: Chatswood **73** (53 + 20 from PO-3001). Shelf stock is already the available stock, so it is not reduced again by reserved units.

**Q4. Which stores have lower stock?** Dashboard → Store stock, comparing the five stores.

```sql
SELECT store_name, in_store_quantity AS available
  FROM dw.rpt_current_stock_by_store WHERE product_code = 'P001' ORDER BY in_store_quantity;
```

Expected: Newtown 20 (lowest), Bondi 27, Parramatta 37, Penrith 46, Chatswood 73. The dashboard flags low stock; it does not decide replenishment.

**Q2. How inaccurate is website stock?** Dashboard → Website stock.

```sql
SELECT product_code, online_shown AS website, actual_in_store AS actual, overstated_by AS discrepancy, status
  FROM dw.rpt_online_vs_actual WHERE status <> 'in sync' ORDER BY product_code;

-- WRITE (Online): the operational sync corrects the website
SELECT online.sync_website_stock();

SELECT product_code, before_qty, after_qty
  FROM dw.rpt_last_sync_changes WHERE measure = 'online_available' ORDER BY product_code;
```

Expected before sync: P001 183 vs 203 (understated, −20); P018 2 vs 0 (overstated, +2). Sync: P001 183 → 203, P018 2 → 0.

**Say:** "The sync corrects the website; the warehouse measures and records the discrepancy."

**Q3. What is the business impact?** Dashboard → Orders & lost sales.

```sql
SELECT basket, product_code, quantity_in_bag, pickup_store, website_showed,
       actual_combined_at_checkout AS actual, reason
  FROM dw.rpt_checkout_blocked ORDER BY attempted_at DESC LIMIT 1;
```

Expected: P018, website showed 2, actual 0, reason *stock sold since last sync - online number was stale*.

**Say:** "The online system blocks the checkout; the warehouse lets us analyse it with inventory data. A blocked checkout is a potential lost sale, not a confirmed one."

## 6. Traceability (1:00)

Dashboard → Data & integration, then trace the Q3 result back to its source.

```sql
SELECT r.basket, f.event_id, f.source_ref, s.stg_id, s.load_status, a.attempt_no, a.outcome
  FROM dw.rpt_checkout_blocked r
  JOIN dw.fact_stock_event f     ON f.event_type = 'checkout_blocked' AND f.order_ref = r.basket
                                AND f.event_ts = r.attempted_at
  JOIN etl.stg_checkout_item s   ON s.event_id = f.event_id
  JOIN online.checkout_attempt a ON a.attempt_no = s.attempt_no
 ORDER BY r.attempted_at DESC LIMIT 1;
```

Expected: one row linking report → warehouse event → staging row (`loaded`) → online checkout attempt (`blocked`).

## 7. End-to-end test result and summary (0:30)

```sql
WITH po AS (
    SELECT s.cartons, s.units_per_carton, s.delivered_at_utc, s.event_id,
           f.units, f.event_ts, ds.store_code
      FROM etl.stg_supplier_delivery_line s
      JOIN dw.fact_stock_event f ON f.event_id = s.event_id
      JOIN dw.dim_store ds       ON ds.store_key = f.store_key
     WHERE s.supplier_order_no = 'PO-3001'
), blocked AS (
    SELECT * FROM dw.rpt_checkout_blocked ORDER BY attempted_at DESC LIMIT 1
), checks(test_no, test, passed) AS (
              SELECT 1,  'Supplier: 5 cartons loaded as 20 units', (SELECT bool_and(cartons * units_per_carton = units AND units = 20) FROM po)
    UNION ALL SELECT 2,  'Supplier: NSW-CHATS mapped to S03',      (SELECT bool_and(store_code = 'S03') FROM po)
    UNION ALL SELECT 3,  'Supplier: UTC converted correctly',      (SELECT bool_and(event_ts = delivered_at_utc AT TIME ZONE 'UTC') FROM po)
    UNION ALL SELECT 4,  'Store: P018 sales at S04 and S05 loaded',
              (SELECT count(DISTINCT ds.store_code) = 2
                 FROM dw.fact_stock_event f JOIN dw.dim_store ds USING (store_key) JOIN dw.dim_product dp USING (product_key)
                WHERE f.event_type = 'store_sale' AND dp.product_code = 'P018' AND f.event_id > (SELECT max(event_id) FROM po))
    UNION ALL SELECT 5,  'Online: blocked checkout captured',
              (SELECT product_code = 'P018' AND website_showed = 2 AND actual_combined_at_checkout = 0 FROM blocked)
    UNION ALL SELECT 6,  'Q1: warehouse = store system (P001, Chatswood)',
              (SELECT r.in_store_quantity = ss.in_store_quantity
                 FROM dw.rpt_current_stock_by_store r, store_ops.store_stock ss
                WHERE r.store_code = 'S03' AND r.product_code = 'P001' AND ss.store_no = '103' AND ss.item_no = 'P001')
    UNION ALL SELECT 7,  'Q2: website in sync after the sync',     (SELECT count(*) = 0 FROM dw.rpt_online_vs_actual WHERE status <> 'in sync')
    UNION ALL SELECT 8,  'Traceability: no staging row pending',   (SELECT count(*) = 0 FROM etl.v_staging WHERE load_status NOT IN ('loaded', 'skipped'))
    UNION ALL SELECT 9,  'Reconciliation: all stores match',       (SELECT count(*) = 0 FROM dw.rpt_reconciliation WHERE status <> 'match')
    UNION ALL SELECT 10, 'Data quality: no rejected rows',         (SELECT count(*) = 0 FROM etl.v_data_quality)
)
SELECT 'T' || test_no AS test, test AS description, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
  FROM checks ORDER BY test_no;
```

Expected: **T1–T10 all PASS**.

**Screen:** finish on Dashboard → Overview.

**Say:** "Inventory data is created separately in the Supplier, Store and Online systems. Our prototype uses ETL, transformation, approved mappings and a data warehouse to combine it into one analytical model. The dashboard then shows where stock is, which stores are low, how wrong the website is and the impact on checkouts, and every number can be traced back to its source."

## Timing

| Section | Time |
|---|---:|
| 1. Business problem | 1:00 |
| 2. Three source systems | 1:00 |
| 3. ETL and transformation | 2:00 |
| 4. Data warehouse | 1:00 |
| 5. Dashboard Q1 / Q4 / Q2 / Q3 | 3:30 |
| 6. Traceability | 1:00 |
| 7. Test result and summary | 0:30 |
| **Total** | **about 10 minutes** |

To record another take, rebuild the database and start again from "Before recording".
