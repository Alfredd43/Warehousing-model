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

The prototype has three source systems. In the Lab Environment each system is a separate schema in the `pethaven_demo` database. The schemas have no foreign keys to each other, so they behave like three independent operational systems. They only share the item number (for example P001), which is how the business identifies a product. Each system keeps its own store codes, transaction IDs, units and time zone, just as separate real systems would.

**Table 3.1. Source system schemas**

| Schema | Source system | Tables | Functions | Triggers | Main tables |
| --- | --- | --- | --- | --- | --- |
| `store_ops` | Store system | 6 | 14 | 6 | store, product, store_stock, sale, sale_line, reservation |
| `supply` | Supplier system | 5 | 2 | 3 | supplier, location, item, supplier_delivery, supplier_delivery_line |
| `online` | Online system | 13 | 9 | 3 | product, online_stock, basket, checkout_attempt, web_order, stock_sync, and 7 more |

The Store system (`store_ops`) records till sales and the live shelf and reserved stock for each of the five stores. It also handles click-and-collect holds, transfers and collections. A trigger on `sale_line` lowers the shelf stock as soon as a sale is recorded.

The Supplier system (`supply`) records supplier deliveries. Each delivery is identified by a supplier ID and a supplier order number, and is recorded in cartons with a UTC timestamp. A trigger adds the delivered units (cartons × units per carton) to the store's shelf.

The Online system (`online`) holds the website catalogue, the single stock number the website shows for each product, shopping bags, checkout attempts and paid orders. It also logs each website sync, including what changed before and after.

Each source system is used only through its own functions, for example `store_ops.record_sale()`, `supply.record_supplier_delivery()` and `online.checkout()`. The other triggers in these schemas send each new record to the ETL layer (Section 3.2). Two more schemas, `etl` and `dw`, hold the integration layer and the data warehouse. The default `public` schema is not used.

> **[TODO Figure 3.1]** CloudBeaver navigator showing the five schemas in `pethaven_demo`, with the `store_ops` tables expanded.

> **[TODO Figure 3.2]** Overview of the schemas and their tables.

### 3.2 Integrated data warehouse

The integrated data warehouse is the `dw` schema. It uses a star schema with one fact table, three dimension tables, two sync tables and eight report views.

**Table 3.2. Data warehouse tables**

| Table | Type | Description |
| --- | --- | --- |
| `fact_stock_event` | Fact | One row for every change to one product's stock at one store |
| `dim_product` | Dimension | Product code (the item number), name, category and price |
| `dim_store` | Dimension | One code per store (S01–S05), plus ONLINE |
| `dim_date` | Dimension | Sydney business date, day name and weekend flag |
| `sync_run` | Sync | One row per website sync: scheduled or manual, and how many events it covered |
| `sync_change` | Sync | What each sync changed (before → after) |

The grain of `fact_stock_event` is one stock change for one product at one store. Events from all three source systems are stored in this one table. The `source_system` column shows where each event came from (SUPPLY, STORE or ONLINE), and `event_type` shows what happened: a supplier delivery, store sale, reservation, transfer out, transfer in, collection, cancellation or blocked checkout.

Quantities are signed. `quantity_change` is the change to shelf stock and `reserved_change` is the change to reserved stock. For example, a sale of 3 units is stored as −3, and a delivery of 5 cartons is stored as +20 units. Because of this, current stock can be calculated by simply adding up the events.

Before records reach the fact table, the ETL layer (`etl` schema) standardises them. It maps each system's store code to the warehouse store code through an approved mapping, converts cartons to units, and converts UTC to Sydney time. Every fact row keeps a `source_ref`, for example `SUPPLY:supplier SUP-01 order PO-1201 line 1`, and the ETL run that loaded it. This means any number in a report can be traced back to its original source record.

After a fresh build, the warehouse contains 146 stock events, and all 90 store and product combinations match the Store system's live stock. The report views (`rpt_*`) read from these tables, and the dashboard uses them to compare stock across stores, measure how wrong the website number is, and analyse blocked checkouts.

> **[TODO Figure 3.3]** The first 15 rows of the stock event fact table, with signed quantity changes and the source reference for each event.

### 3.3 SQL scripts and synthetic data

All SQL for the prototype is in ten script files (about 2,760 lines) in `workspace/db`. Every file starts with a header comment that states its purpose, the part of the design it implements, its prerequisites and whether it can be rerun, and the code itself is commented throughout. The scripts are run in order by one command (`build.py`), each file in its own transaction, and they build the whole database on a clean server without errors. Table 2 maps each script to the solution design.

**Table 2. SQL scripts and the design components they implement**

| Script | Design component | What it creates |
| --- | --- | --- |
| `01_schemas.sql` | All layers | The five schemas: three source systems, etl and dw |
| `02_store_ops.sql` | Source 1: Store system | Stores, products, store stock, sales and reservations; sale trigger; sale, order, transfer, collection and cancellation functions |
| `03_supply.sql` | Source 2: Supplier system | Suppliers, locations, items and deliveries; delivery trigger that adds cartons × units per carton to the store shelf |
| `04_online.sql` | Source 3: Online system | Web catalogue, website stock, bags, pickup options, checkout (stock check before payment), orders and the website sync |
| `05_warehouse.sql` | Data warehouse | Product, store and date dimensions, the stock event fact table, sync tables and indexes |
| `06_etl.sql` | ETL | Product list, approved store-code mapping, staging tables, extract and load triggers, transformation view, `run_etl()` and data quality view |
| `07_sync.sql` | ETL / data warehouse | Loads each website sync (before → after) into the warehouse |
| `08_reports.sql` | Reports | Report views 1–6 used by the dashboard |
| `seed/01_reference_data.sql` | Synthetic data | Stores, 19 products, suppliers, each system's own store codes and the 15 approved store-code mappings |
| `seed/02_business_history.sql` | Synthetic data | Seven days of trading, created through the source systems' own functions |

**Extract, transform and load.** The ETL runs in near real time. When a source system records something, for example a new `sale_line`, an extract trigger copies the record into a staging table (`etl.stg_*`) in its original format, with its source reference. A load trigger then calls `etl.run_etl()`, which checks the item is on the warehouse product list, maps the store code through the approved mapping, converts cartons to units and UTC to Sydney time, and loads one row into `dw.fact_stock_event`. A record that fails a check is not guessed: it stays in staging with a reason (for example "Unknown item P019") and loads automatically once the item is approved. Every run is logged in `etl.etl_run`.

The warehouse also checks its own data. For example, the fact table's check constraint makes sure each event type always has the right effect on shelf and reserved stock (the sign rules in Table 1):

```sql
CONSTRAINT ck_fact_signs CHECK (
       (event_type = 'store_sale'        AND quantity_change = -units AND reserved_change =  0)
    OR (event_type = 'supplier_delivery' AND quantity_change =  units AND reserved_change =  0)
    OR (event_type = 'reservation'       AND quantity_change = -units AND reserved_change =  units)
    OR (event_type = 'collection'        AND quantity_change =  0     AND reserved_change = -units)
    ...                                  -- (simplified: 8 event types in total)
)
```

**Synthetic data.** The sample data covers five stores and 18 products, plus a new product (P019) that is in the store catalogue but not yet on the warehouse product list, so it can be used to test data validation. The data is not inserted directly into the tables. It is created by calling the source systems' own functions, so every record goes through the triggers and the ETL exactly as live data would. The seven days of trading include 30 supplier delivery dockets (opening stock and restocks), 28 till receipts, 8 online bags (7 paid and 1 blocked at checkout because the website number was stale), click-and-collect transfers, 2 collections, 1 cancellation, 1 overdue order and 2 website syncs. Dates are relative to the day the build runs, so "time since last sync" and overdue orders always look realistic.

After a fresh build, 155 source records have been staged and 146 stock events loaded into the warehouse. The other 9 staged records are paid checkout items, which are skipped because the same sale is already loaded as a reservation. No records are rejected, and all 90 store and product combinations reconcile with the Store system.

> **[TODO Figure 3.4]** Building the prototype database with one command.

> **[TODO Figure 3.5]** One supplier delivery traced from the source system, through staging, to the warehouse. The same delivery appears as 5 cartons at NSW-CHATS in UTC in the source and staging, and as 20 units at store S03 in Sydney time in the warehouse. The shared `source_ref` links all three.

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

The Overview page helps the owner track the sales and losses that inventory problems create. Across the top it shows the main figures: sales, potential lost sales, out of stock, website accuracy and the next website refresh. In-store sales count till-sale items at the selling store. Online sales count paid order items at the pickup store, less cancellations, whether or not the customer has collected them. Sales and potential lost-sales values use the current shelf price. Stock, website status and overdue orders show the current position.

Needs attention first shows how many products have the wrong stock on the website. It also summarises blocked items at checkout, products out of stock and overdue orders by store, with links to their details. Best sellers ranks the eight products with the most units sold, with each bar split into in-store and online sales. A product that is out of stock is marked with the number of stores affected. Sales, best sellers and the potential lost-sales figure cover the same 7 days: today and the six preceding days, using Sydney time.

Potential lost sales measures items blocked at checkout before payment. A blocked item is a potential lost sale: nothing was charged, and the data does not establish whether the customer bought it later. The share of online demand (e.g. 20% of online demand on the Potential lost sales tile in Figure X) is units blocked divided by the sum of units sold online and units blocked, over the same period (Report 3). The detail card lists every recorded blocked item, newest first. Selecting a row opens the original checkout record, including its captured website number and the warehouse's reconstruction.

> **[TODO Figure]** Dashboard, Overview, with the blocked P018 checkout selected and its source checkout record open.

#### UC2: website stock (owner)

The core business problem is that the website refresh is not timely, so it shows different data from the in-store data. The owner cares about this because it brings many bad consequences. So the Website stock page shows the owner whether the website is correct now and whether the refresh is keeping it correct. The website shows one stock number for each product, the total stock of the five stores, and that number is only correct after a website refresh. Between refreshes, if in-store sales and supplier deliveries change the real stock, the website can show more or less than the stores have. These situations can lead to lost orders or errors. When the website shows too much, customers put items in their bag that checkout then blocks (UC1). When it shows too little, the customer might not know this item is available to buy, which can stop them ordering because they think it is out of stock.

At the top, a status line shows whether the automatic refresh is running, with its interval and the countdown to the next refresh, and how long ago the last refresh ran. Below it, a banner says either that the website matches the stores for all 18 products, or how many products show the wrong stock, split into too high and too low.

The table of products with the wrong number compares what the website shows for each product with the combined available stock in the five stores (Report 2). The difference is website stock minus store stock. "Website too high" means the website shows more than the stores have, and "Website too low" means the opposite.

Refresh history lists the latest refreshes, newest first. Each row shows the time since the previous refresh, the stock changes in between, the website numbers corrected, and how many products were too high or too low just before it ran. Selecting a refresh shows each corrected number before and after. The owner can use this history to judge whether the refresh interval is short enough. All products lists every product with their online and in-store stock quantity.

> **[TODO Figure]** Dashboard, Website stock, before the manual refresh (P018 "Website too high", P001 "Website too low"), and after it (the refresh history, with the manual refresh opened to show what it corrected).

#### UC3: low stock (store managers)

Store managers are responsible for running their own store. On this problem, they especially need to know which products are running out at their store, so they can reorder before the shelf is empty. An empty shelf loses in-store sales and leaves fewer stores that can supply online orders. The Store stock page shows each store's stock and the items it has sold.

At the top, a store manager can filter to their own store and pick the exact store, category and product. The Low stock filter shows products with 2 or fewer available units. The chart below lists products with the least stock first. Each product has two bars, with available and reserved stock on top. Units sold in the last 7 days sit underneath, counted the same way as on the Overview. When the sold bar is longer than the stock bar, the product sold more last week than the store has left. Selecting only a product shows that product's information.

The table gives each product's available, reserved and on-hand stock at the store, with its stock status (Report 1). Available is shelf stock free to sell. Reserved stock is held for click and collect orders and has already left the shelf. On hand is the two together. A product at 1 or 2 available units is marked Low stock; at zero it is marked Out of stock. If a store is out of stock and a customer still wants to pick up there, the store can transfer stock from another store that has it. While the transfer is on the way, stock in transit belongs to neither store and is not counted.

Selecting a product row opens the stock movements for that product at that store, newest first, from the warehouse's stock events. Each line says what happened, such as "Delivery from Pawfect Foods" or "Sent to Bondi for online order 5", with the quantity change and the supplier order or till receipt behind it. In Figure X, Chatswood has 113 Adult Dry Dog Food (P001) on the shelf, and the newest movement is the 20-unit delivery under supplier order PO-3003. The page also shows what is running low. The reorder itself sits outside the prototype; store managers place it themselves.

> **[TODO Figure]** Dashboard, Store stock for Chatswood with P001 selected, showing the event history with supplier order PO-3001.

#### UC4: click and collect orders (store staff)

Store staff's job is to carry out inventory. In this scenario, that means the click and collect counter. They need to know which items to send to other stores and which are on their way. They also need to see which orders are ready for customers, with overdue orders first. Uncollected orders also keep stock off the shelf. The Click & collect orders page lists the open orders for one store.

At the top, My store picks the store. Four tiles follow the order of the work: Overdue, To send, In transit and Ready to collect. Overdue and Ready to collect count whole orders. To send and In transit count item lines, because one order can take items from several stores. Selecting a tile filters the tables.

Below, one table per pickup store lists its open orders, overdue first (Report 5). Each item line has its own status: Waiting to be sent, In transit or Ready for collection. An order is ready only when every item is at the pickup store. An order becomes overdue when it has been ready for more than 3 days without being collected. Time spent waiting for a transfer does not count. An overdue order has a red Overdue tag under its number. A second table lists the items the selected store must send to other pickup stores. In Figure X, order 3 at Parramatta is overdue. Order 5 at Bondi is not ready because two of its items are still in transit from Chatswood.

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
