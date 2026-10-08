# Keeping Website Stock in Step with Five Stores: An Integrated Data Warehouse Prototype for PetHaven

32113 Advanced Database · Assignment 2 · Spring 2026

[TODO: group ID, student names and UTS IDs, demo video link, GitHub link]

---

## Executive Summary

PetHaven is a fictional Sydney pet-supplies retailer with five stores and a website. The website shows one stock number per product for all five stores, and that number is only updated when a sync runs, every 3 minutes. In-store sales, supplier deliveries and cancellations change real stock straight away, so between syncs the website can show stock that no store has. Customers add these items to their bag and only find out at checkout that they cannot buy them.

We designed and built a prototype for this problem in the Lab Environment on PostgreSQL 15. Three source systems (a store system, a supplier delivery system and an online store) share one item number per product but keep their own transaction IDs, store codes, units and time zones. An ETL layer captures every source record with its transaction ID, checks the item against the warehouse product list, maps store codes through an approved mapping, converts cartons to units and UTC to Sydney time, and loads one stock-event fact table in a star schema. A scheduler copies real shelf totals from the store system to the website every 3 minutes (a manual "run sync now" is kept), and the warehouse records what each sync changed. Report views and a web dashboard show current stock, how stale the website is and which checkouts were blocked. One script builds the whole prototype, and it passes 104 automated behaviour checks, 17 scheduler checks and 67 dashboard checks.

---

## 1. Introduction

PetHaven sells pet food, treats, toys, bedding, health and aquarium products in five Sydney stores (Parramatta, Bondi Junction, Chatswood, Newtown and Penrith) and on its website. Customers buy either at a store till or online, collecting the order from a store they choose.

The website shows one combined "available" number per product for all five stores, and that number is refreshed only when a sync runs, every 3 minutes. Every till sale, supplier delivery and cancelled order changes the real stock in a store at once. Between syncs the website can show stock that is already gone, so customers put items in their bag and are only told at checkout that no store can supply them. The number can also be too low, which hides stock and loses sales.

The cause is the delay between a stock change in one system and its use in another. A second problem makes it hard to measure: although all three systems identify a product by the same item number (for example `P001`), each numbers its own transactions differently (a receipt number in store, an order ID online, a supplier ID and supplier order number for deliveries), names the stores differently, and the supplier delivery system counts in cartons with times in UTC. Their records have to be converted and traced reliably before they can be combined.

The prototype has five goals:

1. Run three source systems as separate PostgreSQL schemas, each with its own codes and rules.
2. Load every stock change into one data warehouse through an ETL layer that keeps each record's transaction ID, converts units and times, maps store codes only through an approved mapping and accepts only items on the warehouse product list.
3. Let the online store refresh the website number from real shelf stock every 3 minutes (and on demand), while the warehouse records what each sync changed.
4. Report what stock each store holds, how stale the website is, and which checkouts were blocked and why.
5. Show that all of this works with repeatable automated checks and a recorded demonstration.

---

## 2. Solution Design

### 2.1 Solution Architecture

> **[TODO Figure 1]** Architecture diagram. Use the "How data reaches the reports" diagram on the dashboard's Data & integration page, or export the Mermaid diagram from `docs/Architecture_and_Data_Model.md` §2 via mermaid.live.

The solution has five layers, each in its own PostgreSQL schema. Three are the operational systems PetHaven uses every day:

- **Store system** (`store_ops`): tills, live shelf and reserved stock in each store, and click-and-collect holds.
- **Supplier delivery system** (`supply`): supplier deliveries to each store, recorded in cartons.
- **Online store** (`online`): the web catalogue, the website stock number, the customer's bag, checkout and online orders.

The other two layers are the **ETL layer** (`etl`), which moves data from the sources into the warehouse, and the **integrated data warehouse** (`dw`), which the reports read.

The three source systems behave like separate products from different vendors. No source table has a foreign key into another source. They interact only through a few business functions, for example a supplier delivery calls the store system's function for receiving goods, and checkout asks the store system to find and hold stock.

Data moves along two separate paths. On the **analytical path**, a business action changes a source system, the ETL copies the record into staging, transforms it and loads it into the warehouse, and reports read the warehouse. On the **operational path**, the sync reads real shelf totals from the store system and writes them to the website number. A small scheduler in the lab's Python container runs it every 3 minutes (`SYNC_INTERVAL_SECONDS = 180`, the one place the interval is set), and it can also be run by hand. The warehouse is not part of this path; it only receives a log of each sync so the reports can show what was corrected.

### 2.2 Conceptual Model of Data Entities

> **[TODO Figure 2]** Conceptual ER diagram. Mermaid diagram in `docs/Architecture_and_Data_Model.md` §3.

The central entity is the **stock position**: the units of one product at one store. It has two parts. **In store** units are on the shelf and free to sell. **Reserved** units are held for online orders. Till sales and supplier deliveries change the shelf. Online orders create **reservations**, which hold stock at a store until the customer collects it. Every one of these changes is a **stock event**, and the stock events together form the single history of stock across all systems.

On the online side, each **product** has one **website number**, the combined quantity the website shows. A **sync** replaces the website numbers with the real shelf totals. Between syncs the website number only goes down when the website itself sells something. We call a website number **stale** when it differs from the real combined shelf stock. A bag item is **blocked at checkout** when the website showed it as in stock but no single store could supply it.

An online order is collected at one **pickup store** that the customer chooses. If an item has to come from another store, it is transferred. Figure 3 shows the life cycle of an order line. While a line is in transit it belongs to no store, so store totals leave it out.

> **[TODO Figure 3]** Order line life cycle (held → in transit → arrived → collected, or cancelled). Mermaid state diagram in `docs/Architecture_and_Data_Model.md` §4.5.

### 2.3 Logical Data Model of Data Entities

#### Source systems

> **[TODO Figure 4]** ER diagrams of the three source schemas. CloudBeaver: right-click `store_ops`, `supply`, `online` → View Diagram.

The **store system** holds the store and product master data, live stock per store and product, till receipts, and reservations. A receipt is refused as a whole if any line is short of stock. Each reservation records the store supplying the units, the pickup store and the time of each step.

The **supplier delivery system** holds supplier delivery locations, supplier items with their units per carton, and supplier delivery dockets. Quantities are in cartons and times are in UTC with no time zone. When a supplier delivery is recorded, it converts cartons to units and adds them to the store's shelf.

The **online store** holds the web catalogue, the website number for each product, collection points, the customer's bag, each checkout attempt and paid orders. A customer can only add an item to the bag up to the website number, and adding holds nothing. At checkout, before payment, the store system checks that one store can supply each item, starting with the pickup store, and locks that stock. If any item is unavailable the checkout is blocked and nothing is charged. Otherwise the order is paid, stock is reserved and the website number drops at once.

All three systems identify a product by the same item number: the bag of dog food is `P001` at the till, at the supplier and on the website; its barcode, units per carton and web title are attributes. What differs is the transaction ID: a receipt number in the store system, an order ID online, and a supplier ID (`SUP-01`) plus supplier order number (`PO-1001`) for supplier deliveries. Store codes also still differ: the same Parramatta store is `101` in the store system, `NSW-PARRA` in the supplier delivery system and `CP-PARRAMATTA` online.

> **[TODO Figure 5]** The item list and each store's code in every system. Dashboard → Data & integration (or `demo.py codes`).

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

The dimensions use surrogate keys and conformed codes (`S01`, `P001`). The date dimension runs from 2020 to 2035 in Sydney time. Two more tables record each website sync: when it ran, which stock events happened since the previous sync, and the before and after value of each number it changed.

### 2.4 Design Rationale

**One fact table of stock events.** Every report needs stock changes over time. A single signed history gives current stock, stock at any earlier moment and an audit trail, without keeping separate balance tables in step.

**One item number, separate transaction IDs.** Every system keys products on the same item number, so products need no translation; each system keeps its own transaction ID, and the warehouse stores it on every event so any number can be traced back to the receipt, order or supplier order behind it. Store codes still differ per system and are joined through an approved mapping, which keeps the warehouse independent of any one source.

**Reject unknown items instead of guessing or failing.** A guessed match corrupts stock silently, and failing the sale would stop a till. Rejecting the record into staging lets the store keep trading, keeps the warehouse correct and shows the gap until a data steward adds the item to the product list.

**ETL in the same transaction as the source change.** Every sale, supplier delivery and order reaches the warehouse immediately, so the source and the warehouse never disagree, and the ETL needs no schedule of its own in the lab.

**The website number comes from the store system.** The website number is operational, and the store system already holds real stock. The warehouse is used for analysis only, so a problem in the warehouse can never stop customers from buying.

**Sync every 3 minutes, plus a manual sync.** A short interval keeps the website at most 3 minutes behind without putting the website update in the path of every till transaction. The interval is one configuration value, not SQL logic. A manual "run sync now" is kept so a demonstration can build up a stale state (with the scheduler stopped) and show the correction on cue.

**Stock checked before payment.** Taking payment and then cancelling costs refunds and trust. Checking and locking real stock at checkout means every paid order can be fulfilled.

### 2.5 Design Trade-offs

**One database for all systems.** Putting the five schemas in one PostgreSQL database keeps the prototype simple and lets the ETL share the source transaction. Real systems would be separate databases connected through messages or APIs, with the warehouse fed from their change logs.

**ETL inside every transaction.** This removes any delay, but every till sale also pays for an ETL run, about 5 ms per sale at our data volume. At production volume the ETL would run asynchronously in small batches every few seconds.

**Type 1 dimensions.** A price change overwrites the old price, so the sales report values past sales at today's price. Type 2 dimensions, or storing the price on the fact, would fix this.

**One store per item.** Each order item must come from a single store, so an item that only two stores together could supply is blocked at checkout. Splitting items across transfers would remove this limit but makes fulfilment more complex.

**Stale numbers on the product page.** Checkout is safe, but customers can still add items that are already gone. Checking real stock when an item is added, or a shorter sync interval, would reduce this.

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

The warehouse is the `dw` schema with the stock-event fact table, the three dimensions and the two sync tables. After the build it holds 146 stock events, and all 90 store and product combinations match the store system.

> **[TODO Figure 8]** A few rows of `dw.fact_stock_event` in CloudBeaver, showing event type, signed quantities and source reference.

### 3.3 SQL scripts and synthetic data

All SQL is commented and runs on a clean database without errors. Table 2 maps each script to the part of the design it implements.

**Table 2. SQL scripts**

| Script | Implements |
| --- | --- |
| `01_schemas.sql` | The five schemas |
| `02_store_ops.sql` | Store system: tables, sale trigger, stock and order functions |
| `03_supply.sql` | Supplier delivery system: tables, supplier delivery trigger |
| `04_online.sql` | Online store: bag, pickup options, checkout, website sync |
| `05_warehouse.sql` | Dimensions, fact table, sync tables, indexes |
| `06_etl.sql` | Warehouse product list, store-code mapping, staging, extract triggers, transform view, load |
| `07_sync.sql` | Records each website sync in the warehouse |
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

The synthetic data covers five stores and 18 products, plus a new product (P019) that is deliberately left off the warehouse product list. It is created through the source systems' own functions, so every record passes through the ETL just as live data would. The seven days of trading include opening stock and restock supplier deliveries, 28 till receipts, eight online bags (seven paid and one blocked by a stale website number), collections, a cancellation and two syncs. Dates are relative to the build day, so "time since last sync" and overdue orders always look realistic.

> **[TODO Figure 9]** Output of `build.py`, ending with 155 records staged, 146 loaded, 0 rejected, 0 not reconciled.

> **[TODO Figure 10]** One supplier delivery traced from source to warehouse: cartons and UTC in staging, units and Sydney date in the fact table. Dashboard → record a supplier delivery in the Demo actions panel → View data trace.

### 3.4 Reports and dashboard

The reports are views in the `dw` schema. A local web dashboard presents them. It opens on an Overview for the company admin (website accuracy, next sync, stock alerts, lost sales, open orders), and its Demo actions panel records sales, supplier deliveries, orders, manual syncs and product-list additions through the source systems.

**Report 1: current stock by store.** Shelf and reserved units for each store and product, with low-stock flags. It also lists the stock events behind each number.

> **[TODO Figure 11]** Dashboard → Store stock.

**Report 2: website staleness.** For each product, the website number next to the real combined stock, whether it is too high or too low, how long since the last sync, when the next scheduled sync is due, and what the last sync changed.

> **[TODO Figure 12]** Dashboard → Website stock, before a sync (some products "Website too high"). If space allows, a second screenshot after the sync.

**Report 3: items blocked at checkout.** Each item that checkout blocked, the pickup store, what the website showed, what was really available and why it was blocked (a stale website number, or stock split across stores).

> **[TODO Figure 13]** Dashboard → Orders & lost sales → Blocked items, with one row selected to show the source checkout record.

Three further reports support these: daily sales by store, channel and category; open click-and-collect orders and their transfer status; and a reconciliation of the warehouse against the store system, together with any rejected records.

> **[TODO Figure 14]** Dashboard → Data & integration, showing the rejected "Unknown item P019" records and the reconciliation gap before the item is added to the product list.

### 3.5 End-to-end testing

Three automated test scripts build a separate test database and run scripted business events. The first checks every business rule, from stock updates and checkout to transaction IDs, unknown-item rejection, the sync and reconciliation, and passes all 104 checks. The second starts the scheduler with a 2-second test interval and checks that it syncs on time, is recorded as scheduled and can be stopped; it passes all 17 checks. The third tests the dashboard's interface and passes all 67 checks.

> **[TODO Figure 15]** Last lines of the three test runs: `PASS 104, FAIL 0`, `PASS 17, FAIL 0` and `PASS 67, FAIL 0`.

The demonstration video starts from a fresh build and shows the core problem and its fix as queries in CloudBeaver. The website and the five stores agree on 183 bags of dog food (P001). A customer buys 3 at the Parramatta till: the store's shelf drops from 37 to 34 at once and the sale appears in the warehouse, traced to its receipt number, but the website still shows 183, so an online customer could try to buy stock that is gone. The sync then takes the real shelf totals from the store system and the website shows 180; the warehouse records the sync and what it changed (website 183 → 180). The video also shows the same correction happening on its own at the next 3-minute scheduled sync.

The rest of the prototype is demonstrated by a second part of the same script and covered by the automated checks. A supplier delivery of 5 cartons for supplier SUP-01, order PO-2001, arrives as 20 units on a Sydney date. A checkout with two dog beds is blocked before payment because no single store has both. A customer chooses Bondi for pickup, and one item is transferred from Newtown. The last aquarium kit sells in store, the website still shows one, and the next online checkout for it is blocked and recorded in Report 3. The new product P019 is delivered and sold before it is on the warehouse product list; its records are rejected as "Unknown item" and load once a data steward adds it.

Demo video: [TODO link]

---

## 4. Report Summary and Conclusion

PetHaven's website stock number falls behind the stores between syncs, so customers try to buy items that no store can supply. This project designed and built a data solution for that problem.

The design keeps the three operational systems separate, each with its own codes, units and time zone, and combines their data only in an integrated data warehouse. An ETL layer captures each source record unchanged, keeps its transaction ID, accepts only items on the warehouse product list, maps store codes through an approved mapping, converts cartons to units and UTC to Sydney time, and loads it as one row in a stock-event fact table with product, store and date dimensions. Records for unknown items are rejected with a reason and load once a data steward adds the item. A sync every 3 minutes (or by hand) refreshes the website number from real shelf totals in the store system. The warehouse does not set that number, but it records every sync so the reports can measure staleness. Checkout checks real stock before payment, so a stale number costs a sale rather than a refund.

The prototype runs in the Lab Environment and one script rebuilds it. It loads a week of synthetic trading, reconciles all 90 store and product combinations with the store system, and passes 104 behaviour checks, 17 scheduler checks and 67 dashboard checks. The reports and dashboard show current stock, website staleness and blocked checkouts, along with sales, open orders and data quality.

The main limitations are that all systems share one database, the ETL runs inside each source transaction, the website can still be up to 3 minutes out of date, the scheduler has to be started by hand, and old prices are not kept. A production version would use separate databases, asynchronous data capture, a scheduler run as a managed service and type 2 dimensions for prices.

---

## Appendix

[TODO A: individual contribution evidence (logbooks, emails, task allocation)]

[TODO B: at least 3 meeting minutes on the Canvas template, signed by the tutor]

[TODO C: individual contribution form]

[TODO D: group self-assessment (HD / D / C / P / F)]
