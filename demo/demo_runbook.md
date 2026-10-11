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

## Example 2 — Store / Online Events

Briefly show how store and online events are also mapped into a common analytical structure.

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
