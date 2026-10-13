# PetHaven Data Warehouse Prototype — Demo Runbook

## Demo Objective

This demonstration shows how PetHaven integrates fragmented inventory data from its **Supplier, Store, and Online systems** into a **Data Warehouse** through ETL and data transformation, and then uses a **Dashboard** to support inventory analysis and business decision-making.

The main story is:

```text
Operational Symptom
        ↓
Website inventory can become stale between synchronisations
        ↓
Data / Analytical Problem
        ↓
Inventory data is fragmented across Supplier, Store, and Online systems
        ↓
ETL + Data Transformation
        ↓
Integrated Data Warehouse
        ↓
Dashboard
        ↓
Cross-system inventory insights
```

---

# 0. Before Presenting

Run this once before the class, off screen. All SQL below is run in CloudBeaver against `pethaven_demo`, one statement at a time.

1. Build a clean database and reconnect CloudBeaver:

   ```bash
   docker compose exec python python /workspace/scripts/build.py
   ```

2. Open the dashboard at <http://localhost:8080>. Keep the automatic sync **stopped**.

3. Make the website stale so Q2 has a clear example. These are the only statements that change data before the demo:

   ```sql
   -- The last aquarium kit (P018) sells in store at Newtown (104) and Penrith (105)
   SELECT store_ops.record_sale('104', ARRAY['P018'], ARRAY[1]);
   SELECT store_ops.record_sale('105', ARRAY['P018'], ARRAY[1]);
   ```

4. Check the starting point:

   ```sql
   SELECT current_database() AS db,
          (SELECT scheduler_status     FROM dw.rpt_online_staleness) AS scheduler,
          (SELECT products_out_of_date FROM dw.rpt_online_staleness) AS website_out_of_date;
   ```

   Expected: `pethaven_demo | never started | 1`.

Every SQL block in sections 2–6 is read-only and can be run again at any time.

---

# 1. Business Problem

PetHaven sells pet products through five Sydney stores and an online store.

Its inventory activities are distributed across three operational systems:

- **Supplier System** — deliveries and replenishment data
- **Store System** — shelf stock, sales, reservations, and stock movements
- **Online System** — website stock, synchronisation, checkout attempts, and online orders

An operational symptom is that **website inventory can become stale between synchronisations**, potentially causing blocked checkouts or obscuring available stock.

However, the main problem addressed by this project is a **data and analytical problem**:

> **Inventory data is fragmented across Supplier, Store, and Online systems, making it difficult to obtain an integrated view, measure stock discrepancies, and understand their business impact.**

Our prototype addresses this problem by using:

- ETL
- data validation and transformation
- approved mappings
- a Data Warehouse
- analytical reports
- a management Dashboard

### Demo Message

> “The Data Warehouse does not perform the operational checkout or stock synchronisation. Its role is to integrate data from multiple systems so PetHaven can analyse inventory from one consistent view.”

---

# 2. Show the Three Source Systems

Briefly introduce the three source systems.

## Supplier System

Show example data such as:

- supplier delivery
- quantity in cartons
- supplier/location codes
- UTC timestamp

## Store System

Show example data such as:

- store
- product
- shelf stock
- reserved stock
- store sales

## Online System

Show example data such as:

- website-displayed stock
- checkout attempts
- online orders
- stock synchronisation information

### SQL

```sql
-- Supplier system: deliveries in cartons, supplier location codes, UTC time
SELECT d.supplier_id, d.supplier_order_no, d.location_code, l.item_no,
       l.cartons, d.delivered_at_utc
  FROM supply.supplier_delivery d
  JOIN supply.supplier_delivery_line l ON l.delivery_no = d.delivery_no
 ORDER BY d.delivery_no DESC
 LIMIT 5;

-- Store system: shelf and reserved stock per store number
SELECT store_no, item_no, in_store_quantity AS shelf, reserved_quantity AS reserved
  FROM store_ops.store_stock
 WHERE item_no = 'P001'
 ORDER BY store_no;

-- Online system: one website number per product, and checkout attempts
SELECT item_no, available_quantity AS website_stock, last_synced_at
  FROM online.online_stock
 WHERE item_no IN ('P001', 'P018');

SELECT attempt_no, basket_id, outcome, pickup_cp_code
  FROM online.checkout_attempt
 ORDER BY attempt_no;
```

Expected: supplier rows in cartons with `NSW-…` codes; store numbers `101`–`105`; P001 website 183, P018 website 2; 8 checkout attempts, one `blocked`.

### Key Point

The data belongs to the same inventory process, but it is stored separately and follows different structures and business rules.

```text
Supplier ─┐
Store ────┼──→ Fragmented inventory data
Online ───┘
```

Do not spend significant time demonstrating the complete customer transaction flow.

---

# 3. Show ETL and Data Transformation

Demonstrate how source data is prepared for integration.

Use one or two clear examples.

## Example 1 — Supplier Delivery

Show the original supplier record:

```text
Quantity: 5 cartons
Time: UTC
Location: source-specific code
```

Then show the transformed warehouse-ready values:

```text
Quantity: 20 units
Time: Sydney business time
Location: approved PetHaven store mapping
```

Explain the transformations:

- cartons → units
- UTC → Sydney business time
- source code → approved warehouse mapping
- validation before loading

### SQL

```sql
-- Source: supplier order PO-1201, 5 cartons of P001 to Chatswood, in UTC
SELECT d.supplier_id, d.supplier_order_no, d.location_code,
       l.item_no, l.cartons, i.units_per_carton, d.delivered_at_utc
  FROM supply.supplier_delivery d
  JOIN supply.supplier_delivery_line l ON l.delivery_no = d.delivery_no
  JOIN supply.item i ON i.item_no = l.item_no
 WHERE d.supplier_order_no = 'PO-1201';

-- Before / after: staging keeps the source values; the ETL rules give the warehouse values
SELECT s.cartons                       AS before_cartons,
       s.cartons * s.units_per_carton  AS after_units,
       s.location_code                 AS before_location,
       x.store_code                    AS after_store,
       s.delivered_at_utc              AS before_utc,
       (s.delivered_at_utc AT TIME ZONE 'UTC') AT TIME ZONE 'Australia/Sydney' AS after_sydney_time,
       s.load_status
  FROM etl.stg_supplier_delivery_line s
  LEFT JOIN etl.store_xref x ON x.source_system = 'SUPPLY' AND x.source_code = s.location_code
 WHERE s.supplier_order_no = 'PO-1201';

-- Approved mapping: three operational codes -> one warehouse store
SELECT store_code, store_name, store_no, location_code, cp_code
  FROM etl.v_store_codes
 ORDER BY store_code;
```

Expected: 5 cartons × 4 = **20 units**; `NSW-CHATS` → **S03**; UTC + 11 h = Sydney time; `loaded`.

## Example 2 — Store / Online Events

Briefly show how store and online events are also mapped into a common analytical structure.

### SQL

```sql
-- Store sales and an online checkout, staged with their own source references
SELECT 'STORE' AS source, store_no AS source_code, item_no, quantity, load_status, source_ref
  FROM etl.stg_store_sale_line
 WHERE stg_id > (SELECT max(stg_id) - 2 FROM etl.stg_store_sale_line)
UNION ALL
SELECT 'ONLINE', pickup_cp_code, item_no, quantity, load_status, source_ref
  FROM etl.stg_checkout_item
 WHERE result = 'unavailable';

-- ETL audit: each source change triggered an ETL run automatically
SELECT etl_run_id, trigger_source, rows_read, rows_loaded, rows_rejected
  FROM etl.etl_run
 ORDER BY etl_run_id DESC
 LIMIT 5;
```

Expected: the two P018 store sales (`104`, `105`) and the blocked online checkout (`CP-BONDI-JUNCTION`), all `loaded`; ETL runs with 0 rejected.

### Demo Message

> “The ETL layer standardises data from different operational systems so the records can be reliably combined and analysed.”

If staging tables are shown, explain that they provide traceability between source records and warehouse records.

---

# 4. Show the Integrated Data Warehouse

Open the warehouse tables/views and briefly demonstrate that data from different systems now appears in a common analytical model.

For example, show:

- `dw.fact_stock_event`
- relevant dimensions
- analytical/reporting views
- ETL audit or reconciliation information where useful

Conceptually:

```text
Supplier events ─┐
Store events ────┼──→ Integrated Data Warehouse
Online events ───┘
                         │
                         ├── Store
                         ├── Product
                         ├── Event
                         └── Date / business context
```

### SQL

```sql
-- One fact table: events from all three systems
SELECT f.event_id, f.source_system, f.event_type, s.store_code, p.product_code,
       f.quantity_change AS shelf_change, f.reserved_change, f.source_ref
  FROM dw.fact_stock_event f
  JOIN dw.dim_store   s ON s.store_key   = f.store_key
  JOIN dw.dim_product p ON p.product_key = f.product_key
 ORDER BY f.event_id DESC
 LIMIT 10;

-- Events per source system in the one fact table
SELECT source_system, event_type, count(*) AS events
  FROM dw.fact_stock_event
 GROUP BY source_system, event_type
 ORDER BY source_system, event_type;

-- Supplier lineage: source -> staging -> warehouse, same source_ref
SELECT s.cartons, s.location_code, f.units, ds.store_code,
       f.event_ts AT TIME ZONE 'Australia/Sydney' AS sydney_time, f.source_ref
  FROM etl.stg_supplier_delivery_line s
  JOIN dw.fact_stock_event f ON f.event_id = s.event_id
  JOIN dw.dim_store ds       ON ds.store_key = f.store_key
 WHERE s.supplier_order_no = 'PO-1201';
```

Expected: SUPPLY, STORE and ONLINE events in the same table (95 / 52 / 1 events); PO-1201 is 5 cartons at `NSW-CHATS` in staging and 20 units at `S03` in the warehouse.

Select a small number of rows rather than scrolling through large tables.

### Demo Message

> “The warehouse provides a consistent analytical layer across the three source systems. This is what allows the dashboard to answer cross-system inventory questions.”

---

# 5. Dashboard Demonstration

The Dashboard is the main business-facing output of the prototype.

Use it to answer four simple business questions.

```text
                     DATA WAREHOUSE
                           │
                           ▼
                       DASHBOARD
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
 Inventory position   Store comparison   Cross-system issues
        │                                     │
   Q1 + Q4                              Q2 + Q3
```

---

## Q1. Where is stock available or reserved?

### Business Question

> **Where is stock available or reserved across PetHaven stores?**

Open the **Store Stock** dashboard view.

Show inventory by store/product, focusing on:

- Shelf Stock
- Reserved Stock
- Available Stock, according to the implemented inventory definition

Use a product filter if helpful.

Example presentation:

```text
Store             Shelf       Reserved       Available
-------------------------------------------------------
Parramatta          25            5              ...
Chatswood           18            2              ...
Newtown             12            3              ...
```

### SQL

```sql
SELECT store_name,
       in_store_quantity AS shelf_available,
       reserved_quantity AS reserved,
       total_on_hand
  FROM dw.rpt_current_stock_by_store
 WHERE product_code = 'P001'
 ORDER BY store_code;

-- Reserved stock across all products, per store
SELECT store_name, sum(in_store_quantity) AS shelf, sum(reserved_quantity) AS reserved
  FROM dw.rpt_current_stock_by_store
 GROUP BY store_name
 ORDER BY store_name;
```

Expected: P001 shelf 37 / 27 / 53 / 20 / 46. Reserved units are held at Parramatta (3), Bondi (2) and Chatswood (2). Shelf stock is already the available stock; do not subtract reserved from it.

### What This Shows

Management can see the integrated stock position rather than looking at individual operational transactions.

### Demo Message

> “This view brings shelf and reservation information together so managers can understand the stock position across stores.”

---

## Q4. Which stores have lower stock levels?

### Business Question

> **Which stores have lower stock levels and may require replenishment?**

Use the **Store Stock** dashboard to compare stock across all five stores:

- Parramatta
- Bondi Junction
- Chatswood
- Newtown
- Penrith

Prefer a simple **Available Stock by Store** bar chart or ranked store view.

Example:

```text
Available Stock by Store

Parramatta       █████████████
Chatswood        ██████████
Newtown          ████████
Bondi Junction   ██████
Penrith          ███
                  ↑
             Lower stock
```

If filters are available, select one product to make the comparison clearer.

### SQL

```sql
SELECT rank() OVER (ORDER BY in_store_quantity) AS rank_lowest,
       store_name,
       in_store_quantity AS available_stock
  FROM dw.rpt_current_stock_by_store
 WHERE product_code = 'P001'
 ORDER BY in_store_quantity;

-- Low-stock alerts (2 or fewer on the shelf) per store
SELECT store_name, count(*) FILTER (WHERE low_stock) AS low_stock_products
  FROM dw.rpt_current_stock_by_store
 GROUP BY store_name
 ORDER BY low_stock_products DESC;
```

Expected: Newtown 20 (lowest), Bondi 27, Parramatta 37, Penrith 46, Chatswood 53. Newtown and Chatswood have the most low-stock products (3 each).

### What This Shows

Management can quickly compare locations and identify stores with relatively lower inventory that may need attention or replenishment.

### Demo Message

> “The integrated view also allows managers to compare inventory across locations and quickly identify stores with lower stock levels.”

### Important Scope

The Dashboard identifies lower inventory levels. It does **not** automatically decide or execute replenishment.

---

## Q2. How inaccurate is website stock?

### Business Question

> **How inaccurate is website stock compared with real store stock?**

Open the **Website Stock** dashboard view.

Show:

- Website Stock
- Real / Actual Store Stock
- Difference or discrepancy
- Sync correction information

Use a clear example where website stock differs from actual store stock.

Conceptually:

```text
Website Stock        5
Actual Store Stock   2
                    ──
Discrepancy          3
```

If appropriate, show the latest synchronisation correction.

### SQL

```sql
-- Website stock vs actual store stock
SELECT product_code, product_name,
       online_shown    AS website_stock,
       actual_in_store AS actual_store_stock,
       overstated_by   AS discrepancy,
       status
  FROM dw.rpt_online_vs_actual
 WHERE status <> 'in sync';

-- Staleness summary
SELECT last_sync_at AT TIME ZONE 'Australia/Sydney' AS last_sync, time_since_sync,
       pending_events, products_out_of_date
  FROM dw.rpt_online_staleness;
```

Expected: P018 website **2**, actual **0**, discrepancy **2**, *overstated - oversell risk*; 2 events pending, 1 product out of date.

Optional: show the sync correction live (this changes data):

```sql
SELECT online.sync_website_stock();

SELECT product_code, before_qty, after_qty, difference
  FROM dw.rpt_last_sync_changes
 WHERE measure = 'online_available';
```

Expected: P018 website 2 → 0.

### What This Shows

This analysis combines information from the Online and Store systems.

It allows PetHaven to identify cases where customer-facing stock information does not match operational inventory.

### Demo Message

> “The warehouse allows PetHaven to measure the stock discrepancy across systems. The operational sync corrects the website stock; the warehouse records and analyses the discrepancy.”

---

## Q3. What is the business impact?

### Business Question

> **What is the business impact of inventory discrepancies?**

Open the **Orders / Lost Sales / Checkout** analytical view.

Show:

- blocked checkout attempts
- product involved
- failure reason
- website stock at the time of the attempt, where available
- actual or reconstructed stock information

Use one clear blocked-checkout example.

Conceptually:

```text
Website shows stock
        ↓
Customer attempts checkout
        ↓
Real stock is insufficient
        ↓
Checkout blocked
        ↓
Event captured for analysis
```

### SQL

```sql
-- Report 3: blocked checkouts, with website stock and real stock at that moment
SELECT basket, attempted_at AT TIME ZONE 'Australia/Sydney' AS attempted_at,
       product_code, quantity_in_bag, pickup_store,
       website_showed, actual_combined_at_checkout AS actual_stock, reason
  FROM dw.rpt_checkout_blocked
 ORDER BY attempted_at;

-- Source record in the online system for the same attempt
SELECT a.attempt_no, a.outcome, i.item_no, i.quantity, i.website_qty_shown, i.result
  FROM online.checkout_attempt a
  JOIN online.checkout_attempt_item i ON i.attempt_no = a.attempt_no
 WHERE a.outcome = 'blocked';
```

Expected: basket 5, 3 × P018, pickup Bondi, website showed **7**, actual **2**, reason *stock sold since last sync - online number was stale*.

### What This Shows

The warehouse can connect inventory information with checkout outcomes to help management understand the customer impact of inventory issues.

### Demo Message

> “The Data Warehouse does not block the checkout. The operational system does that. The warehouse allows PetHaven to analyse the resulting checkout events together with inventory information.”

Avoid claiming that every blocked checkout is a confirmed lost sale unless the data specifically proves that.

---

# 6. Show Data Integration / Traceability

After answering the four business questions, briefly return to the technical side.

Use the **Data & Integration** view, ETL audit, staging records, or reconciliation information available in the prototype.

Show that a dashboard result can be traced back through the warehouse pipeline.

```text
Source Record
     ↓
Staging / ETL
     ↓
Validation + Transformation
     ↓
Data Warehouse
     ↓
Report / Dashboard
```

### SQL

```sql
-- Trace the Q3 result back: report -> warehouse event -> staging -> online source
SELECT r.basket, f.event_id, f.source_ref, s.stg_id, s.load_status, a.attempt_no, a.outcome
  FROM dw.rpt_checkout_blocked r
  JOIN dw.fact_stock_event f     ON f.event_type = 'checkout_blocked'
                                AND f.order_ref = r.basket AND f.event_ts = r.attempted_at
  JOIN etl.stg_checkout_item s   ON s.event_id = f.event_id
  JOIN online.checkout_attempt a ON a.attempt_no = s.attempt_no;

-- Reconciliation: warehouse vs live store system
SELECT status, count(*) AS store_product_pairs
  FROM dw.rpt_reconciliation
 GROUP BY status;

-- Data quality: rejected source records
SELECT count(*) AS rejected_rows FROM etl.v_data_quality;
```

Expected: one row linking basket 5 → warehouse event → staging row (`loaded`) → online attempt 5 (`blocked`); 90 store/product pairs `match`; 0 rejected rows.

### Demo Message

> “The dashboard is not simply reading one operational system. Its analytical results are supported by the ETL and warehouse integration layer.”

This step connects the business-facing dashboard back to the Advanced Database implementation.

---

# 7. Final Summary

Finish on the Dashboard.

### Final Demo Message

> “PetHaven's operational systems generate inventory data separately across Supplier, Store, and Online systems. This fragmentation makes it difficult to obtain one consistent view of inventory and understand cross-system issues.”

> “Our prototype uses ETL, data transformation, approved mappings, and a Data Warehouse to integrate these records into a common analytical model.”

> “The Dashboard then allows managers to see where stock is available or reserved, compare stock levels across stores, measure website stock discrepancies, and investigate their impact on checkout outcomes.”

Finish with:

```text
Supplier ─┐
Store ────┼──→ ETL → Data Warehouse → Dashboard
Online ───┘
                                      │
                                      ├── Q1 Stock position
                                      ├── Q4 Low-stock stores
                                      ├── Q2 Stock discrepancy
                                      └── Q3 Business impact
```

---

# Suggested Demo Timing

The end-to-end test for the recorded video is a separate script: `demo/vedio_demo_script.sql` (about 8 minutes).


| Section | Approx. Time |
|---|---:|
| 1. Business Problem | 1 min |
| 2. Three Source Systems | 1 min |
| 3. ETL & Transformation | 1.5 min |
| 4. Data Warehouse | 1 min |
| 5. Dashboard — Q1 | 1 min |
| 5. Dashboard — Q4 | 0.5 min |
| 5. Dashboard — Q2 | 1 min |
| 5. Dashboard — Q3 | 1 min |
| 6. Data Integration / Traceability | 1 min |
| 7. Final Summary | 0.5 min |
| **Total** | **~9.5 min** |

---

# Core Message

The main purpose of the prototype is **not** to demonstrate a retail checkout application.

The main purpose is to demonstrate how advanced database techniques integrate fragmented retail inventory data and turn it into useful analytical information:

> **Fragmented Operational Data → ETL & Transformation → Integrated Data Warehouse → Dashboard → Inventory Insights**
