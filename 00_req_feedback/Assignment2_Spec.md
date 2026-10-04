# PetHaven - Assignment 2 Spec: Business Case and Prototype Scope (v6)

3 Oct 2026 · Group 3 · Internal guide, not a submission

This guide defines the business problem, the three source systems, the business actions that create their records, and the stock rules the prototype follows. The solution design that implements it is in [docs/Architecture_and_Data_Model.md](../docs/Architecture_and_Data_Model.md).

**What changed from v5.** Following the tutor's 29 Sep feedback (focus on one problem: inventory not syncing between in-store and online sales), the case was simplified: five stores instead of thirty, no distribution centre or inter-store transfers, deliveries go straight to stores, and the website shows one combined number per product that is refreshed by a manual sync instead of an overnight snapshot and 5 am copy. The three sources are now the **store system**, the **delivery system** and the **online store**.

PetHaven is fictional. Its size, operating arrangements and update rules below are fixed definitions for this project.

## 1. What PetHaven is

| Item | Project definition |
| --- | --- |
| Business | PetHaven Group Pty Ltd, a fictional Sydney pet-supplies retailer. It does not sell animals. |
| Products | Pet food, treats, toys, accessories, bedding, hygiene, health and aquatics. The prototype uses 18 products (plus one new line, P019). |
| Stores | Five: Parramatta, Bondi Junction, Chatswood, Newtown and Penrith. Each has a shop floor and a click-and-collect counter. |
| Sales channels | **In store**, through POS tills; **online**, through the website. |
| Click & Collect (C&C) | An online order collected at one **pickup store** (the store closest to the customer's postcode). Items that store does not have are taken from another store and transferred to it. The only online fulfilment in scope. |
| Supply | Suppliers deliver directly to each store, in cartons. |

Use these words consistently:

- **Channel:** how the customer buys (in store or online).
- **Offering:** what is sold (a product).
- **Fulfilment:** how an online order reaches the customer (here, always collection from one pickup store, with transfers from other stores where needed).
- **Location:** where stock physically is (one of the five stores).

## 2. One business problem

### 2.1 Problem statement

> PetHaven's website shows one combined "available" number per product for all five stores, but that number is only refreshed when a sync is run. In-store sales, supplier deliveries and store-side cancellations change the real stock immediately, yet the website does not see them until the next sync. Between syncs customers can put items in their bag that the website says are in stock but no store can supply; they only find out at checkout. The website can also show too little stock and lose sales.

The customer whose order cannot be supplied is let down; store staff spend time checking shelves and contacting customers; PetHaven loses sales and trust in its stock information.

The cause investigated is **the delay between a stock change in one system and its use in another**. The supporting data requirement is that the three systems name stores and products differently, so their records must be matched reliably before they can be combined.

### 2.2 Scope

The unit of analysis is **one product at one store**, and the combined number for one product across all stores.

In scope: in-store sales, supplier deliveries, online C&C orders with several lines (hold, transfer to the pickup store, collect, cancel), the manual sync, and code matching between systems. Out of scope: customer accounts and membership, grooming, home delivery, returns after collection, stock adjustments and counts, splitting one order line across several stores, the customer choosing a pickup store, pricing and promotions.

## 3. The three source systems

### 3.1 What they are

| Operational system | Used by | Source schema | Main responsibility |
| --- | --- | --- | --- |
| **Store system** (POS tills + stock screens + C&C counter) | Store staff | `store_ops` | Stores, product catalogue, live shelf and reserved stock per store, till receipts, C&C holds |
| **Delivery system** | Receiving staff, suppliers | `supply` | Delivery locations, supplier items, delivery dockets |
| **Online store** | Customers, web team | `online` | Web catalogue, the website stock number, collection points, online orders |

The lab hosts them as separate schemas in one PostgreSQL database. They are separate systems: none has a foreign key into another, and they cooperate only through the actions in section 4.

The **integrated data warehouse** (`dw`), fed by the ETL layer (`etl`), is a separate analytical store. It is not a fourth source.

### 3.2 Each system has its own codes

| | Store system | Delivery system | Online store |
| --- | --- | --- | --- |
| Store | store number `101`–`105` | location code `NSW-PARRA` | collection point `CP-PARRAMATTA` |
| Product | EAN-13 barcode `9300601001019` | supplier SKU `PF-DOG-ADT-3K` | web SKU `WEB-10001` |
| Quantity | units | cartons | units |
| Time | Sydney time | UTC | Sydney time |

The warehouse gives each store and product one conformed code (`S01`, `P001`) and matches each system's code to it only through an **approved mapping** (section 5.4).

## 4. Business actions and what they change

All changes to a store's stock happen **immediately** when the action is recorded.

### 4.1 Store system

| Action | Recorded as | Store stock effect | Website number |
| --- | --- | --- | --- |
| Till sale (one receipt, one or more items) | `sale` + `sale_line` | shelf − qty per item; the whole receipt is refused if any item is short | unchanged until sync |
| Held line sent to the pickup store | `reservation` → `in_transit` | supplying store: reserved − qty (in transit, in no store) | unchanged (already deducted) |
| Transferred line arrives | `reservation` → `arrived` | pickup store: reserved + qty | unchanged |
| Customer collects a C&C order (only when every line is at the pickup store) | each `reservation` → `collected` | pickup store: reserved − qty (goods leave) | unchanged (already deducted) |
| C&C order cancelled before collection (not while a line is in transit) | each `reservation` → `cancelled`, with reason | where the units are: reserved − qty, shelf + qty | unchanged until sync |

### 4.2 Delivery system

| Action | Recorded as | Store stock effect | Website number |
| --- | --- | --- | --- |
| Supplier delivery to a store | `delivery` + `delivery_line` in cartons | shelf + cartons × units per carton at that store | unchanged until sync |

### 4.3 Online store

| Action | Recorded as | Effect |
| --- | --- | --- |
| Customer adds items to the bag | `basket` + `basket_item` | Allowed only up to the website number (which may be stale). Nothing is held. |
| Customer checks out (before payment) | `checkout_attempt` + items | 1. **Pickup store** = the store closest to the postcode. 2. For each item, find a store whose **real** shelf stock covers the whole quantity: the pickup store first, then the others by distance. 3. If **any** item is unavailable → checkout **blocked**: nothing charged, nothing held, the customer sees which items to remove and can check out again. 4. Otherwise → **paid**: `web_order` + `web_order_line` created; each item held at its supplying store (shelf − qty, reserved + qty), to be **transferred** to the pickup store if it is another store; the website number drops by each item at once. |

## 5. Stock definitions and rules

### 5.1 Definitions

| Term | Meaning |
| --- | --- |
| In store | Units on one store's shelf, free to sell. |
| Reserved | Units at one store held for C&C orders: waiting for collection there, or waiting to be sent to another pickup store. Units in transit between stores are in no store. |
| On hand | In store + reserved. |
| Real combined available | Sum of in store over the five stores. Reserved units are not available. |
| Website number | The one number per product the website shows, and uses to let items into the bag. |
| Stale | Website number ≠ real combined available. |
| Blocked at checkout | A bag item the website showed as in stock that no single store could supply at checkout. Found before payment, so nothing is charged. |

### 5.2 How the website number changes

1. A **sync** sets it to the real combined available, calculated from the warehouse.
2. Between syncs it drops by each **held** online order line (the website knows its own sales).
3. Nothing else changes it: in-store sales, deliveries and cancellations wait for the next sync; transfers and collections do not change it (the units were already deducted).

Overstated website number → items blocked at checkout (lost sales, frustrated customers). Understated → hidden stock and lost online sales. C&C orders waiting more than 3 days are overdue.

### 5.3 Items blocked at checkout

Checkout always checks real store stock before payment, so a paid order can always be fulfilled. An item is blocked when the website let it into the bag but no single store had the whole quantity at checkout. Two causes are distinguished: **stale number** (the real combined stock was already below the order) and **stock split across stores** (enough in total, but not at any one store).

### 5.4 Matching codes between systems

Each system's store and product codes are mapped to the warehouse's codes only through an approved mapping kept by a data steward. Matching by name is never used (names differ between systems). A record whose code has no approved mapping is **rejected with a reason, not guessed**; the business transaction still completes in its own system, and the record loads into the warehouse as soon as the mapping is approved.

## 6. The sync

The sync is run **on demand** (a single function, script command or button), not on a timer, so the presenter can make several changes and then show the website before and after.

When run, it:

1. Takes every stock event recorded since the previous sync.
2. Recalculates each store's running totals and each product's real combined available.
3. Updates the website number for every product.
4. Logs the sync: time, number of events processed, and every store and website number it changed (before → after).
5. Confirms that the warehouse agrees with the store system.

## 7. What the prototype demonstrates

### 7.1 Data flow

Business action → source system (stock changes immediately) → ETL extracts the record in its source format → maps codes, converts units and time, validates → loads one stock event into the warehouse → reports read the warehouse → the sync recalculates and publishes the website number.

### 7.2 Required reports

| # | Report | Answers |
| --- | --- | --- |
| 1 | Current stock by store | In-store vs reserved per store and product |
| 2 | Online staleness | Time since last sync, events pending, products whose website number is wrong, and before/after of the last sync |
| 3 | Items blocked at checkout | Which bag items the website showed in stock but checkout blocked, for which pickup store, and why |

Additional reports: daily sales by store and category; open C&C order lines (source store, transfer status, order ready, overdue); warehouse vs store reconciliation and rejected source records.

### 7.3 Demonstration cases (in the sample data)

**Case 1: stale number blocks a checkout.** The website was synced when 7 aquarium kits were in stock. Five then sold in store at three stores. A Bondi customer put 3 in the bag: the website still showed 7, so it let them in, but only 2 were left (1 each at Newtown and Penrith). Checkout was blocked before payment; the customer left without buying. Report 3 records it against Bondi with the reason "stale website number".

**Case 2: pickup store cannot supply, so stock is transferred.** A Penrith customer ordered 2 orthopaedic beds. Penrith (the pickup store) had 1, so the beds were taken from Parramatta, the next-nearest store with 2, and transferred to Penrith. They arrived but were never collected, so the order is overdue.

**Case 2b: three items, not all at the pickup store.** A Bondi customer ordered cat food, 2 dog beds and 4 scratching posts. Bondi held the cat food; the beds and posts were taken from Chatswood and are in transit, so the order is not ready to collect yet.

**Case 3: the sync corrects the website.** After sales and deliveries, the website shows numbers that are too high or too low. Running the sync shows each product's old and new number and each store total that moved.

**Case 4: unmatched new product.** A new cat tunnel (P019) is delivered and sold before the warehouse has approved its codes. The stores work normally; the warehouse rejects the records with a reason and the reconciliation shows the gap until the mapping is approved.

## 8. Word list

| Word | Meaning here |
| --- | --- |
| Source system | An operational system that records business actions (store system, delivery system, online store). |
| Data warehouse | The integrated analytical database (`dw`) combining the three sources. |
| ETL | Extract, transform, load: copying source records into staging, converting them, and loading them into the warehouse. |
| Staging | ETL tables holding source records in their original format. |
| Conformed code | The warehouse's own code for a store (`S01`) or product (`P001`), shared by all reports. |
| Surrogate key | Integer key generated by the warehouse for a dimension row. |
| Fact / dimension | Fact: a measured event (a stock change). Dimension: descriptive context (product, store, date). |
| Grain | What one fact row represents: one stock change for one product at one store. |
| Sync | The manual job that recalculates and publishes the website number. |
| Reconciliation | Comparing warehouse totals with the store system's live stock. |
