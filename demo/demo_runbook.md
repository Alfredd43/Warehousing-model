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

3. Make the website stale so Q3 has a clear example. These are the only statements that change data before the demo:

   ```sql
   -- The last aquarium kit (P018) sells in store at Newtown (104) and Penrith (105)
   SELECT store_ops.record_sale('104', ARRAY['P018'], ARRAY[1]);
   SELECT store_ops.record_sale('105', ARRAY['P018'], ARRAY[1]);
   ```

   Each statement returns the new receipt number (29 and 30). Run them only once.

   Confirm the website is now stale:

   ```sql
   SELECT product_code, online_shown AS website, actual_in_store AS actual, status
     FROM dw.rpt_online_vs_actual
    WHERE status <> 'in sync';
   ```

   Expected: `P018 | 2 | 0 | overstated - oversell risk`.

4. Check the starting point:

   ```sql
   SELECT current_database() AS db,
          (SELECT scheduler_status     FROM dw.rpt_online_staleness) AS scheduler,
          (SELECT products_out_of_date FROM dw.rpt_online_staleness) AS website_out_of_date;
   ```

   Expected: `pethaven_demo | never started | 1`.

The SQL in sections 3, 4 and 6 is read-only and can be run again at any time. Section 5 uses the dashboard only.

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

### Key Point

The data belongs to the same inventory process, but it is stored separately and follows different structures and business rules.

| Data element | Store system (`store_ops`) | Supplier system (`supply`) | Online system (`online`) | After ETL (data warehouse `dw`) |
|---|---|---|---|---|
| **Product** | Item number `P001` | Item number `P001` | Item number `P001` | `product_code` `P001` (unchanged) |
| **Store / location** | Store number `101`–`105` | Location code `NSW-PARRA`, `NSW-CHATS`, … | Collection point `CP-PARRAMATTA`, `CP-CHATSWOOD`, … | Conformed store code `S01`–`S05` (approved mapping) |
| **Quantity unit** | Units | **Cartons** | Units | Units (cartons × units per carton) |
| **Timestamp** | Sydney time | **UTC** | Sydney time | Sydney time plus Sydney business date (`dim_date`) |
| **Transaction ID** | Receipt number | Supplier ID + supplier order number (`SUP-01` / `PO-1201`) | Order ID (bag / checkout attempt before payment) | `source_ref`, e.g. `SUPPLY:supplier SUP-01 order PO-1201 line 1` |
| **Stock measure** | Shelf and reserved stock per store | Delivered cartons per delivery line | One combined website number for all stores | Signed `quantity_change` and `reserved_change` per event |

The item number is the only value that is the same in all three systems. The ETL therefore maps store codes, converts units and time, and keeps each transaction ID as `source_ref`.

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

**Story line:** follow PetHaven's stock as it **comes in** from a supplier and **goes out** through the stores and the website. Each system records the same kind of event in its own way; the ETL makes them comparable.

## Example 1 — Supplier Delivery

> **Stock comes in.** Supplier SUP-01 delivers 5 cartons of dog food (P001) to the Chatswood store (order PO-1201). The supplier system records it in its own format: cartons, a location code and UTC time.

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

| | Supplier system (source) | Data warehouse (after ETL) |
|---|---|---|
| Quantity | 5 cartons | 20 units |
| Location | `NSW-CHATS` | `S03` |
| Time | 19:20 UTC | 06:20 Sydney time, next day |

## Example 2 — Store / Online Events

> **Stock goes out.** A Bondi customer tries to buy 3 aquarium kits (P018) online while the website still shows 7, but only 2 are left, so checkout is blocked. Then the last 2 kits sell in store at Newtown and Penrith. The online and store systems each record these events with their own codes.

Briefly show how store and online events are also mapped into a common analytical structure.

The Store and Online systems record events in their own format: the store sale uses store number `104`, the online checkout uses collection point `CP-BONDI-JUNCTION`. The ETL captures both in staging with their own source reference, then loads them into the same warehouse fact table as the supplier deliveries.

### SQL

```sql
-- Store sales and an online checkout, staged with their own codes and source references
SELECT 'STORE' AS source, store_no AS source_code, item_no, quantity, load_status, source_ref
  FROM etl.stg_store_sale_line
 WHERE stg_id > (SELECT max(stg_id) - 2 FROM etl.stg_store_sale_line)
UNION ALL
SELECT 'ONLINE', pickup_cp_code, item_no, quantity, load_status, source_ref
  FROM etl.stg_checkout_item
 WHERE result = 'unavailable';
```

Expected: three rows, all `loaded`.

| Source | Source code | Item | Qty | Source reference |
|---|---|---|---:|---|
| STORE | `104` | P018 | 1 | `STORE:receipt 29 line 1` |
| STORE | `105` | P018 | 1 | `STORE:receipt 30 line 1` |
| ONLINE | `CP-BONDI-JUNCTION` | P018 | 3 | `ONLINE:checkout attempt 5 item P018` |

### What to point out

- Each system keeps its own codes and transaction IDs in staging.
- All three records are `loaded`: the ETL ran automatically when each event happened.
- In the warehouse they become rows in one fact table, with the same store codes (`S01`–`S05`) and product codes as the supplier deliveries (section 4).

> **Where the story goes next:** the delivery, the sales and the blocked checkout now sit side by side in the warehouse (section 4), and the dashboard uses them to answer Q1–Q4 (section 5).

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
   Q1 + Q2                              Q3 + Q4
```

---

Before starting, check the status line on **Website stock**: it should say *Automatic sync: not running*. Use the dashboard's **Refresh** button if a page looks out of date. Refresh only re-reads the reports; it never runs the sync or the ETL.

## Q1. Where is stock available or reserved?

### Business Question

> **Where is stock available or reserved across PetHaven stores?**

### On the Dashboard

1. Open **Store stock** → tab **Current stock**, **View: By store**.
2. Type **P001** in the **Product** box. The **Stock by store** table shows *P001 at each store*, with one row per store and the columns **Available**, **Reserved**, **On hand** and **Stock status**.
3. Clear the box and type **P013**, the large orthopaedic dog bed. It shows that a store can have reserved units with an empty shelf.
4. Optional: click a store row to open its **Event history**, the warehouse events behind the number.

What the audience should see:

```text
P001 at each store      Available   Reserved   On hand
------------------------------------------------------
Parramatta                  37          0         37
Bondi                       27          0         27
Chatswood                   53          0         53
Newtown                     20          0         20
Penrith                     46          0         46
```

For P013, **Parramatta** shows Available **0**, Reserved **2**, On hand **2**: both beds are on the premises but held for a click-and-collect order, so none are free to sell.

*Note:* **Available** is the shelf stock and is already free to sell; reserved units have already been taken off the shelf. Available is therefore not reduced again by reserved.

### What This Shows

Management can see the integrated stock position rather than looking at individual operational transactions. The event history shows the warehouse events behind each number.

### Demo Message

> “This view brings shelf and reservation information together so managers can understand the stock position across stores.”

---

## Q2. Which stores have lower stock levels?

### Business Question

> **Which stores have lower stock levels and may require replenishment?**

### On the Dashboard

1. Stay on **Store stock** → **Current stock**, **View: By store**, with **P001** in the **Product** box.
2. Compare the **Available** column across the five stores.
3. Point out the colours in the **Available** column: **red = out of stock**, **amber = low (1–2 left)**.
4. Clear the **Product** box and tick **Low stock only** to list only the shelves that need attention. (The same list appears on **Overview** → *Out of stock and running low*.)

What the audience should see:

```text
Available Stock by Store (P001)

Chatswood        ████████████████████  53
Penrith          █████████████████     46
Parramatta       ██████████████        37
Bondi Junction   ██████████            27
Newtown          ███████               20   ← lowest
```

With **Low stock only**, **Aquarium Starter Kit 40L (P018)** is red (0) in every store, after the two sales recorded before the demo. Orthopaedic Dog Bed Large (P013) is also low in every store, and Cat Scratching Post 80cm (P017) is low at Chatswood and Newtown.

### What This Shows

Management can quickly compare locations and identify stores with relatively lower inventory that may need attention or replenishment.

### Demo Message

> “The integrated view also allows managers to compare inventory across locations and quickly identify stores with lower stock levels.”

### Important Scope

The Dashboard identifies lower inventory levels. It does **not** automatically decide or execute replenishment.

---

## Q3. How inaccurate is website stock?

### Business Question

> **How inaccurate is website stock compared with real store stock?**

### On the Dashboard

1. Open **Website stock**.
2. Read the status line: *Automatic sync: not running* and the time of the last sync.
3. Read the yellow banner: *1 of 18 products show the wrong stock on the website: 1 too high (customers may order stock that has gone)*.
4. In **Products with the wrong number on the website**, show the P018 row.
5. Optional: click the P018 row. It opens **Store stock** for P018 and shows 0 available in every store.

What the audience should see:

```text
Product                       Website shows   Stores have   Difference
-----------------------------------------------------------------------
Aquarium Starter Kit 40L (P018)      2              0            +2     Website too high
```

### Optional: Show the Sync Correction

Open the **Demo actions** panel and click **Sync website stock now**. This changes data.

- The banner turns green: *The website matches the stores for all 18 products.*
- **What the last sync corrected** lists P018: *Website before* **2** → *Website after* **0**.

Run this only once, and only at the end of Q3. To show the stale number again, rebuild the database and repeat **0. Before Presenting**.

### What This Shows

This analysis combines information from the Online and Store systems. It allows PetHaven to identify cases where customer-facing stock information does not match operational inventory.

### Demo Message

> “The warehouse allows PetHaven to measure the stock discrepancy across systems. The operational sync corrects the website stock; the warehouse records and analyses the discrepancy.”

---

## Q4. What is the business impact?

### Business Question

> **What is the business impact of inventory discrepancies?**

### On the Dashboard

1. Open **Orders & lost sales** → tab **Lost sales**.
2. Show the row for **Aquarium Starter Kit 40L (P018)**.
3. Click the row. The **Customer checkout (attempt 5)** card opens with the source record from the online system: outcome *Blocked before payment*, the bag, the pickup store, and each item's *Website snapshot (source)* next to the *Report reconstruction*.
4. Optional: click **View data trace** to lead into section 6.

What the audience should see:

```text
Product          Wanted   Website showed   Stores had   Pickup store   Why
------------------------------------------------------------------------------------------------
Aquarium Kit       3            7              2          Bondi        Website number was out of date
```

Conceptually:

```text
Website shows stock (7)
        ↓
Customer attempts checkout (3 kits, pickup at Bondi)
        ↓
Real stock is insufficient (only 2 left, at Newtown and Penrith)
        ↓
Checkout blocked before payment, nobody charged
        ↓
Event captured for analysis
```

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
-- Trace the Q4 result back: report -> warehouse event -> staging -> online source
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
                                      ├── Q2 Low-stock stores
                                      ├── Q3 Stock discrepancy
                                      └── Q4 Business impact
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
| 5. Dashboard — Q2 | 0.5 min |
| 5. Dashboard — Q3 | 1 min |
| 5. Dashboard — Q4 | 1 min |
| 6. Data Integration / Traceability | 1 min |
| 7. Final Summary | 0.5 min |
| **Total** | **~9.5 min** |

---

# Core Message

The main purpose of the prototype is **not** to demonstrate a retail checkout application.

The main purpose is to demonstrate how advanced database techniques integrate fragmented retail inventory data and turn it into useful analytical information:

> **Fragmented Operational Data → ETL & Transformation → Integrated Data Warehouse → Dashboard → Inventory Insights**
