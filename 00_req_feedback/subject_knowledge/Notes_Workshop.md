# 32113 Advanced Database — Workshop Implementation Reference

> Purpose: a practical reference for rebuilding the workshop ideas in a real project.  

# 0. Overall Workshop Architecture

Across the workshops, the subject gradually builds this engineering workflow:

```text
Development Environment
        |
        v
Source Data
        |
        v
Ingestion
        |
        v
RAW / BRONZE
        |
        v
CLEANSED / SILVER
        |
        v
CURATED / GOLD
        |
        +--------------------+
        |                    |
        v                    v
Relational Analytics      Graph Model
        |                    |
        v                    v
Views / Reports          Neo4j / Cypher
        |
        v
Performance Tuning
Indexes / Cache / Partitioning / Query Optimisation
```

Two naming conventions appear in the workbook:

| Workshop 2 | Workshop 6 | Main role |
|---|---|---|
| RAW | BRONZE | Preserve source data |
| CLEANSED | SILVER | Clean, standardise, validate |
| CURATED | GOLD | Analytics-ready/business model |

Workshop 6 also introduces an explicit `audit` schema for pipeline execution logging.

---

# Workshop 1 — Introduction to Advanced Database

## 1. Technical stack

The workshop establishes the environment used by the rest of the subject:

- Docker — runs services in containers.
- VS Code — development workspace.
- Python — integration and processing layer.
- PostgreSQL — relational database.
- CloudBeaver — browser-based SQL GUI.
- DuckDB — in-process analytical database.
- Neo4j — graph database.
- ClickHouse — column-oriented analytical database.

The important architectural idea is that Python and several database systems can run as separate services but communicate inside one Docker environment.

## 2. Project directory

```text
advanced-database-lab/
|
|-- docker-compose.yml
|-- python/
|   |-- Dockerfile
|   |-- requirements.txt
|
|-- workspace/
|-- data/
```

What each component does:

- `docker-compose.yml`: defines services, ports, networks, credentials, and volumes.
- `Dockerfile`: defines the Python runtime/container.
- `requirements.txt`: Python dependencies.
- `workspace/`: Python, SQL, datasets, and lab scripts.
- `data/`: persistent database data.

## 3. Verify Docker

```bash
docker --version
docker compose version
```

This confirms Docker and Docker Compose are available.

## 4. Start services

```bash
docker compose up -d
```

This reads `docker-compose.yml`, creates the services, and starts them in detached mode.

Typical containers:

```text
python
postgres
cloudbeaver
neo4j
clickhouse
```

## 5. Verify running containers

```bash
docker ps
```

This confirms the services are actually running.

## 6. Access services

```text
CloudBeaver     http://localhost:8978
Neo4j Browser   http://localhost:7474
ClickHouse      http://localhost:8123
```

## 7. Connect CloudBeaver to PostgreSQL

Typical workshop settings:

```text
Host: postgres
Port: 5432
Database: lab
Username: student
Password: student
```

Inside Docker Compose, the service name `postgres` acts as the hostname.

## 8. Stop/restart/remove environment

```bash
docker compose stop
docker compose start
docker compose down -v
docker compose up -d
```

Meaning:

- `stop`: stop containers but preserve them.
- `start`: restart stopped containers.
- `down -v`: remove containers/networks and volumes; persisted DB data can be deleted.
- `up -d`: recreate/start the environment.

---

# Workshop 1 — Basic PostgreSQL Operations

## 9. Create a table

```sql
CREATE TABLE inventory (
    item_id SERIAL PRIMARY KEY,
    item_name VARCHAR(100) NOT NULL,
    quantity INT DEFAULT 0,
    price NUMERIC(10,2)
);
```

What it demonstrates:

- `SERIAL PRIMARY KEY`: generated unique ID.
- `NOT NULL`: mandatory value.
- `DEFAULT`: fallback value.
- `NUMERIC(10,2)`: fixed-precision decimal for prices.

## 10. Insert rows

```sql
INSERT INTO inventory (item_name, quantity, price)
VALUES ('Laptop', 15, 1299.99);
```

This adds records to the table.

## 11. Query rows

```sql
SELECT *
FROM inventory;
```

This validates that the table was populated correctly.

## 12. Python execution inside Docker

```bash
docker compose exec python python /workspace/lab1_python_test.py
```

The script runs inside the Python container, using the dependencies defined by the project environment.

## 13. Python database connections

```python
import duckdb
import psycopg2
from neo4j import GraphDatabase
```

PostgreSQL:

```python
pg = psycopg2.connect(
    dbname="lab",
    user="student",
    password="student",
    host="postgres",
    port=5432
)
```

Neo4j:

```python
neo = GraphDatabase.driver(
    "bolt://neo4j:7687",
    auth=("neo4j", "password")
)
```

DuckDB:

```python
duck = duckdb.connect()
```

This introduces Python as the orchestration/integration layer between databases.

## 14. Execute SQL through Python

```python
cur = pg.cursor()
cur.execute("""
SELECT * FROM inventory;
""")
rows = cur.fetchall()
print(rows)
```

- `cursor()`: creates a SQL execution handle.
- `execute()`: sends SQL to PostgreSQL.
- `fetchall()`: retrieves returned rows.

This pattern later becomes the basis for automated ETL pipelines.

---

# Workshop 2 — Database System Architecture

## 15. Main pipeline

```text
Operational Sources
       |
       v
RAW
       |
       v
CLEANSED
       |
       v
CURATED
       |
       v
Dashboards / Reports
```

This is one of the most reusable workshop patterns for a project.

## 16. Create schemas

```sql
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS cleansed;
CREATE SCHEMA IF NOT EXISTS curated;
```

Schemas separate data by processing stage and make lineage visible.

## 17. Verify schemas

```sql
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN ('raw', 'cleansed', 'curated')
ORDER BY schema_name;
```

This queries PostgreSQL metadata to confirm the layers were created.

---

# Workshop 2 — RAW Layer

## 18. Create source-matching raw tables

Example:

```sql
CREATE TABLE raw.customers (
    customer_id INTEGER,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    email VARCHAR(255),
    city VARCHAR(100),
    state VARCHAR(100),
    created_date DATE,
    ingestion_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

The workshop also creates:

```text
raw.products
raw.orders
raw.order_items
```

Purpose of RAW:

- preserve source data closely;
- allow duplicates/inconsistencies to remain visible;
- record ingestion metadata;
- provide a historical landing layer before business rules are applied.

`ingestion_timestamp` records when the row entered the platform.

---

# Workshop 2 — Data Ingestion

## 19. CloudBeaver import

```text
CSV -> CloudBeaver Import -> raw.<table>
```

This is a manual ingestion method suitable for a small demonstration.

## 20. Python ingestion

```python
import pandas as pd
from sqlalchemy import create_engine
from datetime import datetime

engine = create_engine(
    "postgresql://admin:admin@postgres:5432/lakehouse"
)

def load_to_postgres(file_name, table_name):
    df = pd.read_csv(f"data/{file_name}")
    df["ingestion_timestamp"] = datetime.now()

    df.to_sql(
        name=table_name,
        con=engine,
        schema="raw",
        if_exists="append",
        index=False
    )
```

Then:

```python
load_to_postgres("customers.csv", "customers")
load_to_postgres("products.csv", "products")
load_to_postgres("orders.csv", "orders")
load_to_postgres("order_items.csv", "order_items")
```

Pipeline meaning:

```text
CSV
 |
 v
pandas.read_csv()
 |
 v
DataFrame
 |
 +--> add ingestion timestamp
 |
 v
DataFrame.to_sql()
 |
 v
PostgreSQL RAW table
```

For a real project this is preferable to manual import because it is repeatable and version-controlled.

---

# Workshop 2 — Explore and Profile RAW Data

## 21. Inspect raw tables

```sql
SELECT * FROM raw.customers;
SELECT * FROM raw.products;
SELECT * FROM raw.orders;
SELECT * FROM raw.order_items;
```

The workshop asks you to inspect:

- missing values;
- formatting inconsistencies;
- duplicate rows;
- negative prices;
- invalid quantities.

This is an early form of **data profiling**.

## 22. Basic SQL exploration

Operations include:

```sql
SELECT
FROM
WHERE
ORDER BY
JOIN
```

Tasks include filtering customers, sorting records, selecting specific attributes, and joining customers to orders.

Purpose: understand source structure before applying transformations.

---

# Workshop 2 — CLEANSED Layer

## 23. Clean and standardise customer data

```sql
CREATE TABLE cleansed.customers AS
SELECT DISTINCT
    customer_id,
    TRIM(first_name) AS first_name,
    TRIM(last_name) AS last_name,
    LOWER(TRIM(email)) AS email,
    INITCAP(city) AS city,
    INITCAP(state) AS state,
    created_date
FROM raw.customers
WHERE customer_id IS NOT NULL;
```

Operations:

- `DISTINCT`: remove exact duplicates.
- `TRIM()`: remove whitespace.
- `LOWER()`: standardise email casing.
- `INITCAP()`: standardise presentation of names/locations.
- `WHERE ... IS NOT NULL`: reject records without required IDs.

## 24. Correct invalid numeric values

```sql
CASE
    WHEN unit_price < 0 THEN 0
    ELSE unit_price
END AS unit_price
```

Similar logic is applied to invalid quantities.

This demonstrates rule-based data cleansing.

## 25. Convert data types

```sql
CAST(order_date AS DATE) AS order_date
```

Raw strings become strongly typed values suitable for validation, indexing, and date logic.

---

# Workshop 2 — Data Integrity

## 26. Add primary keys

```sql
ALTER TABLE cleansed.customers
ADD PRIMARY KEY(customer_id);
```

Primary keys are also added to products, orders, and order items.

The workshop intentionally introduces stronger constraints in the cleansed layer rather than raw ingestion.

## 27. Add foreign keys

```sql
ALTER TABLE cleansed.orders
ADD CONSTRAINT fk_customer
FOREIGN KEY(customer_id)
REFERENCES cleansed.customers(customer_id);
```

Other relationships:

```text
order_items.order_id   -> orders.order_id
order_items.product_id -> products.product_id
```

This prevents orphan references.

---

# Workshop 2 — CURATED Layer

## 28. Build dimensions

```text
curated.dim_customer
curated.dim_product
curated.dim_date
```

Example date dimension:

```sql
CREATE TABLE curated.dim_date AS
SELECT DISTINCT
    order_date,
    EXTRACT(YEAR FROM order_date) AS year,
    EXTRACT(MONTH FROM order_date) AS month,
    EXTRACT(QUARTER FROM order_date) AS quarter,
    EXTRACT(DAY FROM order_date) AS day
FROM cleansed.orders;
```

## 29. Build a fact table

```sql
CREATE TABLE curated.fact_sales AS
SELECT
    oi.order_item_id,
    o.order_id,
    o.customer_id,
    oi.product_id,
    o.order_date,
    o.status,
    oi.quantity,
    oi.unit_price
FROM cleansed.orders o
INNER JOIN cleansed.order_items oi
    ON o.order_id = oi.order_id;
```

The resulting model is a star schema:

```text
               dim_customer
                    |
                    |
dim_product ---- fact_sales ---- dim_date
```

Purpose: organise data for reporting and analytical queries rather than source-system transactions.

---

# Workshop 2 — Analytical Views

## 30. Customer sales view

```sql
CREATE OR REPLACE VIEW curated.vw_customer_sales AS
SELECT
    c.customer_id,
    c.first_name,
    c.last_name,
    c.city,
    c.state,
    COUNT(DISTINCT f.order_id) AS total_orders,
    SUM(f.quantity) AS total_quantity
FROM curated.dim_customer c
INNER JOIN curated.fact_sales f
    ON c.customer_id = f.customer_id
GROUP BY
    c.customer_id,
    c.first_name,
    c.last_name,
    c.city,
    c.state;
```

## 31. Product performance view

Uses:

```text
SUM(quantity)
AVG(unit_price)
GROUP BY product
```

## 32. Daily sales view

Uses:

```text
COUNT(DISTINCT order_id)
SUM(quantity)
GROUP BY order_date
```

Views provide a stable serving layer for dashboards and reports.

---

# Workshop 3 — Storage and Compute

## 33. Main idea

Physical design affects:

- storage consumption;
- memory use;
- cache efficiency;
- disk I/O;
- query performance.

Conceptual flow:

```text
SQL
 |
 v
Query Processor
 |
 v
Storage Engine
 |
 +--> Data Pages
 +--> Indexes
 +--> Partitions
 |
 v
Disk Storage
```

---

# Workshop 3 — Character Data Types

## 34. Compare `TEXT`, `VARCHAR(4)`, and `CHAR(4)`

The workshop creates three equivalent tables and inserts one million records into each.

Synthetic-data pattern:

```sql
INSERT INTO users_text(postcode, age)
SELECT
    lpad((random()*9999)::int::text, 4, '0'),
    (random()*80)::int
FROM generate_series(1,1000000);
```

Purpose: create enough rows for storage differences to become measurable.

## 35. Measure table size

```sql
SELECT
    relname,
    pg_size_pretty(
        pg_total_relation_size(relid)
    )
FROM pg_catalog.pg_statio_user_tables;
```

Lesson:

- `TEXT` and `VARCHAR` are stored similarly in PostgreSQL.
- `CHAR` may consume more space because shorter values are padded.

---

# Workshop 3 — Integer Storage

## 36. Compare integer sizes

```text
SMALLINT  2 bytes
INTEGER   4 bytes
BIGINT    8 bytes
```

The workshop creates equivalent tables and inserts one million rows into each, then compares total relation size.

Purpose: show that oversized types increase storage and memory pressure.

---

# Workshop 3 — Storage vs Compute

## 37. Core relationship

```text
Smaller tables
     |
     +--> more likely to fit in cache
     +--> less disk I/O
     +--> less memory movement
     +--> less data scanned
     +--> potentially faster queries
```

Schema design and data-type selection therefore affect performance, not only storage cost.

---

# Workshop 3 — Indexes

## 38. Baseline query without index

```sql
EXPLAIN ANALYZE
SELECT *
FROM sales
WHERE customer_id = 500;
```

Without an index PostgreSQL may choose a sequential or parallel sequential scan.

## 39. Create index

```sql
CREATE INDEX idx_customer
ON sales(customer_id);
```

## 40. Re-run query

```sql
EXPLAIN ANALYZE
SELECT *
FROM sales
WHERE customer_id = 500;
```

The plan may change to:

```text
Bitmap Index Scan
      |
      v
Bitmap Heap Scan
```

Why it improves performance:

- fewer rows need to be inspected;
- less CPU work;
- less I/O;
- less filtering.

Index trade-off:

- extra storage;
- extra maintenance during `INSERT`, `UPDATE`, and `DELETE`.

---

# Workshop 3 — Table Partitioning

## 41. Baseline date-range query

```sql
EXPLAIN ANALYZE
SELECT *
FROM sales
WHERE sale_date
BETWEEN '2025-03-01'
AND '2025-03-31';
```

## 42. Create partitioned table

```sql
CREATE TABLE sales_partitioned (
    id INT,
    customer_id INT,
    amount NUMERIC,
    sale_date DATE
)
PARTITION BY RANGE(sale_date);
```

## 43. Create year partitions

```sql
CREATE TABLE sales_p_2025
PARTITION OF sales_partitioned
FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
```

Equivalent partitions are created for other years.

Physical structure:

```text
sales_partitioned
 |
 +-- sales_p_2023
 +-- sales_p_2024
 +-- sales_p_2025
 +-- sales_p_2026
```

## 44. Inspect partition distribution

```sql
SELECT
    tableoid::regclass AS partition,
    COUNT(*)
FROM sales_partitioned
GROUP BY tableoid
ORDER BY partition;
```

## 45. Partition pruning

A query for 2025 can skip 2023, 2024, and 2026 partitions.

```text
Query predicate on sale_date
          |
          v
Select relevant partition only
          |
          v
Scan less data
```

Partitioning is useful when large tables are frequently filtered by the partition key.

---

# Workshop 3 — Compute Through Joins

## 46. Build fact/dimension-like data

The workshop uses:

```text
customers
products
sales
```

with `sales` as the large table.

## 47. Referential quality check

```sql
SELECT COUNT(*)
FROM sales s
LEFT JOIN customers c
    ON s.customer_id = c.customer_id
WHERE c.customer_id IS NULL;
```

Expected result: `0`.

The same pattern checks missing products.

Purpose: detect orphan source records before analytical processing.

## 48. Analyse large joins

```sql
EXPLAIN ANALYZE
SELECT
    c.customer_name,
    p.product_name,
    SUM(s.amount)
FROM sales s
JOIN customers c
    ON s.customer_id = c.customer_id
JOIN products p
    ON s.product_id = p.product_id
GROUP BY
    c.customer_name,
    p.product_name;
```

Typical operators:

- `Seq Scan` — sequential table read.
- `Hash` — create hash structure.
- `Hash Join` — match rows through hashes.
- `HashAggregate` — maintain groups and compute aggregations.

A large `HashAggregate` can exceed work memory and spill temporary data to disk.

The workshop therefore shows that compute cost comes from scanning, joining, hashing, grouping, and memory management.

---

# Workshop 4 — Caching and Query Performance

## 49. Create performance-test data

The workshop creates:

```text
lab_4.customers
lab_4.products
lab_4.orders
```

and populates them with `generate_series()`, `random()`, and `CASE` expressions.

Purpose: create a large enough workload to observe optimiser and cache behaviour.

---

# Workshop 4 — Cache Behaviour

## 50. Run the same query twice

```sql
SELECT *
FROM lab_4.orders
WHERE quantity = 5;
```

Conceptual first execution:

```text
Disk -> Shared Memory -> Result
```

Later execution:

```text
Cache -> Result
```

The same query may therefore have different execution times depending on cache state.

---

# Workshop 4 — PostgreSQL Statistics

## 51. Cache hit ratio

```sql
SELECT
    datname,
    blks_read,
    blks_hit,
    round(
        100 * blks_hit::numeric /
        (blks_hit + blks_read),
        2
    ) AS cache_hit_ratio
FROM pg_stat_database;
```

Meaning:

- `blks_read`: pages read from disk.
- `blks_hit`: pages found in cache.
- `cache_hit_ratio`: percentage served from memory.

## 52. Update optimiser statistics

```sql
ANALYZE lab_4.customers;
ANALYZE lab_4.orders;
ANALYZE lab_4.products;
```

This refreshes statistics used for cost estimation.

## 53. Inspect column statistics

```sql
SELECT
    tablename,
    attname,
    n_distinct
FROM pg_stats
WHERE tablename = 'customers';
```

The optimiser uses value cardinality/selectivity to choose plans.

---

# Workshop 4 — Query Processing Pipeline

## 54. Processing stages

```text
1. Receive SQL
2. Parse and validate syntax/objects
3. Translate to logical operations / relational algebra
4. Optimise alternative plans
5. Produce physical execution plan
6. Execute using memory/cache/index/storage operators
7. Return result
```

Example SQL:

```sql
SELECT customer_name
FROM lab_4.customers
WHERE city = 'Sydney';
```

Logical interpretation:

```text
Projection(customer_name)
        |
Selection(city='Sydney')
        |
Customers
```

## 55. Inspect physical plan

```sql
EXPLAIN
SELECT customer_name
FROM lab_4.customers
WHERE city = 'Sydney';
```

Possible operators include:

```text
Sequential Scan
Index Scan
Bitmap Scan
Nested Loop Join
Hash Join
Merge Join
```

---

# Workshop 4 — Cost Estimation and Actual Performance

## 56. Estimated plan

```sql
EXPLAIN
SELECT *
FROM lab_4.orders
WHERE customer_id = 500;
```

Example output includes:

```text
cost=0.00..1900.00
```

The first value is startup cost; the second is estimated total cost. These are PostgreSQL cost units, not milliseconds.

## 57. Actual execution

```sql
EXPLAIN ANALYZE
SELECT *
FROM lab_4.orders
WHERE customer_id = 500;
```

This executes the query and reports:

- planning time;
- execution time;
- actual rows;
- loops;
- estimated vs actual behaviour.

---

# Workshop 4 — Query Rewriting

## 58. Subquery version

```sql
SELECT *
FROM lab_4.orders
WHERE product_id IN (
    SELECT product_id
    FROM lab_4.products
    WHERE category = 'Laptop'
);
```

## 59. Join version

```sql
SELECT o.*
FROM lab_4.orders o
JOIN lab_4.products p
    ON o.product_id = p.product_id
WHERE p.category = 'Laptop';
```

The workshop compares both using `EXPLAIN ANALYZE`.

Main lesson: logically equivalent SQL can lead to different physical plans and performance.

## 60. Challenge: identify expensive queries

The workshop compares full scans, selective filters, and joins with `EXPLAIN ANALYZE`.

Project lesson: tune based on measured plans rather than visual SQL complexity.

---

# Workshop 5 — Graph Database

## 61. Architecture

```text
Source Data
(Python Lists)
      |
      v
Python Application
      |
      v
Neo4j Python Driver
      |
      v
Neo4j Database
      |
      v
Cypher Queries
      |
      v
Neo4j Browser
```

## 62. Property Graph Model

Neo4j stores:

```text
Nodes
Relationships
Properties
```

Example node:

```cypher
(:Customer {
    id: 1,
    name: "Alice"
})
```

Example relationship:

```cypher
(Alice)-[:PURCHASED]->(Laptop)
```

This makes relationships first-class stored objects instead of reconstructing every connection through relational joins.

---

# Workshop 5 — Core Cypher Operations

## 63. Find nodes

```cypher
MATCH (c:Customer)
```

## 64. Return results

```cypher
MATCH (c:Customer)
RETURN c
```

## 65. Filter

```cypher
MATCH (c:Customer)
WHERE c.name = "Alice"
RETURN c
```

## 66. Create

```cypher
CREATE (:Customer {id:1})
```

Always creates a new node and can create duplicates if rerun.

## 67. Merge

```cypher
MERGE (:Customer {id:1})
```

Matches an existing entity or creates it if missing; useful for repeatable ingestion.

## 68. Set property

```cypher
SET c.name = "Alice"
```

Updates/assigns node properties.

---

# Workshop 5 — Build Graph Through Python

## 69. Script workflow

The workshop Python script performs:

```text
1. Connect to Neo4j
2. Create/read source data
3. Create uniqueness constraints
4. Load Customer nodes
5. Load Product nodes
6. Load Category nodes
7. Create Product-Category relationships
8. Create Customer-Product purchase relationships
9. Close connection
```

Run:

```bash
docker compose exec python python /workspace/graph_db_architecture.py
```

Source data in a real project could come from CSV files, APIs, PostgreSQL, or a warehouse rather than hardcoded Python lists.

---

# Workshop 5 — Verify and Query Graph

## 70. Count nodes

```cypher
MATCH (n)
RETURN labels(n), count(*)
```

## 71. Count relationships

```cypher
MATCH ()-[r]->()
RETURN type(r), count(*)
```

These are graph-level validation checks.

## 72. One-hop traversal

```cypher
MATCH (c:Customer)
-[:PURCHASED]->
(p:Product)
WHERE c.name = "Alice"
RETURN p.name
```

Meaning:

```text
Alice -> Purchased Products
```

## 73. Two-hop traversal

```cypher
MATCH (c:Customer)
-[:PURCHASED]->
(p:Product)
-[:BELONGS_TO]->
(cat:Category)
WHERE c.name = "Alice"
RETURN cat.name
```

Meaning:

```text
Customer -> Product -> Category
```

## 74. Visualise graph

```cypher
MATCH p=()
--()
RETURN p
```

Neo4j Browser renders the paths visually.

---

# Workshop 6 — Data Warehouse and ETL

## 75. Main architecture

```text
Source CSVs
    |
    v
BRONZE
    |
    v
SILVER
    |
    v
GOLD
    |
    v
Analytics
```

Separate governance/operations layer:

```text
AUDIT
```

This is the most complete end-to-end data-engineering workflow in the workbook.

---

# Workshop 6 — Files and Pipeline Scripts

## 76. Source datasets

The workshop uses Olist ecommerce files such as:

```text
customers
geolocation
order_items
order_payments
orders
products
sellers
category translation
```

## 77. ETL scripts

```text
01_check_environment.py
02_create_schemas.py
03_profile_sources.py
04_load_bronze.py
05_build_silver_etl.py
06_build_gold_etl.py
07_validate_warehouse.py
08_run_analytics.py
config.py
database.py
```

The key engineering pattern is to split the pipeline into small, independently testable stages.

---

# Workshop 6 — Configuration and Environment Check

## 78. Run configuration

```bash
docker compose exec python python /workspace/ecommerce_etl/config.py
```

Configuration defines:

- source data directory;
- PostgreSQL connection string;
- expected datasets.

Keeping config separate avoids duplicating connection/path settings across scripts.

## 79. Check environment

```bash
docker compose exec python python \
/workspace/ecommerce_etl/01_check_environment.py
```

The program checks:

- source files exist;
- source file sizes;
- missing files;
- PostgreSQL connection;
- current database;
- current user;
- PostgreSQL version.

Purpose: fail early before starting ETL.

---

# Workshop 6 — Create Warehouse Schemas

## 80. Create layers

```bash
docker compose exec python python \
/workspace/ecommerce_etl/02_create_schemas.py
```

Creates:

```text
bronze  = raw ingested data
silver  = cleaned/standardised business entities
gold    = analytical models/star schemas
audit   = ETL execution logs
```

Verify:

```sql
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN (
    'bronze',
    'silver',
    'gold',
    'audit'
)
ORDER BY schema_name;
```

---

# Workshop 6 — Profile Sources

## 81. Run profiling

```bash
docker compose exec python python \
/workspace/ecommerce_etl/03_profile_sources.py
```

The script computes:

- row counts;
- column counts;
- missing values;
- duplicate rows;
- duplicate business keys;
- sample records.

Purpose: understand the source before deciding cleansing and matching rules.

---

# Workshop 6 — Load Bronze

## 82. Run loader

```bash
docker compose exec python python \
/workspace/ecommerce_etl/04_load_bronze.py
```

For each CSV, the loader:

```text
1. Creates an audit record
2. Reads the CSV
3. Adds metadata columns
4. Loads into PostgreSQL
5. Validates row counts
6. Updates audit status
```

## 83. Verify bronze tables

```sql
SELECT
    schemaname,
    tablename
FROM pg_tables
WHERE schemaname = 'bronze'
ORDER BY tablename;
```

## 84. Check audit log

```sql
SELECT
    run_id,
    source_name,
    target_table,
    rows_read,
    rows_loaded,
    run_status,
    started_at,
    completed_at
FROM audit.pipeline_run
ORDER BY run_id;
```

This answers:

```text
Which source was loaded?
What target table received it?
How many rows were read?
How many rows were loaded?
Did the load succeed?
When did it start/end?
```

## 85. Validate row counts

```sql
SELECT COUNT(*) FROM bronze.customers_raw;
SELECT COUNT(*) FROM bronze.orders_raw;
SELECT COUNT(*) FROM bronze.order_items_raw;
SELECT COUNT(*) FROM bronze.payments_raw;
```

This checks for incomplete ingestion.

---

# Workshop 6 — Build Silver

## 86. Run transformation

```bash
docker compose exec python python \
/workspace/ecommerce_etl/05_build_silver_etl.py
```

Transformations include:

- remove ingestion metadata where no longer required;
- trim whitespace;
- null handling;
- standardise city names;
- uppercase state codes;
- remove duplicates;
- create derived business fields.

Derived examples:

```text
purchase_date
delivery_days
estimated_delivery_days
delivery_delay_days
delivered_late
```

## 87. Verify Silver

```sql
SELECT tablename
FROM pg_tables
WHERE schemaname = 'silver'
ORDER BY tablename;
```

Row-count checks:

```sql
SELECT COUNT(*) FROM silver.customers;
SELECT COUNT(*) FROM silver.orders;
SELECT COUNT(*) FROM silver.order_items;
SELECT COUNT(*) FROM silver.products;
SELECT COUNT(*) FROM silver.geolocation_postcode;
```

Derived-field inspection:

```sql
SELECT
    order_id,
    order_status,
    order_purchase_timestamp,
    delivery_days,
    estimated_delivery_days,
    delivery_delay_days,
    delivered_late
FROM silver.orders
LIMIT 20;
```

---

# Workshop 6 — Build Gold Warehouse

## 88. Run Gold builder

```bash
docker compose exec python python \
/workspace/ecommerce_etl/06_build_gold_etl.py
```

Purpose: create a dimensional warehouse for reporting and analytics.

## 89. Dimensions

```text
dim_customer
dim_product
dim_seller
dim_date
```

## 90. Facts

```text
fact_order_item
fact_order_payment
fact_order_review
```

## 91. Surrogate keys

Each dimension receives a warehouse-generated key.

Why:

- stable warehouse identity;
- independence from source IDs;
- simpler integration of multiple sources;
- reliable joins even when source keys differ/change.

Conceptually:

```text
Source IDs:
POS       C001
Digital   95432
Grooming  G87

        |
        v
Warehouse / Master key = 1001
```

## 92. Supporting scripts

The package also contains:

```text
07_validate_warehouse.py
08_run_analytics.py
```

The intended sequence is therefore:

```text
Build -> Validate -> Analyse
```

---

# Workshop 7 — Complex Data Types

## 93. Data categories

The workshop distinguishes:

```text
Structured
Semi-Structured
Unstructured
```

and performs practical work with JSON/JSONB and XML.

---

# Workshop 7 — JSONB Storage

## 94. Create JSONB table

```sql
DROP SCHEMA IF EXISTS lab_6 CASCADE;
CREATE SCHEMA IF NOT EXISTS lab_6;

CREATE TABLE lab_6.customer_profiles (
    profile_id SERIAL PRIMARY KEY,
    customer_data JSONB
);
```

Different rows can contain different document shapes.

Example:

```json
{
  "customer_id": 1,
  "name": "Alice",
  "city": "Sydney",
  "preferences": {
    "newsletter": true,
    "language": "English"
  }
}
```

Another row may contain email/interests instead.

Purpose: demonstrate flexible schema handling inside PostgreSQL.

---

# Workshop 7 — Query JSON

## 95. Extract text value

```sql
SELECT
    customer_data->>'name'
FROM lab_6.customer_profiles;
```

`->>` returns a SQL text value.

## 96. Extract nested value

```sql
SELECT
    customer_data->'preferences'->>'language'
FROM lab_6.customer_profiles;
```

Rule:

- `->` returns JSON/JSONB and allows further JSON navigation.
- `->>` returns the value as SQL text.

---

# Workshop 7 — Relational to Nested JSON

## 97. Start from relational tables

```text
customers_json
orders_json
```

Relationship:

```text
Customer 1 ---- N Orders
```

## 98. Nest child rows into JSON

```sql
SELECT
    c.customer_id,
    c.customer_name,
    c.city,
    json_agg(
        json_build_object(
            'order_id', o.order_id,
            'order_date', o.order_date,
            'total_amount', o.total_amount
        )
    ) AS orders
FROM lab_6.customers_json c
LEFT JOIN lab_6.orders_json o
    ON c.customer_id = o.customer_id
GROUP BY
    c.customer_id,
    c.customer_name,
    c.city;
```

Transformation:

```text
Relational:
Customers + Orders

        |
        v

Document:
Customer
 |
 +-- Order 1
 +-- Order 2
```

Nested JSON is convenient for APIs and exchange.

---

# Workshop 7 — Store Nested Documents

## 99. Create document table

```sql
CREATE TABLE lab_6.customer_documents (
    customer_doc JSONB
);
```

The workshop uses:

```text
jsonb_build_object()
jsonb_agg()
```

to construct and persist full nested customer documents.

---

# Workshop 7 — Unnest / Flatten JSON

## 100. Expand an array

```sql
SELECT
    customer_doc->>'customer_name' AS customer_name,
    jsonb_array_elements(
        customer_doc->'orders'
    ) AS order_info
FROM lab_6.customer_documents;
```

Each JSON array element becomes a relational row.

This is commonly called:

```text
JSON shredding
JSON flattening
unnesting
```

## 101. Fully flatten attributes

```sql
SELECT
    customer_doc->>'customer_name' AS customer_name,
    order_entry->>'order_id' AS order_id,
    order_entry->>'order_date' AS order_date,
    order_entry->>'total_amount' AS total_amount
FROM lab_6.customer_documents,
jsonb_array_elements(
    customer_doc->'orders'
) AS order_entry;
```

Result:

```text
Customer | Order ID | Date | Amount
```

Main lesson:

- nested representations are useful for API/data exchange;
- flattened rows are useful for SQL analytics/reporting.

---

# Workshop 7 — XML

## 102. Create XML table

```sql
CREATE TABLE lab_6.product_xml (
    id SERIAL PRIMARY KEY,
    product_details XML
);
```

## 103. Insert XML document

```xml
<Product>
    <ProductID>100</ProductID>
    <Name>Laptop</Name>
    <Category>Electronics</Category>
</Product>
```

## 104. Useful XML functions

| Function | Purpose |
|---|---|
| `XMLPARSE()` | Convert text to XML |
| `XMLSERIALIZE()` | Convert XML to text |
| `XMLELEMENT()` | Create XML element |
| `XMLFOREST()` | Create multiple XML elements |
| `XMLATTRIBUTES()` | Add XML attributes |
| `XMLAGG()` | Aggregate rows into XML |
| `XMLCONCAT()` | Combine XML fragments |
| `XPATH()` | Extract values using XPath |
| `XMLEXISTS()` | Check whether XPath exists |
| `IS DOCUMENT` | Validate XML document structure |

---

# Cross-Workshop Engineering Pattern

The workshops collectively teach this repeatable project process:

```text
1. Establish a reproducible environment
   Docker / Python / PostgreSQL

2. Define source systems
   CSV / DB / API

3. Preserve raw input
   RAW or BRONZE

4. Profile data
   nulls / duplicates / formats / keys

5. Clean and standardise
   CLEANSED or SILVER

6. Enforce trusted-layer constraints
   PK / FK / correct data types

7. Integrate entities
   joins / matching / relationship logic

8. Build business/analytical representation
   CURATED or GOLD

9. Create dimensions/facts/views
   star schema / serving layer

10. Add audit and validation
    row counts / execution status / integrity checks

11. Add specialised models only when they solve a problem
    Neo4j / JSON / XML

12. Optimise after correctness
    indexes / partitioning / cache / query plans
```

---



# Most Reusable Workshop Ideas

| Workshop | Most reusable project idea |
|---|---|
| Workshop 1 | Reproducible Docker + Python + PostgreSQL environment |
| Workshop 2 | RAW → CLEANSED → CURATED pipeline |
| Workshop 3 | Data-type sizing, indexing, partitioning, join-cost awareness |
| Workshop 4 | `EXPLAIN`, `EXPLAIN ANALYZE`, statistics, query optimisation |
| Workshop 5 | Neo4j construction, constraints, relationships, traversal |
| Workshop 6 | Full ETL, Bronze/Silver/Gold, audit, dimensional warehouse |
| Workshop 7 | JSON/XML ingestion, nesting, flattening, semi-structured data |

For a multi-source integration project, **Workshop 2 and Workshop 6 are the core implementation references**. Workshops 3, 4, 5, and 7 should be added when they solve a specific technical requirement rather than copied mechanically.
