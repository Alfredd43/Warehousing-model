# PetHaven - Assignment 2 Spec: Business Case, Prototype Scope and Demonstration (v8)

12 Oct 2026 · Group 3 · Internal guide, not a submission

This guide defines the business problem, the three source systems, the business actions that create their records, the stock rules, the integration and warehouse layer, the dashboard's four data use cases, and how the working prototype is tested end to end in the recorded demo video. The solution design that implements it is in [docs/Architecture_and_Data_Model.md](../docs/Architecture_and_Data_Model.md). The demo is scripted in [demo/demo_runbook.md](../demo/demo_runbook.md).

PetHaven is fictional. Its size, operating arrangements and update rules below are fixed definitions for this project.

## 1. What PetHaven is

| Item | Project definition |
| --- | --- |
| Business | PetHaven Group Pty Ltd, a fictional Sydney pet-supplies retailer. It does not sell animals. |
| Products | Pet food, treats, toys, accessories, bedding, hygiene, health and aquatics. The prototype uses 18 products (plus one new line, P019, used to test data validation). |
| Stores | Five: Parramatta, Bondi Junction, Chatswood, Newtown and Penrith. Each has a shop floor and a click-and-collect counter. |
| Sales channels | **In-store**, through POS tills; **online**, through the website. |
| Click & Collect (C&C) | An online order collected at one **pickup store**, chosen by the customer from the stores holding at least one of the items. Items that store does not have are taken from another store and transferred to it. The only online fulfilment in scope. |
| Supply | **Suppliers** deliver directly to each store, in cartons. |

Use these words consistently: **in-store**, **online** and **supplier** (never "offline").

- **Channel:** how the customer buys (in-store or online).
- **Offering:** what is sold (a product).
- **Fulfilment:** how an online order reaches the customer (always collection from one pickup store, with transfers from other stores where needed).
- **Location:** where stock physically is (one of the five stores).

## 2. Business problem and solution

### 2.1 The business problem

PetHaven is a fictional Sydney pet-supplies retailer with five stores and a website. Its stores, supplier deliveries and website run on three separate systems: the **Store**, **Supplier** and **Online** systems (section 3).

The website shows one stock number per product for all five stores. Before this project, that number was updated only by a periodic batch extract (once a day: an overnight stock snapshot copied to the website at 5 am), not at the same time as store stock changed. In-store sales, supplier deliveries and cancellations change real stock straight away, so between refreshes the website could show stock that no store had. Customers added these items to their bag and paid for them; only when store staff checked the order did they find the stock was not there, and the website and store records did not match. The website could also show too little and hide stock that was on the shelves.

All three systems use the same item number for a product, but nobody could see how far the website was out of date, because each system records stock changes in its own way: its own transaction IDs, store codes, units and time zones.

> **Business problem:** product stock is not updated in real time between PetHaven's in-store and online sales, so stock sold in one channel can still show as available in the other.

### 2.2 The solution

| Part | What it does | Layer | Section |
| --- | --- | --- | --- |
| 1. Website refresh every 3 minutes | The website extracts the real store totals from the store system every 3 minutes and resets its number, and can be refreshed by hand ("refresh now"). The interval follows the tutor's advice (6 Oct) to refresh every few minutes; on 13 Oct the tutor asked that this be described as shortening the data extraction, not as "syncing". | Operational | 6 |
| 2. Real-stock check at checkout | Before payment, each bag item is checked against real store shelf stock. If any item cannot be supplied, checkout is blocked: nothing is charged. A paid order can always be fulfilled. | Operational | 4.3, 5.3 |
| 3. ETL, data warehouse and dashboard | Records from all three systems are validated, transformed and loaded into one warehouse, so PetHaven can see where stock is, how wrong the website was and which checkouts were blocked. | Analytical | 7–9 |

Parts 1 and 2 make the problem smaller and stop it from charging customers for missing stock, but they do not remove it. Between refreshes the website number can still be wrong for up to 3 minutes, and a customer can still be blocked at checkout. The website is not refreshed on every sale because the three systems are separate: refreshing on every transaction would tie them together and add load to every sale, while the checkout check already protects the moment that matters.

PetHaven therefore needs to measure the remaining gap: how often the website is wrong, by how much, for which products and stores, and how many checkouts it blocks. That needs records from all three systems, which each record stock in their own way (section 2.1). The ETL validates and converts them, and the warehouse combines them into one consistent view. Of the dashboard's data use cases (section 9), UC1 and UC2 measure the gap (how wrong the website is, and which checkouts it blocked); UC3 and UC4 show which stores are running low and where the real stock is.

```text
Business problem: stock is not updated in real time between in-store and online
        ↓
Operational solution: 3-minute website refresh + real-stock check at checkout
        ↓
Remaining gap: the website number can still be wrong between refreshes; checkouts can be blocked
        ↓
Analytical solution: ETL → integrated data warehouse → dashboard (data use cases UC1–UC4, section 9)
```

The demo video shows the problem and the solution in the same prototype: the scheduler is stopped, an in-store sale leaves the website number wrong (the problem), an online checkout is blocked (part 2), "refresh now" corrects the website (part 1), and the dashboard measures what happened (part 3).

### 2.3 Role of the data warehouse

| The warehouse does | The warehouse does not |
| --- | --- |
| Integrate records from all three systems into one analytical model | Perform checkout or block a checkout (the online store does) |
| Measure the discrepancy between the website number and real store stock | Set the website number (the operational website refresh does) |
| Record each website refresh and each blocked checkout for analysis | Decide or execute replenishment |
| Trace every result back to its source record | Act as a fourth source system |

### 2.4 Scope

The unit of analysis is **one product at one store**, and the combined number for one product across all stores.

In scope: in-store sales, supplier deliveries, online C&C orders with several lines (hold, transfer to the pickup store, collect, cancel), blocked checkouts, the scheduled website refresh (every 3 minutes, plus "refresh now"), ETL with validation and approved mappings, the warehouse, reports and dashboard.

Out of scope: customer accounts and membership, grooming, home delivery, returns after collection, stock adjustments and counts, splitting one order line across several stores, pricing and promotions, automatic replenishment.

The old once-a-day extract (section 2.1) is background only; it is not built in the prototype.

## 3. The three source systems

### 3.1 What they are

| Operational system | Used by | Source schema | Main responsibility |
| --- | --- | --- | --- |
| **Store system** (POS tills + stock screens + C&C counter) | Store staff | `store_ops` | Stores, product catalogue, live shelf and reserved stock per store, till receipts, C&C holds and transfers |
| **Supplier system** (supplier delivery system) | Receiving staff, suppliers | `supply` | Supplier delivery locations, supplier items, supplier delivery dockets |
| **Online system** (online store) | Customers, web team | `online` | Web catalogue, the website stock number and its refresh log, collection points, bags, checkout attempts, online orders |

The lab hosts them as separate schemas in one PostgreSQL database. They are separate systems: none has a foreign key into another, and they cooperate only through the actions in section 4.

The **integrated data warehouse** (`dw`), fed by the ETL layer (`etl`), is a separate analytical store. It is not a fourth source.

### 3.2 One item number; each system has its own transaction IDs, codes, units and clock

| | Store system (in-store) | Supplier system (supplier) | Online system (online) |
| --- | --- | --- | --- |
| Product | item number `P001` | item number `P001` | item number `P001` |
| Product attributes | EAN-13 barcode, description, price | GTIN-14 carton barcode, units per carton, supplier | web title, web price |
| Transaction ID | **receipt number** | **supplier ID** (`SUP-01`) + **supplier order number** (`PO-1001`) | **order ID** (bag / checkout attempt before payment) |
| Store | store number `101`–`105` | location code `NSW-PARRA` | collection point `CP-PARRAMATTA` |
| Quantity | units | cartons | units |
| Time | Sydney time | UTC | Sydney time |

The item number is how the business tells one product from another, so all three systems share it, and the warehouse uses it as its product code. Store codes are what needs mapping: the warehouse gives each store one conformed code (`S01`–`S05`) and matches each system's store code to it only through an **approved mapping** (section 7.3). Every warehouse record keeps the transaction ID of the source record it came from (`source_ref`).

## 4. Business actions and what they change

All changes to a store's stock happen **immediately** when the action is recorded. Each action is also captured by the ETL within the same transaction (section 7.1).

### 4.1 Store system

| Action | Recorded as | Store stock effect | Website number |
| --- | --- | --- | --- |
| Till sale (one receipt, one or more items) | `sale` (receipt number) + `sale_line` | shelf − qty per item; the whole receipt is refused if any item is short | unchanged until the next refresh |
| Held line sent to the pickup store | `reservation` → `in_transit` | supplying store: reserved − qty (in transit, in no store) | unchanged (already deducted) |
| Transferred line arrives | `reservation` → `arrived` | pickup store: reserved + qty | unchanged |
| Customer collects a C&C order (only when every line is at the pickup store) | each `reservation` → `collected` | pickup store: reserved − qty (goods leave) | unchanged (already deducted) |
| C&C order not collected within 3 days | the overdue job (`cancel_overdue_orders`) cancels it like the row below | as below | unchanged until the next refresh |
| C&C order cancelled before collection (not while a line is in transit) | each `reservation` → `cancelled`, with reason | where the units are: reserved − qty, shelf + qty | unchanged until the next refresh |

### 4.2 Supplier system

| Action | Recorded as | Store stock effect | Website number |
| --- | --- | --- | --- |
| Supplier delivery to a store | `supplier_delivery` (supplier ID + supplier order number, UTC) + `supplier_delivery_line` in cartons | shelf + cartons × units per carton at that store | unchanged until the next refresh |

### 4.3 Online system

| Action | Recorded as | Effect |
| --- | --- | --- |
| Customer adds items to the bag | `basket` + `basket_item` | Allowed only up to the website number (which may be stale). Nothing is held and the website number does not change. Bags never expire. |
| Customer sees pickup options | `pickup_options()` | Every store holding at least one bag item, ranked by fewest transfers, then distance. A store with none of the items is not offered. |
| Customer checks out (before payment) | `checkout_attempt` + `checkout_attempt_item` (records the website number shown) | 1. **Pickup store** = the customer's choice (default: the top option). 2. For each item, find a store whose **real** shelf stock covers the whole quantity: the pickup store first, then the others by distance. 3. If **any** item is unavailable → checkout **blocked**: nothing charged, nothing held, the customer sees which items to remove. 4. Otherwise → **paid**: `web_order` (order ID) + `web_order_line`; each item held at its supplying store (shelf − qty, reserved + qty), transferred to the pickup store if needed; the website number drops by each item at once. |
| Website refresh | `stock_sync` + `stock_sync_line` (before → after) | See section 6. |

## 5. Stock definitions and rules

### 5.1 Definitions

| Term | Meaning |
| --- | --- |
| Shelf (in store) | Units on one store's shelf, free to sell. In this model **shelf stock is the available stock**: reserved units have already been taken off the shelf. |
| Reserved | Units at one store held for C&C orders: waiting for collection there, or waiting to be sent to another pickup store. Units in transit between stores are in no store. |
| Available | = shelf. **Never calculate available as shelf − reserved** (that would subtract reserved units twice). |
| On hand | Shelf + reserved. |
| Low stock | 2 or fewer units on one store's shelf (`low_stock` in Report 1). |
| Real combined available | Sum of shelf over the five stores. |
| Website number | The one number per product the website shows, and uses to let items into the bag. |
| Discrepancy | Website number − real combined available. Positive = **overstated** (oversell risk); negative = **understated** (lost sales risk); zero = matches. |
| Stale | Discrepancy ≠ 0. |
| Blocked at checkout | A bag item the website showed as in stock that no single store could supply at checkout. Found before payment, so nothing is charged. It is a **potential** lost sale; it is not reported as a confirmed lost sale unless the data proves the customer did not buy later. |

### 5.2 How the website number changes

1. A **website refresh** sets it to the real combined available: the shelf totals extracted straight from the store system.
2. Between refreshes it drops by each **held** online order line (the website knows its own sales).
3. Nothing else changes it: in-store sales, supplier deliveries and cancellations wait for the next refresh; transfers and collections do not change it (the units were already deducted).

### 5.3 Items blocked at checkout

Checkout always checks real store stock before payment, so a paid order can always be fulfilled. Two causes are distinguished: **stale number** (the real combined stock was already below the quantity in the bag) and **stock split across stores** (enough in total, but not at any one store).

## 6. The website refresh (operational, not part of the warehouse)

The website refresh runs **automatically every 3 minutes** (one configuration value, `SYNC_INTERVAL_SECONDS = 180`). It can also be run **on demand** ("refresh now": `online.sync_website_stock()` or the script command `demo.py sync`). The scheduler is kept **stopped while recording** so the stale state stays on screen until the presenter refreshes by hand.

It is a periodic, asynchronous extract (destination-driven, Module 5): the online system pulls the store totals on a timer. It is separate from the ETL, which loads every source record into the warehouse in near real time (section 7). The code keeps its original names (`sync_website_stock`, `sync_run`, `SYNC_INTERVAL_SECONDS`); "sync" in a code name means this website refresh.

Each run asks the store system for the real shelf totals per product across the five stores, updates the website number for every product, and logs before → after in the online system.

The warehouse does not set the website number. It receives the refresh log through the ETL and records, for reporting: whether the refresh was scheduled or manual, every website number it changed (before → after), the stock events since the previous refresh and the store totals they changed, and whether the warehouse agrees with the store system.

## 7. ETL and data transformation

### 7.1 Flow

Business action → source system (stock changes immediately) → ETL **extracts** the record into staging in its source format, with its transaction ID → **validates** the item and **maps** the store code → **transforms** units and time → **loads** one stock event into the warehouse → reports and dashboard read the warehouse.

The ETL runs **near-real-time**: each source change triggers an ETL run automatically (change data capture), recorded in `etl.etl_run`. A read-only demo needs no manual ETL run.

### 7.2 Transformations

| Source value | Rule | Warehouse value |
| --- | --- | --- |
| Supplier quantity in **cartons** | cartons × units per carton | **units** (5 cartons × 4 = 20 units) |
| Supplier time in **UTC** | convert to `Australia/Sydney` | **Sydney business time** and Sydney business date (`dim_date`) |
| Store number / location code / collection point | approved mapping (`etl.store_xref`) | conformed store code `S01`–`S05` |
| Item number | must be on the warehouse product list (`etl.item_list`) | `product_code` (unchanged) |
| Transaction ID | kept as text | `source_ref`, e.g. `SUPPLY:supplier SUP-01 order PO-3001 line 1`, `STORE:receipt 29 line 1`, `ONLINE:checkout attempt 9 item P018` |

### 7.3 Validation and approved mappings

Items need no mapping: every system uses the same item number. The warehouse accepts an item only once a data steward has added it to the **product list**. Store codes are mapped only through approved mappings; matching by name is never used. A record for an unknown item or an unmapped store code is **rejected with a reason ("Unknown item P019"), not guessed**. The business transaction still completes in its own system; the record waits in staging and loads as soon as the item is approved.

### 7.4 Staging and traceability

Staging tables (`etl.stg_supplier_delivery_line`, `stg_store_sale_line`, `stg_checkout_item`, `stg_reservation_change`, `stg_website_sync_line`) keep each source record in its original format with its load status and the warehouse event it became. `etl.v_transform` lists only pending or rejected rows; loaded rows have left it, so before/after demonstrations recompute the documented rules from the stored staging values. `etl.v_data_quality` lists rejected rows; `dw.rpt_reconciliation` compares warehouse totals with the live store system.

## 8. The integrated data warehouse

| Element | Definition |
| --- | --- |
| Fact | `dw.fact_stock_event`. **Grain:** one stock change for one product at one store, from any source system (`source_system` = SUPPLY, STORE or ONLINE). Measures: `quantity_change` (shelf), `reserved_change`, `units`. |
| Event types | `supplier_delivery`, `store_sale`, `reservation`, `transfer_out`, `transfer_in`, `collection`, `cancellation`, `checkout_blocked` |
| Dimensions | `dim_product` (item number, category, price; SCD type 1), `dim_store` (S01–S05 + ONLINE), `dim_date` (Sydney business date) |
| Website refresh record | `dw.sync_run`, `dw.sync_change` (before → after per store and the website) |
| Lineage | every fact row keeps `source_ref` and `etl_run_id`; every staging row keeps its `event_id` |

Report views:

| # | View | Answers |
| --- | --- | --- |
| 1 | `dw.rpt_current_stock_by_store` | Shelf vs reserved, on hand and low stock per store and product |
| 2 | `dw.rpt_online_vs_actual`, `rpt_online_staleness`, `rpt_last_sync_changes` | Website number vs real stock, time since the last refresh, events pending, before/after of the last refresh |
| 3 | `dw.rpt_checkout_blocked` | Bag items blocked at checkout: pickup store, what the website showed, real stock, reason |
| 4 | `dw.rpt_daily_sales` | Units sold per day, store, channel and category |
| 5 | `dw.rpt_open_reservations` | Open C&C order lines: source store, transfer status, order ready, overdue |
| 6 | `dw.rpt_reconciliation`, `etl.v_data_quality` | Warehouse vs store system; rejected source records |

## 9. Dashboard: four data use cases

The dashboard is the main business-facing output. It reads only the warehouse report views (plus the online system's checkout records as the source evidence for UC2). Pages: Overview, Website stock, Store stock, and Orders & potential lost sales.

A data use case is one way a PetHaven user relies on the integrated data: who uses it, the question it answers, the decision it supports, and the report and dashboard page that deliver it. The four use cases below are what the reports and dashboard are built for (brief item vi.d, at least 3).

Three roles use the dashboard. The **owner** is affected most by stock that customers cannot buy (lost sales and unhappy customers) and is the one who decides whether the solution is kept, so the owner's use cases have high impact. **Store managers** manage stock across the stores (medium impact). **Store staff** serve customers and handle click & collect orders: holding stock, transfers between stores, collections (low impact: day-to-day questions).

```text
                     DATA WAREHOUSE
                           │
                       DASHBOARD
        ┌──────────────────┼──────────────────┐
 Inventory position   Store comparison   Cross-system issues
     UC3 + UC4                              UC1 + UC2
```

| Use case | User | Impact | Question it answers | Decision it supports |
| --- | --- | --- | --- | --- |
| UC1 Measure website accuracy | Owner | High | How inaccurate is website stock compared with real store stock, and what did the last refresh correct? | Whether the 3-minute refresh interval is short enough |
| UC2 Measure the impact | Owner (final decision-maker) | High | Which checkouts were blocked because of inaccurate stock, for which products and stores, and why? | Which products and stores need attention; whether blocks come from a stale number or from stock split across stores |
| UC3 Spot low stock | Store managers | Medium | Which stores have lower stock levels and may require replenishment? | Which stores to reorder for (the reorder itself is made outside this system) |
| UC4 Locate stock | Store staff (main), store managers | Low | Where is stock available or reserved across PetHaven stores? | Which store can serve a customer, or send stock to another store |

| Use case | Dashboard page | Source view | What it shows | Scope note |
| --- | --- | --- | --- | --- |
| UC1 | Website stock | Report 2 | Website vs real stock, discrepancy, status, last refresh and its corrections | The refresh corrects the website; the warehouse measures and records the discrepancy |
| UC2 | Orders & potential lost sales | Report 3 + `online.checkout_attempt*` | Blocked checkout attempts: product, pickup store, website number shown, real stock, reason | The online system blocks the checkout; a blocked checkout is a potential, not confirmed, lost sale |
| UC3 | Store stock | Report 1 | Available stock by store for one product, ranked; low-stock alerts per store | Identifies low stock; does **not** decide or execute replenishment |
| UC4 | Store stock (open click & collect orders: Orders & potential lost sales → Click & collect orders) | Report 1 (Report 5) | Shelf (= available), reserved and on hand per store and product | Available = shelf (section 5.1); reserved = held for click & collect orders |

## 10. End-to-end testing and the recorded demo video

### 10.1 Format

Following the tutor's guidance (6 Oct), queries are **not written live**: the end-to-end test is **pre-recorded**, its link is given in the report (brief item vi.e), and it is played sped up in the presentation. On 13 Oct the tutor described the video as the prototype itself: state the business problem very briefly, then show the code and the technologies: how the data is ingested, extracted, transformed, cleaned and validated, and the reports and dashboards. The architecture is explained in the report and on the presentation slides, not in the video. The script is `demo/video_demo_script.sql`; each data use case is shown as a report query and then on the dashboard.

### 10.2 Test scenario

One scenario is driven through all three source systems and followed through ETL, the warehouse, the reports and the dashboard:

| Step | System | Action | Proves |
| --- | --- | --- | --- |
| 1 | Supplier | SUP-01, order PO-3001: 5 cartons of P001 to Chatswood (`NSW-CHATS`) | cartons → units, UTC → Sydney, location code → S03 |
| 2 | Store | The last aquarium kit (P018) sold at Newtown and the last at Penrith | in-store sales reach the warehouse at once; website becomes stale |
| 3 | Online | A Bondi customer tries to buy 1 × P018; the website still shows 2 | checkout blocked before payment; event captured for analysis |
| 4 | Online | Refresh now | website corrected (P001 183 → 203, P018 2 → 0); correction recorded by the warehouse |
| 5 | Supplier + Store | Deliver and sell P019, not on the product list; data steward approves it | rejection with reason, then load without duplicates (data cleaning and validation) |

### 10.3 Pass criteria

The script ends with an automatic test summary; every row must be PASS:

| Test | Condition |
| --- | --- |
| T1 | Supplier: 5 cartons loaded as 20 units |
| T2 | Supplier: `NSW-CHATS` mapped to S03 |
| T3 | Supplier: UTC converted to Sydney time |
| T4 | Store: P018 sales at S04 and S05 in the warehouse |
| T5 | Online: blocked checkout captured with website 2 vs actual 0 |
| T6 | UC4: warehouse stock equals the store system (P001 Chatswood = 73) |
| T7 | UC1: after the refresh, the website matches the stores for every product |
| T8 | Traceability: no staging row left pending |
| T9 | Reconciliation: warehouse matches the store system |
| T10 | Data quality: no rejected source rows |
| T11 | Validation: P019 rejected with a reason, then loaded once after approval |

Before recording, the automated checks must also pass: `check_demo.py` (104), `check_scheduler.py` (17) and `check_dashboard.py` (38), each `FAIL 0`.

### 10.4 Running order and timing (about 10 minutes)

| Section | Content | Time |
| --- | --- | ---: |
| Opening | Business problem and solution in brief (dashboard Overview) | 0:30 |
| 0-1 | Pre-check and baseline: the source systems before the test | 0:45 |
| 2 | Test inputs: one event in each source system | 0:45 |
| 3 | ETL: the code (extract, transform, validate, load), then its results | 2:00 |
| 4 | Integrated data warehouse: one fact table, all three sources | 0:45 |
| 5 | Reports and dashboard: UC1, UC2, UC3, UC4 | 3:00 |
| 6 | Traceability: dashboard row back to its source record | 0:30 |
| 7 | Validation test: P019 rejected, then loaded once | 1:00 |
| 8 | Test result T1-T11, ending on the dashboard | 0:30 |

Recording rules: rebuild `pethaven_demo` before every take (`build.py`) and reconnect CloudBeaver; keep the refresh scheduler stopped; show times in Sydney time; select a few rows rather than scrolling large tables.

### 10.5 Further cases in the sample data

These are in the seed history and support the reports and use cases:

- **Stale number blocks a checkout (seed).** Website refreshed at 7 aquarium kits; 5 sold in store; a Bondi customer's checkout for 3 was blocked (Report 3, basket 5).
- **The nearest store can't supply, so it isn't offered.** A Penrith customer's 2 orthopaedic beds were held at Parramatta; never collected, so the order becomes overdue and is cancelled, returning the beds to the shelf.
- **The customer picks a store with only some items.** A Bondi order whose dog beds and scratching posts are in transit from Chatswood, so the order is not ready to collect (Report 5).

### 10.6 The presentation

The tutor's format (13 Oct): at most 10 minutes (going over is marked down), 3 or 4 slides (business problem, solution, architecture, learnings), and the video above played sped up in between, with every member presenting and answering questions. The plan, timing and question list are in `demo/demo_runbook.md`.

## 11. Brief items and where they are delivered

| Brief item | Delivered by |
| --- | --- |
| vi.a Source databases and schemas (≥ 3) | `store_ops`, `supply`, `online` (`workspace/db/02`–`04`) |
| vi.b Integrated data warehouse (≥ 1) | `dw` (`workspace/db/05_warehouse.sql`) |
| vi.c Commented SQL scripts with synthetic data, ETL | `workspace/db/01`–`08`, `workspace/db/seed/` |
| vi.d Reports and dashboard per data use case (≥ 3) | Four data use cases UC1–UC4 (section 9), Reports 1–6 (`08_reports.sql`), dashboard (`workspace/dashboard/`) |
| vi.e End-to-end testing and recorded demo video | `demo/video_demo_script.sql` (recorded video, T1-T11), `workspace/tests/` (104 + 17 + 38 checks) |

## 12. Word list

| Word | Meaning here |
| --- | --- |
| Source system | An operational system that records business actions (Store, Supplier, Online). |
| Business problem | Product stock is not updated in real time between in-store and online sales, so stock sold in one channel can still show as available in the other. |
| Remaining gap | What the operational solution cannot remove: the website number can be wrong between refreshes, and checkouts can be blocked. The warehouse measures it. |
| Data warehouse | The integrated analytical database (`dw`) combining the three sources. |
| ETL | Extract, transform, load: copying source records into staging, validating and converting them, and loading them into the warehouse. |
| Staging | ETL tables holding source records in their original format, with load status and traceability. |
| Approved mapping | A data-steward-approved link from a system's store code to the warehouse store code. |
| Item number | The number that identifies a product (`P001`), the same in all three systems. The warehouse calls it `product_code`. |
| Transaction ID | How a system identifies its own transaction: receipt number (in-store), order ID (online), supplier ID + supplier order number (supplier). |
| Conformed code | The warehouse's own code for a store (`S01`), shared by all reports. |
| Fact / dimension | Fact: a measured event (a stock change). Dimension: descriptive context (product, store, date). |
| Grain | What one fact row represents: one stock change for one product at one store. |
| Discrepancy | Website number minus real combined available stock. |
| Website refresh | The operational job in which the website extracts the store system's shelf totals: every 3 minutes, or by hand. Code names still say "sync" (`online.sync_website_stock()`, `dw.sync_run`). |
| Reconciliation | Comparing warehouse totals with the store system's live stock. |
| End-to-end test | The recorded scenario that drives all three sources through ETL, the warehouse and the dashboard, ending in T1–T10 PASS. |
