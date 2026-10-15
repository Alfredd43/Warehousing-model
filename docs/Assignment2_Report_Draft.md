# Keeping Website Stock in Step with Five Stores: An Integrated Data Warehouse Prototype for PetHaven

32113 Advanced Database · Assignment 2 · Spring 2026

[TODO: group ID, student names and UTS IDs, demo video link, GitHub link]

---

## Executive Summary

PetHaven is a fictional Sydney pet-supplies retailer with five stores and a website. Its product stock is not updated in real time between in-store and online sales. The website shows one combined stock number per product, and before this project that number was updated only once a day. In-store sales, supplier deliveries and cancellations change real stock straight away, so the website could show stock that no store had, and customers found out only at checkout.

We built a working prototype in the Lab Environment on PostgreSQL 15. Three source systems (store, supplier and online) share one item number per product but keep their own transaction IDs, store codes, units and time zones. The website now extracts real shelf totals from the store system every 3 minutes, and checkout checks real store stock before payment. An ETL layer captures every source record with its transaction ID, accepts only approved items and store mappings, converts cartons to units and UTC to Sydney time, and loads a stock-event fact table in a star schema. Report views and a web dashboard serve four data use cases, led by the owner's two: how inaccurate website stock is, and which checkouts it blocked. One script builds the prototype, and it passes 105 behaviour checks, 17 scheduler checks and 45 dashboard checks.

---

## 1. Introduction

PetHaven is a fictional pet-supplies retailer selling pet food, treats, toys, bedding, health and aquarium products through five stores in Sydney: Parramatta, Bondi Junction, Chatswood, Newtown and Penrith. It also runs a website. Customers buy in a store, or order online and collect from a store they choose. Suppliers deliver products directly to each store, counted in cartons. PetHaven runs three separate systems (store, supplier and online), and their records are not kept consistent with each other.

The main business problem is that product stock is not updated in real time between in-store and online sales, so the website shows different stock numbers from the stores. The website shows one combined available number for each product across the five stores, and before this project that number was updated only once a day. Store sales, supplier deliveries and cancelled orders change real stock straight away. The website may therefore show items that are no longer available, and customers discover only at checkout that no store can fulfil their order. It may also show too little stock, hiding available items and losing sales. Customers and staff therefore find it hard to trust the website's stock information.

A further challenge is that all three systems use the same item number for a product (for example `P001`), but each numbers its own transactions differently (a receipt number in store, an order ID online, a supplier ID and supplier order number for deliveries) and names the stores differently. The supplier system also counts in cartons and records times in UTC. Without converting and tracing these records into one place, PetHaven cannot tell what stock each store really holds, how far the website is out of date, or which checkouts were blocked because of it.

This project builds a working prototype that addresses these problems without replacing the existing systems. The website extracts real stock from the store system every 3 minutes, and checkout checks real store stock before payment, so nobody pays for stock that cannot be supplied. The three sources stay in separate PostgreSQL schemas, and an extract, transform and load (ETL) process integrates their records into a data warehouse. The ETL accepts only approved items and store mappings, converts quantities and timestamps, and records every stock movement, so reports and a dashboard can measure how far the website is out of date and which checkouts were blocked.

---

## 2. Solution Design

### 2.1 Solution Architecture

> **[TODO Figure 1]** Architecture diagram. Export the Mermaid diagram from `docs/Architecture_and_Data_Model.md` §2 via mermaid.live.

The solution has five layers, each in its own PostgreSQL schema. Three are the operational systems PetHaven uses every day:

- **Store system** (`store_ops`): tills, live shelf and reserved stock in each store, and click-and-collect holds.
- **Supplier delivery system** (`supply`): supplier deliveries to each store, recorded in cartons.
- **Online store** (`online`): the web catalogue, the website stock number, the customer's bag, checkout and online orders.

The other two layers are the **ETL layer** (`etl`), which moves data from the sources into the warehouse, and the **integrated data warehouse** (`dw`), which the reports read.

The three source systems behave like separate products from different vendors. No source table has a foreign key into another source. They interact only through a few business functions, for example a supplier delivery calls the store system's function for receiving goods, and checkout asks the store system to find and hold stock.

Data moves along two separate paths. On the **analytical path**, a business action changes a source system, the ETL copies the record into staging, transforms it and loads it into the warehouse, and reports read the warehouse. On the **operational path**, the website refresh extracts real shelf totals from the store system and writes them to the website number. A small scheduler in the lab's Python container runs it every 3 minutes (`SYNC_INTERVAL_SECONDS = 180`, the one place the interval is set), and it can also be run by hand. The warehouse is not part of this path; it only receives a log of each refresh so the reports can show what was corrected.

### 2.2 Conceptual Model of Data Entities

> **[TODO Figure 2]** Conceptual ER diagram. Mermaid diagram in `docs/Architecture_and_Data_Model.md` §3.

The central entity is the **stock position**: the units of one product at one store. It has two parts. **In store** units are on the shelf and free to sell. **Reserved** units are held for online orders. Till sales and supplier deliveries change the shelf. Online orders create **reservations**, which hold stock at a store until the customer collects it. Every one of these changes is a **stock event**, and the stock events together form the single history of stock across all systems.

On the online side, each **product** has one **website number**, the combined quantity the website shows. A **website refresh** replaces the website numbers with the real shelf totals. Between refreshes the website number only goes down when the website itself sells something. We call a website number **stale** when it differs from the real combined shelf stock. A bag item is **blocked at checkout** when the website showed it as in stock but no single store could supply it.

An online order is collected at one **pickup store** that the customer chooses. If an item has to come from another store, it is transferred. Figure 3 shows the life cycle of an order line. While a line is in transit it belongs to no store, so store totals leave it out.

> **[TODO Figure 3]** Order line life cycle (held → in transit → arrived → collected, or cancelled). Mermaid state diagram in `docs/Architecture_and_Data_Model.md` §4.5.

### 2.3 Logical Data Model of Data Entities

#### Source systems

> **[TODO Figure 4]** ER diagrams of the three source schemas. CloudBeaver: right-click `store_ops`, `supply`, `online` → View Diagram.

The **store system** holds the store and product master data, live stock per store and product, till receipts, and reservations. A receipt is refused as a whole if any line is short of stock. Each reservation records the store supplying the units, the pickup store and the time of each step.

The **supplier delivery system** holds supplier delivery locations, supplier items with their units per carton, and supplier delivery dockets. Quantities are in cartons and times are in UTC with no time zone. When a supplier delivery is recorded, it converts cartons to units and adds them to the store's shelf.

The **online store** holds the web catalogue, the website number for each product, collection points, the customer's bag, each checkout attempt and paid orders. A customer can only add an item to the bag up to the website number, and adding holds nothing. At checkout, before payment, the store system checks that one store can supply each item, starting with the pickup store, and locks that stock. If any item is unavailable the checkout is blocked and nothing is charged. Otherwise the order is paid, stock is reserved and the website number drops at once.

All three systems identify a product by the same item number: the bag of dog food is `P001` at the till, at the supplier and on the website; its barcode, units per carton and web title are attributes. What differs is the transaction ID: a receipt number in the store system, an order ID online, and a supplier ID (`SUP-01`) plus supplier order number (`PO-1001`) for supplier deliveries. Store codes also still differ: the same Parramatta store is `101` in the store system, `NSW-PARRA` in the supplier delivery system and `CP-PARRAMATTA` online.

> **[TODO Figure 5]** The item list and each store's code in every system: `demo.py codes` in the terminal, or `etl.v_item_list` and `etl.v_store_codes` in CloudBeaver.

#### ETL layer

The ETL works in four steps.

**Extract.** Triggers copy each new source record, unchanged and in source format, into a staging table. Each staged row gets a unique source reference that carries the source system's transaction ID, such as `STORE:receipt 12 line 1` or `SUPPLY:supplier SUP-01 order PO-1001 line 1`.

**Transform.** A view checks the item number against the warehouse product list, maps each system's store code to the warehouse store code, converts cartons to units and UTC to a Sydney business date, and assigns each row an event type with signed quantities.

**Validate.** A row is rejected with a reason if its item is not on the warehouse product list ("Unknown item"), its store code has no approved mapping, its quantity is not positive or its date is invalid. Rejected rows stay in staging and are retried on every run, so they load as soon as a data steward adds the item to the product list.

**Load.** Valid rows are inserted into the fact table, and each run is logged with its counts.

Items are accepted only if a data steward has added them to the warehouse product list, and store codes are translated only through an approved store-code mapping. Nothing is ever guessed (for example by matching names), because a wrong match would corrupt the stock history without anyone noticing.

#### Data warehouse

> **[TODO Figure 6]** Star schema of `dw`. Mermaid diagram in `docs/Architecture_and_Data_Model.md` §6, or CloudBeaver diagram of `dw`.

The warehouse is a star schema with one fact table, `fact_stock_event`, and three dimensions: product, store and date. The grain is one stock change for one product at one store. Current stock is the sum of the signed changes, so the same table also serves as a full audit trail. Table 1 shows how each event type changes stock.

**Table 1. Effect of each event type on stock**

| Event type | Shelf | Reserved |
| --- | ---: | ---: |
| Store sale | − | 0 |
| Supplier delivery | + | 0 |
| Reservation (online order held) | − | + |
| Transfer out | 0 | − |
| Transfer in | 0 | + |
| Collection | 0 | − |
| Cancellation | + | − |
| Checkout blocked | 0 | 0 |

A check constraint enforces these rules on every row. Order events also carry the order reference and the pickup store, which is a second use of the store dimension. Each fact row keeps its source system and source reference, and the reference is unique, so no source record is loaded twice.

The dimensions use surrogate keys and conformed codes (`S01`, `P001`). The date dimension runs from 2020 to 2035 in Sydney time. Two more tables record each website refresh: when it ran, which stock events happened since the previous refresh, and the before and after value of each number it changed.

### 2.4 Design Rationale

We judged each part of the design on four things: whether it gives the dashboard's users the data their decisions need (use case fit), whether it is fast enough for trading and reporting (performance), whether it is simple enough to build, test and explain (complexity), and what it costs to run. Use case fit was the first test, so the design starts from the people who use the dashboard.

#### Data use cases

Inaccurate website stock affects three roles at PetHaven, and we ranked their use cases by impact: how much the role loses when stock is wrong, and how much say it has over the solution.

The owner is affected most. The owner looks after the whole business, and online is a channel to grow sales. When the website shows stock that no store has, the customer is blocked at checkout and the sale is lost, so wrong website stock makes that channel sell less. The owner also decides whether the 3-minute website refresh and the checkout check are kept. The owner's two use cases are high impact: UC1 shows the result (what sold and what was lost), and UC2 the cause (whether the website number is right and the refresh is running). The owner does not watch individual shelves; if a product sells well, the owner asks the stores to keep more of it. Store managers look after the stock of their own store and reorder it, so theirs is medium impact. Store staff at the click and collect counter prepare online orders: they send items to other stores, receive transfers and hand orders over. Their questions come up every day but each one is small, so their use case is low impact.

**Table X. Data use cases, ordered by impact**

| Impact | Use case | User | Question it answers | Decision it supports |
| --- | --- | --- | --- | --- |
| High | UC1 See the business impact | Owner (final decision-maker) | In the last 7 days, how much did we sell in store and online, which products sell best and how fast, and how many sales did we lose at checkout, and why? | Which products need attention: best sellers to keep in stock, and products and stores that lose sales |
| High | UC2 Check the website stock | Owner | Does the website show what the stores really have, and is the automatic refresh running? | Whether the online channel is working, or the refresh needs attention |
| Medium | UC3 Spot low stock | Store managers | Which products is my store running low on? | What to reorder for my store (the order itself is placed outside this system) |
| Low | UC4 Prepare click and collect orders | Store staff | Which orders must I send, receive or hand over, and which are overdue? | Which order to handle first |

These use cases set three requirements. UC1 and UC2 compare records from different systems: in-store sales and real shelf stock are in the store system, while online orders, blocked checkouts and the website number are in the online store. They can only be answered from one place that holds data from both. UC3 and UC4 need stock and order status per store that match the store system exactly, or a manager will reorder the wrong products and staff will tell a customer an order is ready when it is not. And the owner needs to trace any number back to the record it came from before acting on it. The dashboard pages are organised around these four use cases, and section 3.4 shows the report and page that answer each one.

#### Use case fit

Because UC1 and UC2 combine the online store with the store system, all three source systems load into one integrated data warehouse (`dw`) with shared product, store and date dimensions. The warehouse is used for analysis only. The online store sets its own website number from the store system and blocks checkouts itself, so a fault in the warehouse would delay the reports while customers could still buy.

The fact table records one stock change for one product at one store, from any of the three systems. UC3 reads current stock as the sum of these signed changes, so a store total and the history behind it come from the same rows, and UC4 follows each click and collect order line through the same events (held, sent, received, collected). A blocked checkout is stored as an event type that moves no stock, which puts the lost sales for UC1 in the same table as the sales around them. Each website refresh is logged with the website number before and after for every product, and UC2 reports from that log.

All three systems use the same item number for a product, so products need no mapping. Each system numbers its own transactions differently: a receipt number in store, an order ID online, and a supplier ID with a supplier order number for deliveries. The ETL stores that transaction ID on every fact row (`source_ref`), so a blocked checkout in UC1 can be traced back to the checkout attempt in the online store.

#### Data quality

Store codes still differ between systems. Parramatta is `101` in the store system, `NSW-PARRA` in the supplier system and `CP-PARRAMATTA` online, so each code is mapped to one warehouse code (`S01`) through a mapping a data steward has approved. A record whose item is not on the warehouse product list, or whose store code has no approved mapping, is rejected with a reason and stays in staging until the steward approves it. We did not match codes by name, because one wrong match would change the UC3 stock figures and the UC4 order lines without anyone noticing. We also did not refuse the sale, because that would stop a till over a reporting problem.

Supplier deliveries arrive in cartons with UTC times. The ETL converts them to units and to Sydney business dates before loading, so every store total is in units and every event falls on the right trading day.

#### Performance

Every source change starts an ETL run inside the same database transaction (change data capture). The warehouse is never behind the store system, so UC3 shows the stock on the shelf now and UC4 shows an order as ready as soon as its items arrive. At our data volume one ETL run takes about 5 ms, and a whole till sale stays under 10 ms.

Before the project, the website number came from a once-a-day extract of store stock. We shortened this data extraction to every 3 minutes, following the tutor's advice to use an interval of a few minutes. Refreshing on every sale would tie the three systems together and add work to every till transaction, and the checkout check already protects the moment the customer pays. The interval is one configuration value (`SYNC_INTERVAL_SECONDS = 180`), so if UC2 shows the website is wrong too often, the owner can shorten it without changing any SQL. A manual "refresh now" is kept for the same check on demand.

The reports are SQL views over the warehouse, so the dashboard always shows current data and needs no refresh job of its own. The prototype holds 146 stock events after the build, which is small enough for views; indexes on product and store support the stock totals.

#### Complexity

The three source systems are separate schemas in one PostgreSQL database, with no foreign keys between them. They behave as separate systems, and one script still builds and tests the whole prototype. The warehouse is a star schema with one fact table and three dimensions, which the dashboard and CloudBeaver query with simple joins. The website refresh logic is written in SQL, and a small Python scheduler only decides when to run it. Each online order is collected at one pickup store and each item comes from one store, which keeps transfers to one shipment per item.

#### Cost

The prototype uses the Lab Environment as supplied: PostgreSQL 15, the Python container and CloudBeaver. It needs no extra containers, no database extensions such as pg_cron, and no licences. We did not use the lab's Neo4j or ClickHouse, because the problem is relational and transactional. For the business, checking real store stock before payment means PetHaven never takes money for stock it cannot supply, so there are no refunds or cancelled paid orders. A blocked checkout still loses the sale, and UC1 measures how often that happens.

### 2.5 Design Trade-offs

**One database for all systems.** Putting the five schemas in one PostgreSQL database keeps the prototype simple and lets the ETL share the source transaction. Real systems would be separate databases connected through messages or APIs, with the warehouse fed from their change logs.

**ETL inside every transaction.** This removes any delay, but every till sale also pays for an ETL run, about 5 ms per sale at our data volume. At production volume the ETL would run asynchronously in small batches every few seconds.

**Type 1 dimensions.** A price change overwrites the old price, so the sales report values past sales at today's price. Type 2 dimensions, or storing the price on the fact, would fix this.

**One store per item.** Each order item must come from a single store, so an item that only two stores together could supply is blocked at checkout. Splitting items across transfers would remove this limit but makes fulfilment more complex.

**Stale numbers on the product page.** Checkout is safe, but customers can still add items that are already gone. Checking real stock when an item is added, or a shorter refresh interval, would reduce this.

**No agreed pickup time.** A click and collect order has no pickup time, so the prototype gives the customer 3 days from the moment the whole order is ready and then cancels it. A real store would let the customer choose a pickup time at checkout, no earlier than the order can be ready: a couple of hours when every item is at the pickup store, the next day when an item has to be transferred. Two kinds of lateness could then be told apart: an order not ready by the agreed time, which is PetHaven's failure and belongs on the owner's dashboard, and a ready order the customer has not collected 3 days after the agreed time, which is cancelled. This concerns collection, not the website stock problem, so it was left out of the prototype.

---

## 3. Working Prototype Implementation

The prototype runs in the course Lab Environment (PostgreSQL 15, a Python container and CloudBeaver). One command rebuilds the whole database:

```bash
docker compose exec python python /workspace/scripts/build.py
```

### 3.1 Source system databases and schemas

The three source systems are the schemas `store_ops` (6 tables), `supply` (5 tables, including suppliers) and `online` (13 tables, including the scheduler's registration), each with its own business functions and triggers. The scheduler itself is `scripts/sync_scheduler.py`, started with `demo.py scheduler start`.

> **[TODO Figure 7]** CloudBeaver navigator showing the five schemas in `pethaven_demo`, with the `store_ops` tables expanded.

### 3.2 Integrated data warehouse

The warehouse is the `dw` schema with the stock-event fact table, the three dimensions and the two website-refresh tables (`sync_run`, `sync_change`). After the build it holds 146 stock events, and all 90 store and product combinations match the store system.

> **[TODO Figure 8]** A few rows of `dw.fact_stock_event` in CloudBeaver, showing event type, signed quantities and source reference.

### 3.3 SQL scripts and synthetic data

All SQL is commented and runs on a clean database without errors. Table 2 maps each script to the part of the design it implements.

**Table 2. SQL scripts**

| Script | Implements |
| --- | --- |
| `01_schemas.sql` | The five schemas |
| `02_store_ops.sql` | Store system: tables, sale trigger, stock and order functions |
| `03_supply.sql` | Supplier delivery system: tables, supplier delivery trigger |
| `04_online.sql` | Online store: bag, pickup options, checkout, website refresh |
| `05_warehouse.sql` | Dimensions, fact table, website-refresh tables, indexes |
| `06_etl.sql` | Warehouse product list, store-code mapping, staging, extract triggers, transform view, load |
| `07_sync.sql` | Records each website refresh in the warehouse |
| `08_reports.sql` | Report views |
| `seed/01_reference_data.sql` | Stores, items, suppliers, store codes in each system, warehouse product list |
| `seed/02_business_history.sql` | Seven days of synthetic trading |

For example, the fact table's check constraint enforces the sign rules from Table 1:

```sql
CONSTRAINT ck_fact_signs CHECK (
       (event_type = 'store_sale'   AND quantity_change = -units AND reserved_change = 0      AND order_ref IS NULL)
    OR (event_type = 'supplier_delivery'     AND quantity_change =  units AND reserved_change = 0      AND order_ref IS NULL)
    OR (event_type = 'reservation'  AND quantity_change = -units AND reserved_change =  units AND order_ref IS NOT NULL)
    ...
)
```

The synthetic data covers five stores and 18 products, plus a new product (P019) that is deliberately left off the warehouse product list. It is created through the source systems' own functions, so every record passes through the ETL just as live data would. The seven days of trading include opening stock and restock supplier deliveries, 28 till receipts, eight online bags (seven paid and one blocked by a stale website number), collections, a cancellation and two website refreshes. Dates are relative to the build day, so "time since the last refresh" and overdue orders always look realistic.

> **[TODO Figure 9]** Output of `build.py`, ending with 155 records staged, 146 loaded, 0 rejected, 0 not reconciled.

> **[TODO Figure 10]** One supplier delivery traced from source to warehouse: cartons and UTC in staging, units and Sydney date in the fact table. CloudBeaver: the staging query in section 3 and the fact-table query in section 4 of `demo/video_demo_script.sql`.

### 3.4 Reports and dashboard

The prototype provides ten report views in the `dw` schema, grouped as Reports 1 to 6 in `workspace/db/08_reports.sql`. Report 6 also uses `etl.v_data_quality` to identify rejected source records. A local web dashboard presents four data use cases, meeting the assignment's requirement for at least three. Its menu follows the roles and impact ranking in section 2.4: the owner's two high-impact use cases come first, followed by store managers and store staff.

The dashboard is read-only. Sales, deliveries, orders and website refreshes are recorded through the source systems' own functions. Most dashboard data comes from warehouse report views. The website comparison and reconciliation reports also read the live source balances they compare with the warehouse. Checkout details read the online system's original records, and the stock movements drawer reads supplier names from `supply.supplier`, because the warehouse has no supplier dimension. The dashboard's Reload button reads the reports again; it does not refresh website stock or run the ETL.

**Table X. Data use cases, reports and dashboard pages**

| Use case | User (impact) | Report | Dashboard page |
| --- | --- | --- | --- |
| UC1 See the business impact | Owner (high) | Report 4: `rpt_daily_sales`, `rpt_product_sales`; Report 3: `rpt_checkout_blocked` | Overview |
| UC2 Check the website stock | Owner (high) | Report 2: `rpt_online_vs_actual`, `rpt_online_staleness`, `rpt_last_sync_changes`, `rpt_refresh_history` | Website stock |
| UC3 Spot low stock | Store managers (medium) | Report 1: `rpt_current_stock_by_store`; Report 4: `rpt_product_sales` | Store stock |
| UC4 Prepare click and collect orders | Store staff (low) | Report 5: `rpt_open_reservations` | Click & collect orders |

#### UC1: business impact (owner)

The Overview helps the owner decide which products and stores need attention. Report 4 supplies sales value by channel and the best-selling products, with units sold and value. A best seller with an empty shelf is marked with the number of stores affected. Needs attention summarises blocked items at checkout, products out of stock and overdue orders by store, with links to their details.

Sales, best sellers and the potential lost-sales figure cover the same 7 Sydney calendar days: today and the six preceding days. In-store sales count till-sale items at the selling store. Online sales count paid order items at the pickup store, less cancellations, whether or not the customer has collected them. Sales and potential lost-sales values use the current shelf price. Stock, website status and overdue orders show the current position.

Potential lost sales measures items blocked at checkout before payment. Its share of online demand is calculated as units blocked divided by the sum of units sold online and units blocked, over the same period. The detail card lists every recorded blocked item, newest first; only the headline figure is limited to 7 days. Report 3 gives the time, pickup store, quantity wanted, website number, real combined stock and reason for each block. It distinguishes an out-of-date website number from stock split across stores, where the total is sufficient but no single store can supply the whole quantity. Selecting a row opens the original checkout record, including its captured website number, alongside the warehouse's reconstruction. A blocked item is a potential lost sale: nothing was charged, and the data does not establish whether the customer bought it later.

> **[TODO Figure]** Dashboard, Overview, with the blocked P018 checkout selected and its source checkout record open.

#### UC2: website stock (owner)

Report 2 compares the website number with the combined available shelf stock across all five stores, for products on the warehouse product list. The difference is website stock minus store stock. "Website too high" means the website shows more stock than the stores have; "Website too low" means available stock is hidden from online customers. The page shows whether automatic refresh is running, how long ago the last refresh ran and when the next is due while it is running.

Refresh history lists the latest refreshes, the time between them, the stock events in between and the website numbers corrected. Selecting a row expands the products' before and after quantities and their changes. The owner can use the history to decide whether the refresh needs attention or whether its interval should be reviewed.

> **[TODO Figure]** Dashboard, Website stock, before the manual refresh (P018 "Website too high", P001 "Website too low"), and after it (the refresh history, with the manual refresh opened to show what it corrected).

#### UC3: low stock (store managers)

Report 1 gives available, reserved and on-hand units for each product at each store. Available means shelf stock free to sell; reserved units have already left the shelf. On hand is available plus reserved. Low stock means 2 or fewer available units, including an empty shelf. Stock in transit belongs to no store and is excluded from these balances.

A manager selects a store and uses the stock-and-sales chart to see which products are running out. It places current available and reserved stock beside units sold over the last 7 Sydney calendar days, with the least available stock first. Sales follow Report 4's rule: till sales at that store plus paid online order items assigned to it as the pickup store, less cancellations. The Low stock only filter narrows the products needing attention. Selecting a product in the chart narrows the table: with all stores selected, the table shows that product at each store; with one store selected, it keeps that store. The reorder itself is placed outside the prototype.

Selecting a table row opens a stock movements drawer for that product at that store. It lists events newest first in business language, such as "Delivery from Pawfect Foods" or "Sent to Bondi for online order 5". Each event shows the quantity change and, where available, the supplier order or till receipt behind it, for that store only.

> **[TODO Figure]** Dashboard, Store stock for Chatswood with P001 selected, showing the event history with supplier order PO-3001.

#### UC4: click and collect orders (store staff)

Report 5 helps store staff decide which click and collect orders to handle first. With My store selected, the page shows orders collected there and the items that store supplies to other pickup stores. Orders are sorted by urgency, with overdue orders first. The order time is when the customer paid and the items were held. Orders are identified by number; no customer names are stored.

An order is ready only when every item is at the pickup store. It becomes overdue after the whole order has been ready for more than 3 days without collection, so time spent waiting for a transfer does not make it overdue. Overdue and Ready to collect count whole orders; To send and In transit count item lines. Selecting Ready to collect keeps only whole ready orders and all their lines. The Status filter applies to individual lines, whose status changes from Waiting to be sent to In transit and then Ready for collection. Each item line has its own status; an overdue order also has a red Overdue tag under its number.

> **[TODO Figure]** Dashboard, Click & collect orders, with the overdue order at Parramatta and the Bondi order waiting for two items in transit.

#### Supporting reports

Report 6 compares warehouse stock with the live store system, while `etl.v_data_quality` lists source records rejected by the ETL. If either check finds a problem, a yellow banner warns on every page that the figures may be incomplete, and clears when no rejected records or stock mismatches remain.

> **[TODO Figure]** CloudBeaver, section 7 of `demo/video_demo_script.sql`: the two records rejected as "Unknown item P019" (`etl.v_data_quality`) before the item is added to the product list.

### 3.5 End-to-end testing

Testing combines automated checks on an isolated database with a recorded end-to-end demonstration. The automated checks exercise business rules and report responses. The demonstration follows identifiable source transactions through staging, transformation, validation, the warehouse and the dashboard.

#### Automated checks

Three test scripts build the separate `pethaven_check` database and run scripted business events, preserving the data used for the demonstration in `pethaven_demo`.

| Script | Coverage | Result |
| --- | --- | --- |
| `check_demo.py` | Stock updates, checkout, transfers, collection, cancellation, transaction references, unknown-item rejection, website refresh and reconciliation | 105 checks passed |
| `check_scheduler.py` | A 2-second test interval, scheduled refresh records, stock corrections, single-scheduler enforcement and stopping the scheduler | 17 checks passed |
| `check_dashboard.py` | Read-only API responses against the report views, input validation, error responses, source checkout details and data-quality warnings | 45 checks passed |

The scheduler's short test interval checks its behaviour without waiting for the normal 3-minute cycle. Dashboard API checks compare returned values with SQL report results. Page layout and interactions were checked by hand in the browser at 1440, 1280, 768 and 375 px wide. The scripted business checks are sequential and do not establish behaviour under concurrent checkouts or production workloads.

> **[TODO Figure]** Last lines of the three test runs: `PASS 105, FAIL 0`, `PASS 17, FAIL 0` and `PASS 45, FAIL 0`.

#### Recorded end-to-end test

Following the tutor's advice, the demonstration uses prepared queries and is recorded before the presentation. The script `demo/video_demo_script.sql` starts from a fresh build with automatic website refresh stopped, so the stale number remains visible until the manual refresh. After a brief statement of the business problem, it records events in all three source systems and follows them through the data pipeline. The presentation plays the recording at increased speed and explains the results.

**Table X. End-to-end test scenario**

| Step | System | Action | What is checked |
| --- | --- | --- | --- |
| 1 | Supplier | SUP-01 delivers 5 cartons of P001 to Chatswood (order PO-3001) | 5 cartons × 4 = 20 units; `NSW-CHATS` → S03; UTC → Sydney time |
| 2 | Store | The last P018 sells at Newtown and at Penrith | In-store sales reach the warehouse at once; the website number is now out of date |
| 3 | Online | A Bondi customer tries to buy 1 × P018 while the website still shows 2 | Checkout is blocked before payment and recorded for analysis |
| 4 | Online | Manual website refresh | P001 183 → 203 and P018 2 → 0; the warehouse records the correction |
| 5 | Supplier, store | P019, not on the warehouse product list, is delivered and sold | Both records are rejected with a reason, then load once after a data steward approves P019 |

The recording shows the ETL code for extraction, transformation, validation and loading. Staged records retain their original quantities, codes, timestamps and transaction references. The corresponding warehouse rows show the converted units, mapped stores and Sydney business times. Supplier, store and online events are then shown together in the stock-event fact table.

Each use case is shown first as a report query in CloudBeaver and then on its dashboard page. For UC1, sales and the blocked checkout appear on the Overview, and the checkout row opens its source record. For UC2, P018 is too high and P001 too low before the refresh; afterwards, the website matches the combined store stock and refresh history shows the corrections. For UC3, the low-stock list identifies products needing attention. Chatswood's P001 stock rises from 53 to 73, and its drawer shows the delivery and supplier order PO-3001. For UC4, order 3 at Parramatta is ready and overdue, while order 5 at Bondi remains unready because two items are in transit from Chatswood.

A traceability query follows the blocked item from Report 3 to its warehouse event, staged record and original checkout attempt. The validation step then delivers and sells P019 before it is on the warehouse product list. Both transactions succeed in the source systems, but their records are rejected by the ETL with a reason. After a data steward adds P019 and the ETL is run, the waiting records load once. The dashboard's data-quality banner appears during the rejection and clears after loading.

The script ends with 11 automatic checks, and all of them pass.

**Table X. End-to-end test results**

| Test | What it checks | Result |
| --- | --- | --- |
| T1 | Supplier: 5 cartons loaded as 20 units | PASS |
| T2 | Supplier: `NSW-CHATS` mapped to S03 | PASS |
| T3 | Supplier: UTC converted to Sydney time | PASS |
| T4 | Store: P018 sales at S04 and S05 in the warehouse | PASS |
| T5 | Online: blocked checkout captured, website 2 vs stores 0 | PASS |
| T6 | UC3: warehouse stock equals the store system (P001 Chatswood) | PASS |
| T7 | UC2: after the refresh, the website matches the stores for every product | PASS |
| T8 | Traceability: no staging row left pending | PASS |
| T9 | Reconciliation: warehouse matches the store system | PASS |
| T10 | Data quality: no rejected source rows | PASS |
| T11 | Validation: P019 rejected with a reason, then loaded once | PASS |

Other cases, including a checkout blocked because no single store has the whole quantity, transfers to the pickup store, collection and overdue cancellation, are covered by the automated checks. The results apply to the prototype's synthetic scenarios. They do not measure actual customer losses or establish that a 3-minute refresh interval is optimal for a live retailer.

Demo video: [TODO link]

---

## 4. Report Summary and Conclusion

PetHaven's product stock was not updated in real time between in-store and online sales, so the website could show stock that no store had and customers found out only at checkout. This project designed and built a solution for that problem.

The design keeps the three operational systems separate, each with its own codes, units and time zone, and combines their data only in an integrated data warehouse. An ETL layer captures each source record unchanged, keeps its transaction ID, accepts only items on the warehouse product list, maps store codes through an approved mapping, converts cartons to units and UTC to Sydney time, and loads it as one row in a stock-event fact table with product, store and date dimensions. Records for unknown items are rejected with a reason and load once a data steward adds the item. Every 3 minutes (or by hand) the website extracts the real shelf totals from the store system and refreshes its number. The warehouse does not set that number, but it records every refresh so the reports can measure staleness. Checkout checks real stock before payment, so a stale number costs a sale rather than a refund.

The prototype runs in the Lab Environment and one script rebuilds it. It loads a week of synthetic trading, reconciles all 90 store and product combinations with the store system, and passes 105 behaviour checks, 17 scheduler checks and 45 dashboard checks. The reports and dashboard show current stock, website staleness and blocked checkouts, along with sales, open orders and data quality.

The main limitations are that all systems share one database, the ETL runs inside each source transaction, the website can still be up to 3 minutes out of date, the scheduler has to be started by hand, old prices are not kept, and click and collect orders have no agreed pickup time. A production version would use separate databases, asynchronous data capture, a scheduler run as a managed service and type 2 dimensions for prices.

---

## Appendix

[TODO A: individual contribution evidence (logbooks, emails, task allocation)]

[TODO B: at least 3 meeting minutes on the Canvas template, signed by the tutor]

[TODO C: individual contribution form]

[TODO D: group self-assessment (HD / D / C / P / F)]
