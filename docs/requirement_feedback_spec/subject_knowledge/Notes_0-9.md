# Advanced Database Notes

# Module 1 — Introduction to Advanced Database Systems

## 1. Information, actors, and interactions

The course treats information as something produced, observed, exchanged, processed, and used through interactions among actors.

A useful conceptual chain is:

**Actors → Interactions → Information → Decisions / Actions → Outcomes / Impacts**

Actors can have roles, goals, and responsibilities. Interactions occur through interfaces, processes, lifecycles, and value chains. These interactions generate or consume information.

The lecture's information lens distinguishes several broad generic information types, including:

- **Organism** — people, organisations, animals, citizens, customers, managers, etc.
- **Place** — country, state, suburb, road, building, room, etc.
- **Time** — date and time.
- **Thing** — product, service, material, device, vehicle, etc.
- **Event** — sale, purchase, request, response, learning event, etc.
- **Mechanism** — sell, buy, share, drive, and similar actions/processes.
- **State** — initiated, in progress, complete, current, historical, future, etc.
- **Intuition** — emotion, feeling, belief, desire, intention.
- **Consequence** — result, value, benefit, liability, responsibility.

These categories help identify what information must be represented in a database or broader information system.

## 2. Data and data elements

A **data element** is a unit of information, such as an attribute or specific piece of data.

Examples:

- customer name;
- product ID;
- order date;
- transaction amount;
- postcode;
- pet breed.

Data elements become useful only when their meaning, context, structure, quality, and intended use are understood.

## 3. Data classification and protection

The module presents a progression based on access and sensitivity:

**Closed data → Internal data → Shared data → Open data**

Associated examples include:

- secret data;
- private data;
- protected data;
- public data.

Protection mechanisms include:

- **encryption** — transforms data so that unauthorised parties cannot read it;
- **tokenisation** — replaces sensitive values with substitute tokens;
- **data masking** — hides or obfuscates sensitive data while preserving usability for selected purposes.

## 4. The five major data characteristics

### 4.1 Variety

Data can be:

- **structured** — entities and attributes represented in a defined schema;
- **semi-structured** — JSON, XML, email, and similar formats with partial or flexible structure;
- **unstructured** — images, audio, video, free text, etc.

### 4.2 Value

Data can create many kinds of value. The lecture groups examples into areas such as:

- business value — cost, revenue, customer satisfaction, productivity, quality, risk, resilience;
- economic value — employment, inflation, income, interest, exchange rate;
- social value — welfare, health, safety, connectivity, equal opportunity, culture, religion;
- political value — policy, transparency, trust;
- legal value — regulation and law;
- environmental value — climate, weather, sustainability;
- psychological value — intention, desire, feeling, emotion.

The key principle is that data is valuable when it supports decisions, actions, services, governance, or other outcomes.

### 4.3 Veracity

Veracity concerns whether data can be trusted. The lecture highlights:

- data quality;
- origin/provenance;
- data hygiene.

### 4.4 Velocity

Velocity concerns how quickly data is generated, moved, and processed. Common modes are:

- real time;
- near real time;
- batch.

### 4.5 Volume

Volume concerns the amount of data. The course illustrates storage scale from bits and bytes through KB, MB, GB, TB, PB, EB, ZB, YB and beyond.

The general relationship across the course is:

**larger data volumes → greater storage requirements → more I/O and compute pressure → stronger need for efficient architecture, indexing, partitioning, caching, and analytical design.**

## 5. Data models

The module introduces several model families:

- network data model;
- hierarchical data model;
- entity-relationship model;
- object-oriented model;
- graph data model;
- dimensional data model;
- Data Vault model.

These can be described at three abstraction levels:

### Conceptual model

High-level business view of entities, relationships, and major concepts. It focuses on **what the business needs to represent**, not implementation details.

### Logical model

Adds more structure, such as attributes, keys, cardinalities, and relationships, but remains relatively technology-independent.

### Physical model

Describes the implementation in a specific platform: tables, columns, data types, indexes, partitions, constraints, physical storage decisions, etc.

## 6. Data lifecycle and value chain

Data should be viewed as something that moves through a lifecycle rather than as a static asset. Typical stages include creation/acquisition, storage, processing, use, sharing, maintenance, archiving, and disposal.

A data value chain describes how raw data is transformed through processing and analysis into information that supports decisions and outcomes.

## 7. Database systems

A **database system** stores and organises data with defined formats or structures and is managed through a DBMS.

A typical database system contains:

- business data such as customer, sales, or student data;
- **metadata** describing meaning and context;
- users and roles such as administrators, owners, analysts, and end users;
- applications and tools that access and process the data;
- a data platform and infrastructure providing storage, compute, security, and management capabilities.

## 8. Data requirements

**Data requirements** define how data must be:

- captured;
- stored;
- organised;
- validated;
- processed;
- retrieved;
- used.

Good data requirements connect a business problem to the database design and architecture.

## 9. Database-system options

The module distinguishes three broad system roles.

| Aspect | Operational System | Data Warehouse System | Consumption System |
|---|---|---|---|
| Main purpose | Transaction processing (OLTP) | Aggregation, integration, mapping | Analytics, BI, AI/ML (OLAP) |
| Typical scope | Business unit or function | Enterprise or ecosystem | Domain, subject area, decision-driven use |
| Main features | Data capture and CRUD | Integration and lineage | Intelligence, reporting, analytics |
| Typical models | Relational, object-oriented, graph | Relational, dimensional, Data Vault, enterprise knowledge graph | AI/ML models, dashboards, reports, visualisation |
| Example technologies from the lecture | SQL Server, PostgreSQL, MongoDB, Neo4j | Redshift, S3/Data Lake, Azure Data Lake, Cloudera, Databricks Lakehouse, Snowflake | Athena, Power BI, Tableau, Pinecone |

### Core distinction

- **Operational systems** answer: *What is happening now?*
- **Warehouse/analytical systems** answer: *What happened across sources and over time?*
- **Consumption systems** turn integrated data into reports, models, decisions, or products.

---

# Module 2 — Database System Architecture & Platform

## 1. Traditional vs modern data architecture

### Traditional architecture

A traditional architecture commonly centres on:

**Applications / operational sources → data ingestion → data warehouse → reporting and analytics**

Metadata and master data provide shared context across the architecture.

### Modern architecture

The modern view separates the system into layers:

**Data Sources → Data Ingestion Layer → Storage Layer → Processing & Compute Layer → Analytics & AI Layer**

This layered approach separates responsibilities and makes the platform easier to scale, evolve, govern, and optimise.

## 2. Data sources

A **data source** is the origin where data is generated, collected, or stored before entering the data platform.

### Common source types

- operational systems — transaction databases, ERP, CRM;
- external sources — APIs, third-party datasets, web data;
- user-generated sources — mobile apps, sensors, logs;
- files and streams — CSV, JSON, Kafka streams.

### Common characteristics

Sources may be:

- structured, semi-structured, or unstructured;
- inconsistent in quality and format;
- batch-based or real time.

## 3. Data ingestion layer

The **data ingestion layer** moves data from sources into the platform for storage and processing.

Core functions:

- extraction;
- validation and filtering;
- basic transformation;
- routing.

Two major ingestion modes:

- **batch ingestion** — e.g. daily ETL jobs;
- **streaming ingestion** — continuous or real-time pipelines.

Typical tools mentioned in the module:

- Python scripts such as `pandas` and PostgreSQL connectors;
- ETL/orchestration tools such as Airflow and Talend;
- streaming systems such as Kafka and Spark Streaming.

Example pattern:

```python
import pandas as pd

df = pd.read_csv("orders.csv")
df.to_sql("raw_orders", conn)
```

## 4. Storage layer

The **storage layer** persists data for operational and analytical use.

Examples:

- relational databases — PostgreSQL, MySQL;
- analytical storage — Snowflake, BigQuery;
- data lakes/object storage — S3, Azure storage.

A layered schema design can separate raw, intermediate, and warehouse data:

```sql
CREATE SCHEMA raw;
CREATE SCHEMA staging;
CREATE SCHEMA warehouse;
```

## 5. Processing and compute layer

The **processing and compute layer** transforms data into usable forms.

Processing styles:

- ETL;
- ELT;
- streaming processing.

Typical operations:

- cleaning;
- joins;
- aggregation;
- feature engineering.

Compute engines can include:

- SQL engines such as PostgreSQL or DuckDB;
- distributed systems such as Spark.

Example:

```sql
CREATE TABLE staging.orders_enriched AS
SELECT
    o.order_id,
    c.customer_name,
    p.product_name,
    (o.quantity * p.price) AS revenue
FROM raw.orders o
JOIN raw.customers c USING (customer_id)
JOIN raw.products p USING (product_id);
```

## 6. Analytics layer

The **analytics layer** supports querying, reporting, modelling, and decision-making.

Typical outputs:

- dashboards;
- reports;
- machine-learning features;
- data products.

The lecture distinguishes:

- **descriptive analytics** — what happened?
- **diagnostic analytics** — why did it happen?
- **predictive analytics** — what is likely to happen?

Example analytical query:

```sql
SELECT category, SUM(revenue)
FROM warehouse.fact_sales
GROUP BY category;
```

## 7. Architecture patterns

### 7.1 Application / database pattern

An application is directly backed by a database and uses the database to persist application data. This pattern is suited to application-specific operational workloads.

### 7.2 Data warehouse pattern

Data from multiple source systems is extracted, transformed, and loaded into a central warehouse for integration, reporting, and analysis.

A **data mart** is a smaller subset focused on one functional area or group of users.

Example idea from the lecture: customer data from multiple application databases can be integrated in a warehouse and combined with sales, complaints, service, and support information to create a more complete view of the customer.

### 7.3 Data lake pattern

A **data lake** adds storage for semi-structured and unstructured data and supports advanced analytics and machine learning.

It may coexist with a data warehouse rather than replace it.

### 7.4 Data lakehouse pattern

A **lakehouse** combines:

- the scalability and flexibility of a data lake;
- the reliability, performance, and governance associated with a data warehouse.

The goal is to support raw/flexible data and structured analytics within a more unified environment.

### 7.5 Data fabric pattern

A **data fabric** is an architectural approach that creates a unified and intelligent management layer across distributed:

- data sources;
- clouds;
- applications;
- organisational boundaries.

Its goal is governed, secure, seamless access to data regardless of where the data physically resides.

### 7.6 Data product pattern

The pattern treats data as a consumable product rather than only as internal storage. Data is curated, governed, described through semantic/context layers, and delivered to consumers through a defined product interface or service.

### 7.7 Data exchange pattern

A data exchange connects:

**information providers → exchange/coordinator → information consumers**

The exchange coordinates access, governance, interoperability, and controlled sharing across organisational boundaries.

### 7.8 Data satellite pattern

The Data Satellite pattern addresses challenges in complex digital ecosystems, particularly:

- acquiring the right data in real time or non-real time;
- believability, consistency, and quality;
- governance, observability, and provenance;
- toxic or unusable data;
- dark data that has not been used;
- siloed and duplicated data.

## 8. Architecture reasoning

When analysing a database architecture, trace the full path:

**Where does the data originate? → How is it ingested? → Where is it persisted? → How is it transformed? → How is it consumed? → How is it governed?**

That sequence is the bridge between business requirements and technical design.

---

# Module 3 — Data Storage & Compute

## 1. Physical storage hierarchy

The module presents a storage hierarchy in which faster storage is generally smaller and more expensive per unit, while slower storage is generally larger and cheaper.

| Level | Example | Approximate access time shown in slides | General role |
|---|---|---:|---|
| Internal | Registers | ~1 ns | Immediate CPU state |
| Internal | Cache memory / SRAM | ~1–5 ns | Very fast temporary access |
| Primary | Main memory / DRAM | ~60–100 ns | Active working data |
| Secondary | USB / flash memory | ~20–100 µs | Persistent storage |
| Secondary | Magnetic disk | ~5–10 ms | Persistent high-capacity storage |
| Tertiary | Magnetic tape | ~10–100 s or more | Very large archival storage |

### Why tape is tertiary storage

Tape is typically not directly used for normal random-access database operations. Access usually involves locating and loading the required part of sequential media, so latency is very high. Its strengths are capacity and archival cost, not interactive access speed.

## 2. Direct, network, and cloud storage

- **Direct-attached disks** connect directly to a computer system.
- **SAN (Storage Area Network)** connects block storage to multiple servers over a high-speed network.
- **NAS (Network Attached Storage)** provides a networked file-system interface rather than a raw disk/block interface.
- **Cloud storage** provides managed online storage without the organisation operating its own local storage, SAN, or NAS infrastructure.

## 3. Database storage structure

A database is physically represented through a hierarchy such as:

**Database → Files → Records → Fields**

One simplified organisation assumes:

- fixed-size records;
- each record is smaller than a disk block;
- one file contains one record type;
- different relations use different files.

Variable-length records require more flexible layouts.

## 4. Fixed-length records

If every record has size `n`, record `i` can be placed starting at:

`n × (i − 1)`

This makes addressing simple, but records should generally be arranged so they do not cross block boundaries unnecessarily.

Example fixed-size attributes:

```sql
CREATE TABLE fixed_length_example (
    id INT,
    code CHAR(10),
    flag BOOLEAN
);
```

### Deleting fixed-length records

Possible approaches include:

- shift following records to fill the gap;
- move the final record into the deleted position;
- do not move records; instead maintain a **free list** of reusable positions.

## 5. Variable-length records

Variable-length records arise when:

- different record types are stored in one file;
- fields such as `VARCHAR` or `TEXT` have varying lengths;
- repeating fields are allowed.

A common representation stores:

- fixed-size metadata describing the **offset** and **length** of variable fields;
- actual variable data after fixed-length attributes;
- a **null bitmap** to indicate null values.

Example:

```sql
CREATE TABLE variable_length_example (
    id INT,
    description TEXT,
    notes VARCHAR(255)
);
```

## 6. Large objects

Large objects such as BLOBs or CLOBs may exceed a normal page/record size.

Possible strategies:

- store them in the external file system;
- let the DBMS manage them as files;
- split them into pieces and store those pieces separately.

PostgreSQL uses mechanisms such as **TOAST** for oversized values.

## 7. File organisation

### Heap organisation

A record can be placed anywhere with free space.

Good for simple insertion; no inherent key order.

### Sequential organisation

Records are stored in search-key order.

Useful when an application frequently scans the file sequentially.

### Multitable clustering

Records from multiple relations can be stored together so related records are physically close.

Benefit: reduce I/O for common joins.

Trade-off: a layout that is good for joint access can be worse for queries that access only one relation.

### B+ tree file organisation

Maintains ordered access while still supporting inserts and deletes.

### Hash organisation

A hash function maps search-key values to buckets/blocks.

Best suited to exact-match access rather than ordered range access.

## 8. Partitioning

**Table partitioning** splits a relation into smaller physical partitions.

Example use case:

- `transaction_2024`
- `transaction_2025`

If a query filters on the partitioning attribute, the DBMS may read only the relevant partition. This is **partition pruning**.

Benefits:

- less unnecessary scanning;
- lower management cost for some operations;
- different partitions can be placed on different storage devices.

Example:

```sql
CREATE TABLE sales (
    id SERIAL,
    sale_date DATE,
    amount NUMERIC
) PARTITION BY RANGE (sale_date);

CREATE TABLE sales_2024 PARTITION OF sales
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

CREATE TABLE sales_2025 PARTITION OF sales
FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
```

## 9. Row-oriented vs column-oriented storage

### Row-oriented representation

Stores all attributes of one tuple together.

Best suited to transaction processing where a query often reads or modifies complete records.

### Column-oriented representation

Stores each attribute separately.

Benefits:

- less I/O when only a subset of columns is needed;
- better CPU cache utilisation;
- better compression;
- vectorised processing on modern CPUs.

Costs:

- tuple reconstruction;
- update/deletion complexity;
- decompression overhead.

General course distinction:

- **row stores → operational / transaction workloads**;
- **column stores → decision support / analytical workloads**.

Some systems combine both and are called hybrid row/column stores.

### Columnar file formats

- ORC
- Parquet

These are widely used in big-data environments.

DuckDB is used in the module as an example of a columnar analytical database.

## 10. Main-memory database storage

Main-memory databases can keep records directly in memory and may avoid a traditional disk-oriented buffer-management path.

Columnar layouts can also be used in memory for analytics, where compression reduces memory consumption.

## 11. Indexing

An **index** is an additional access path containing searchable key values in a structure that helps the DBMS locate relevant rows without examining every row.

Analogy:

**book index → topic → page**

**database index → search key → record location**

Indexes are normally much smaller than the underlying table.

## 12. Evaluating an index

No index structure is universally best. Evaluate it using:

- supported access types — equality, range, ordering;
- access time;
- insertion time;
- deletion time;
- storage overhead.

## 13. Ordered vs hash indexes

### Ordered index

- keys stored in sorted order;
- supports equality lookups;
- supports range queries;
- useful when results are processed in key order.

### Hash index

- hash function maps keys to buckets;
- good for exact-match lookup;
- poor for ordered range queries.

## 14. Dense vs sparse indexes

### Dense index

- one index entry for every search-key value;
- can point directly to matching records;
- faster direct lookup;
- larger and more expensive to maintain.

### Sparse index

- index entries only for selected search-key values;
- underlying file must be ordered by the search key;
- smaller and cheaper to maintain;
- may require scanning within a local range after finding the nearest index entry.

---

# Module 4 — Caching & Query Performance

## 1. Why caching matters

A **cache** is a high-speed storage layer used to serve frequently accessed data more quickly than slower primary database storage.

Main benefits in the module:

- database performance;
- database availability.

Modern processors use multiple cache levels. A cache line is typically around 64 bytes in the course example.

## 2. Caching inside a database system

A typical database server has multiple processes accessing shared memory.

Shared memory can include:

- buffer pool;
- lock table;
- log buffer;
- cached query plans.

A cached query plan may be reused when the same or compatible query is submitted again.

Database server processes receive queries/transactions, execute them, and return results. Processes may be multithreaded, allowing concurrent query execution.

## 3. PostgreSQL cache statistics

The lecture uses `pg_stat_database` to compare:

- blocks served from cache (`blks_hit`);
- blocks read from storage (`blks_read`).

Conceptually:

`cache hit ratio = cache hits / (cache hits + disk reads)`

A low ratio suggests a more disk-heavy workload.

## 4. Cache coherence

A distributed or multi-cache system can contain stale copies of data.

**Cache coherence** concerns keeping cached values consistent enough with the authoritative memory/database state.

The lecture distinguishes:

- strong consistency;
- weak consistency.

With weak consistency, additional mechanisms may be needed to ensure a processor sees current values.

### Memory barriers introduced in the lecture

- `sfence` — store barrier;
- `lfence` — load barrier;
- `mfence` — performs both roles.

Locking mechanisms commonly handle the required ordering around lock acquisition and release.

PostgreSQL also uses **MVCC (Multi-Version Concurrency Control)** to manage concurrent access to changing data.

## 5. Relational algebra refresher

Basic operations:

- **Selection** `σ` — choose rows satisfying a condition.
- **Projection** `Π` — choose columns.
- **Cross product** `×` — combine all tuples of two relations.
- **Set difference** `\` — tuples in relation 1 but not relation 2.
- **Union** `∪` — tuples appearing in either relation.

Additional useful operations include:

- intersection;
- join;
- division;
- renaming.

A key property is **closure**: each relational operation produces another relation, so operations can be composed.

## 6. Query-processing pipeline

A query typically passes through three stages.

### 6.1 Parsing and translation

The DBMS:

- checks syntax;
- verifies referenced relations/attributes;
- translates SQL into an internal form, conceptually related to relational algebra.

### 6.2 Optimisation

The optimiser considers logically equivalent plans and selects one with a lower estimated cost.

It uses statistics from the database catalogue, such as:

- number of tuples;
- tuple sizes;
- distinct-value counts;
- number of pages;
- index statistics.

### 6.3 Evaluation

The execution engine runs the chosen physical plan and returns the result.

## 7. Equivalent expressions

For a query such as:

```sql
SELECT salary
FROM instructor
WHERE salary < 75000;
```

Equivalent relational-algebra forms can apply selection and projection in different orders, for example:

`σ_salary<75000(Π_salary(instructor))`

or

`Π_salary(σ_salary<75000(instructor))`

Equivalent logical expressions can have different physical costs.

## 8. Query cost

Major cost sources include:

- disk I/O;
- CPU processing;
- network communication.

Cost can be represented by:

- total response time; or
- total resource consumption.

The lecture presents the conceptual cost model:

`Cost = W × CPUcost + IOcost`

where `W` is a weighting factor.

### CPU cost

Often related to the number of tuples processed.

### I/O cost

Depends on pages/blocks that must be accessed and on table/index layout.

Catalogue statistics may include:

- tuple count;
- page count;
- non-empty page count;
- distinct-key count;
- index-page count;
- high/low key values.

## 9. Cost-based query optimisation

The optimiser generally:

1. generates logically equivalent expressions using equivalence rules;
2. converts these into possible physical plans;
3. estimates costs using catalogue statistics;
4. chooses the cheapest estimated plan.

Important equivalence ideas from the module include:

- selections can often be reordered;
- multiple selections can be cascaded;
- projections can be pushed/reduced;
- joins are commutative;
- joins can be associative;
- a selection over a Cartesian product can become a join when the predicate is a join condition;
- pushing filters/projections closer to the data source can reduce intermediate-result size.

## 10. EXPLAIN and EXPLAIN ANALYZE

`EXPLAIN` displays the plan selected by the optimiser together with estimated costs.

`EXPLAIN ANALYZE` executes the query and reports actual runtime statistics in addition to the estimates.

Example:

```sql
EXPLAIN ANALYZE
SELECT
    c.customer_name,
    SUM(s.amount)
FROM sales_large s
JOIN customers c
  ON s.customer_id = c.customer_id
GROUP BY c.customer_name;
```

In PostgreSQL, a cost shown as `f..l` represents approximately:

- `f` — cost to produce the first tuple;
- `l` — cost to produce the complete result.

### Main performance-analysis habit

When reading a plan, identify:

- the scan type;
- the join strategy;
- rows processed vs rows returned;
- sorting/aggregation steps;
- estimated vs actual rows/cost/time;
- whether indexes are used;
- whether the plan reads unnecessary data.

---

# Module 5 — Data Warehouse, ETL & ELT

## 1. Why data warehousing exists

Operational source systems are usually designed for day-to-day transactions and may store primarily current state.

Organisational analysis often requires:

- data from multiple sources;
- a unified schema;
- historical records;
- aggregated reporting;
- analytical querying;
- predictive modelling and decision support.

## 2. ETL vs ELT

### ETL

**Extract → Transform → Load**

Data is extracted from sources, transformed into the required form, then loaded into the destination.

### ELT

**Extract → Load → Transform**

Raw or lightly processed data is loaded first and transformation occurs inside the target platform.

The choice depends on architecture, platform capability, governance, cost, data volume, latency, and transformation requirements.

## 3. Data warehouse definition

A **data warehouse** is a repository containing data gathered from multiple sources and stored under a unified schema for analytical use.

Benefits:

- simplifies integrated querying;
- supports historical analysis;
- separates decision-support workloads from operational transaction systems.

## 4. Reporting, analysis, and prediction

Data warehouse workloads may support:

- aggregates and summary reports;
- dashboards;
- OLAP;
- statistical analysis;
- large-scale/parallel analytics;
- predictive modelling;
- forecasting and business decisions.

Examples of decision questions:

- what should be stocked?
- how much should be produced?
- which customers should be targeted?
- what trends are emerging?

## 5. Warehouse design considerations

### When and how to gather data

**Source-driven architecture:** source systems send new data to the warehouse, continuously or periodically.

**Destination-driven architecture:** the warehouse periodically requests data from sources.

### Synchronous vs asynchronous replication

Keeping a warehouse exactly synchronised with source systems can be expensive. Analytical systems often tolerate a small delay and use periodic/asynchronous refresh.

### Schema choice

Possible approaches include:

- relational;
- dimensional;
- Data Vault.

### Transformation and cleansing

Examples:

- correct address errors;
- standardise formats;
- merge records from multiple sources;
- remove duplicates.

### Update propagation

Warehouse structures may behave like maintained/materialised views derived from source schemas.

### Summarisation

Raw data can be too large or expensive for repeated interactive analysis. Precomputed totals/subtotals or other aggregates can reduce query cost.

## 6. OLTP vs OLAP

### OLTP — Online Transaction Processing

Designed for high volumes of real-time business transactions.

Typical characteristics:

- current operational state;
- CRUD operations;
- many concurrent users;
- ACID transaction management;
- many small, predefined queries;
- frequent row-level inserts/updates/deletes.

### OLAP — Online Analytical Processing

Designed for exploration and aggregation over large volumes of historical data.

Typical characteristics:

- integrated historical data;
- large scans and aggregations;
- ad-hoc analyst queries;
- fact and dimension tables;
- BI dashboards, reporting, forecasting.

### Comparison

| Property | OLTP | OLAP |
|---|---|---|
| Main question | What is happening now? | What happened, why, and what trends exist? |
| Read pattern | Point lookups | Aggregates over many rows |
| Write pattern | Individual insert/update/delete | Bulk ETL or event streams |
| Main human user | Application end user | Analyst / decision-maker |
| Queries | Many small predefined queries | Fewer complex ad-hoc queries |
| Data | Current state | Historical events |
| Typical scale in lecture | GB–TB | TB–PB |

## 7. Dimensional data warehouse

Dimensional models divide warehouse data into **facts** and **dimensions**.

### Fact table

Stores quantitative information about a business process.

Example attributes:

- item ID;
- store ID;
- customer ID;
- date;
- quantity;
- price or amount.

Fact tables are typically very large.

### Dimension table

Stores descriptive business context, such as:

- customer details;
- product attributes;
- store location;
- date hierarchy.

Dimensions are typically smaller than fact tables.

### Measures vs dimensions

- **measure attributes** can be aggregated, e.g. quantity, revenue, amount;
- **dimension attributes** provide the viewpoints by which measures are grouped, filtered, or interpreted.

## 8. Star and snowflake schemas

### Star schema

A central fact table is linked directly to dimension tables.

Common query pattern:

- join fact to dimensions;
- group by dimension attributes;
- aggregate fact measures.

### Snowflake schema

The module describes snowflake schemas as more complex dimensional structures with multiple levels of dimension tables and potentially multiple fact tables.

Example analytical query:

```sql
SELECT
    c.country,
    SUM(f.amount) AS total_sales
FROM dw.fact_sales f
JOIN dw.dim_customer c
  ON f.customer_id = c.customer_id
GROUP BY c.country;
```

## 9. Data Vault

**Data Vault** is a warehouse methodology designed to integrate, historise, and audit data from multiple sources.

Its core components are:

### Hub

Stores unique business keys representing core business entities.

Typical characteristics:

- business key;
- load date;
- record source;
- stable identity over time.

### Link

Stores relationships between hubs.

Useful for:

- many-to-many relationships;
- tracking how business entities are connected.

### Satellite

Stores descriptive attributes and historical changes associated with hubs or links.

Data Vault emphasises:

- full history;
- auditability;
- lineage;
- governance;
- integration from multiple sources.

## 10. Medallion architecture

A **Medallion Architecture** progressively improves data quality and value through three layers.

### Bronze

- raw ingestion;
- low transformation;
- lower/unknown data quality;
- oriented toward data engineering and traceability.

### Silver

- cleaned;
- validated;
- standardised;
- medium data quality;
- suitable for analysts and data scientists.

### Gold

- business-ready;
- curated or aggregated;
- high quality and high value;
- suitable for BI, executives, and business consumption.

Example progression:

```sql
CREATE SCHEMA bronze;
CREATE SCHEMA silver;
CREATE SCHEMA gold;
```

Bronze may preserve raw strings. Silver converts types, trims values, normalises text, and removes invalid rows. Gold exposes curated business entities or aggregates.

## 11. Choosing between dimensional, Data Vault, and Medallion ideas

These patterns solve different problems and can coexist.

- **Dimensional modelling** optimises analytical consumption and business-friendly querying.
- **Data Vault** emphasises integration, history, auditability, and source lineage.
- **Medallion architecture** emphasises staged improvement in quality and usability through a data pipeline/lakehouse.

---

# Module 6 — Graph & Vector Database

## 1. Why graphs matter

Graph databases are useful when relationships are central to the problem.

The lecture uses investigative-data examples to show that a graph can reveal connections among people, organisations, addresses, communications, and other entities that are difficult to discover by manually joining many tables.

Core impacts highlighted in the lecture include:

- enhanced enterprise AI;
- reduction/elimination of costly joins for highly connected traversal workloads;
- unified data governance and lineage.

## 2. Graph basics

A graph represents a domain using:

- **nodes** — entities;
- **relationships/edges** — connections between entities;
- **properties/attributes** — descriptive values attached to nodes or relationships.

Examples of natural graph-shaped domains:

- social networks;
- communication networks;
- the internet;
- neural networks;
- event graphs;
- disease pathways;
- knowledge graphs.

## 3. Graph database vs relational database

In a relational database, relationships are commonly reconstructed through foreign keys and joins.

In a graph database, relationships are stored as first-class structures.

This makes graph databases particularly suitable when queries repeatedly traverse chains of relationships.

### Runtime intuition

- relational model: relationships are often **computed at query time** through joins;
- graph model: relationships are explicitly represented and can be directly traversed.

This does not mean graph databases are universally faster. Their advantage is strongest when the workload is fundamentally relationship/traversal-heavy.

## 4. Traversal queries

A traversal query follows edges from node to node.

Typical examples from the lecture:

- find all nodes connected to a person named Bill;
- find friends of Bill's friends;
- find friends of Bill's friends who are not directly friends with Bill.

This is a natural fit for graph structures because the query follows stored relationships.

## 5. Machine learning with graphs

The module introduces several graph-ML tasks.

### Node classification

Predict a label/type for a node.

Example: classify social-network nodes into social circles.

### Link prediction

Predict whether two nodes should be connected.

Example: content recommendations.

### Community detection

Find densely connected clusters.

Example: identifying groups or polarisation structures in social networks.

### Graph/node similarity

Measure similarity between nodes or networks.

Example: identify the same person across two social networks.

## 6. LLMs and graphs

The lecture presents a two-way relationship.

### Graphs can support LLMs

Explicit entities and relationships can ground a model in verified or governed facts.

**GraphRAG** can retrieve connected subgraphs, supporting:

- multi-hop retrieval;
- explainability;
- access to current graph data.

### LLMs can support graphs

LLMs can:

- extract entities and relationships from text;
- help bootstrap a knowledge graph;
- translate natural-language requests into graph query languages such as Cypher or SPARQL.

### Challenges

- extraction errors propagate into the graph;
- duplicate entity resolution is difficult;
- large subgraphs can exceed model context windows;
- retrieval must be pruned;
- schema drift, provenance, and governance become increasingly important as the graph grows.

## 7. Knowledge graphs

A **knowledge graph** is a graph-based knowledge base containing facts, relationships, rules, or other knowledge.

The lecture emphasises three properties.

### It is a graph

Nodes represent entities and types; relationships and attributes are first-class elements.

This makes it easier to integrate new datasets and explore information by following links.

### It is semantic

Meaning is encoded for programmatic use through an **ontology** or other semantic schema.

The ontology describes:

- entity types;
- properties;
- relationship meanings;
- constraints or domain structure.

Because semantics are explicit, the system can support reasoning and derive additional information.

### It is alive

Knowledge graphs evolve:

- new data can be added;
- schemas can change;
- domains can expand;
- relationships can be updated as knowledge changes.

## 8. Knowledge-graph applications

The lecture lists uses such as:

- semantic search;
- recommender systems;
- semantic web services;
- question answering/chatbots;
- information extraction;
- data integration.

Knowledge graphs can support analytics and AI by:

- adding identifiers and descriptions across different data modalities;
- improving integration and sense-making;
- improving explainability;
- injecting domain knowledge into machine-learning systems;
- reducing the amount of knowledge that must be learned only from labelled examples.

## 9. Knowledge graphs for data integration

Traditional rows and columns can lose information when unstructured source content does not fit a predefined table schema.

Graph/knowledge-graph approaches are useful when:

- data comes from heterogeneous sources;
- relationships matter;
- schemas evolve;
- semantic meaning must be preserved;
- repeated relational joins become complex.

## 10. Knowledge graph + digital twin networks

A digital twin network mirrors physical/logical systems and their virtual counterparts.

The lecture presents knowledge graphs as a way to enrich digital twins through:

- semantic integration and reasoning;
- schema-grounded modelling;
- human-AI interaction;
- explainability.

## 11. Vector databases

A **vector database** is designed to store, index, and query **vector embeddings**.

Embeddings are numerical representations of items such as:

- words;
- documents;
- images;
- audio.

Items with similar meaning/content are represented by vectors that are close to one another in a multidimensional vector space.

## 12. Vector-database workflow

Typical pipeline:

**Content → Embedding Model → Vector Embedding → Vector Database**

At query time:

**Query → Embedding Model → Query Vector → Similarity Search → Retrieved Results**

The database retrieves vectors close to the query vector according to a similarity/distance measure.

## 13. Embedding models

The lecture uses **Word2Vec** as a classic example.

Its central idea is that words with related meanings can be represented by vectors located close together in embedding space.

Modern embedding models extend the same general principle to sentences, documents, images, audio, behaviour, and multimodal data.

## 14. Vector-database use cases

### Semantic search

Retrieve by meaning rather than exact keyword match.

### RAG for LLMs

Retrieve relevant passages from a private or domain-specific corpus and provide them to the LLM at query time.

### Recommendation

Find items near a user's interest/profile vector.

### Image and multimodal search

Search images/audio/video using embeddings, sometimes with cross-modal text queries.

### Anomaly and fraud detection

Identify vectors far from normal behavioural clusters.

### Deduplication and entity matching

Identify records that refer to the same or similar entity despite different wording.

## 15. Graph database vs knowledge graph vs vector database

| Concept | Main representation | Best at |
|---|---|---|
| Graph database | Nodes + relationships + properties | Relationship traversal and connected data |
| Knowledge graph | Graph + explicit semantics/ontology | Meaning, integration, reasoning, explainable connected knowledge |
| Vector database | High-dimensional embeddings | Similarity and semantic-nearest-neighbour retrieval |

These technologies can be combined. For example, an AI system can use vector search to find semantically related content and a knowledge graph to retrieve explicit multi-hop relationships.

---

# Module 7 — Complex Data Types

## 1. Data variety

The module revisits three broad forms of data:

- **structured** — conventional entities/attributes in defined schemas;
- **semi-structured** — JSON, XML, email;
- **unstructured** — image, voice, video, free text.

A data lake can be integrated into an architecture to support semi-structured and unstructured data for analytics and machine learning.

## 2. Why semi-structured data exists

Relational modelling assumes atomic attributes and relatively stable schemas. Some applications have data that is:

- nested;
- multi-valued;
- highly variable;
- frequently changing;
- exchanged between applications and web services.

For such cases, strict normalisation may be unnecessarily complicated.

Example: storing a set of user interests may be simpler as a multi-valued attribute/document structure than as multiple normalised tables.

JSON and XML are the main semi-structured formats introduced in the module.

## 3. Flexible schema

Two patterns are discussed.

### Wide-column representation

Different tuples can have different attribute sets and new attributes can be added over time.

### Sparse-column representation

The schema contains many possible attributes, but each tuple stores only a subset.

## 4. Multi-valued data types

Examples include:

### Sets / multisets

A field may contain multiple values such as a set of interests.

### Key-value maps

Store pairs such as:

- `(brand, Apple)`
- `(ID, MacBook Air)`
- `(size, 13)`
- `(color, silver)`

Typical conceptual operations:

- `put(key, value)`
- `get(key)`
- `delete(key)`

### Arrays

Useful for scientific and monitoring data.

Example:

`[5, 8, 9, 11]`

can represent regularly sampled values without explicitly storing every `(time, value)` pair.

The module refers to multi-valued attributes as a non-first-normal-form (NFNF) approach and notes that modern database systems commonly support such types.

## 5. Array databases

Array databases provide specialised array support, potentially including:

- compressed array storage;
- array-aware query operations;
- specialised indexing.

Examples listed in the lecture include Oracle GeoRaster, PostGIS, and SciDB.

## 6. Nested data

Hierarchical data is common in applications.

Two major nested representations:

- **JSON — JavaScript Object Notation**;
- **XML — Extensible Markup Language**.

## 7. JSON

JSON is a text-based format widely used for data exchange.

It can contain:

- numbers;
- strings;
- objects;
- arrays;
- nested objects/arrays.

### JSON object

An object is a map of key-value pairs.

Example:

```json
{
  "ID": "2222",
  "name": {
    "firstname": "Albert",
    "lastname": "Einstein"
  },
  "department": "Physics",
  "children": [
    {"firstname": "Hans", "lastname": "Einstein"},
    {"firstname": "Eduard", "lastname": "Einstein"}
  ]
}
```

JSON is widely used in web services and modern application architectures.

### SQL support for JSON

Modern DBMSs may support:

- native JSON data types;
- path expressions to extract nested values;
- functions to generate JSON from relational data;
- JSON aggregation functions.

PostgreSQL-style example:

```sql
INSERT INTO users (data) VALUES
('{"name": "Alice", "age": 30, "city": "Sydney"}');

SELECT
    data->>'name' AS name,
    data->>'city' AS city
FROM users;

SELECT *
FROM users
WHERE data->>'city' = 'Sydney';
```

JSON syntax and functions differ across DBMSs.

The module also notes that JSON can be verbose and that compressed/binary formats such as BSON may be used for more efficient storage.

## 8. XML

XML represents data using tags.

Example:

```xml
<course>
  <course_id>CS-101</course_id>
  <title>Intro. to Computer Science</title>
  <dept_name>Comp. Sci.</dept_name>
  <credits>4</credits>
</course>
```

Characteristics:

- tags are self-describing;
- structures can be hierarchical/nested;
- data can contain repeated nested elements.

### XML querying

The lecture mentions:

- XQuery for nested XML querying;
- SQL extensions for storing, generating, and extracting XML;
- path expressions for nested access.

## 9. Arrays in SQL

Example PostgreSQL-style array table:

```sql
CREATE TABLE students (
    id SERIAL,
    name TEXT,
    grades INT[]
);

INSERT INTO students (name, grades)
VALUES ('Alice', ARRAY[85, 90, 78]);

SELECT name, grades[1] AS first_grade
FROM students;

SELECT name, unnest(grades) AS grade
FROM students;
```

`unnest()` converts array elements into rows.

## 10. Knowledge representation and RDF

Representing knowledge has long been an AI/database problem.

**RDF (Resource Description Framework)** represents facts as triples:

**(subject, predicate, object)**

Examples:

- `(NBA-2019, winner, Raptors)`
- `(Washington-DC, capital-of, USA)`

RDF can represent:

- attributes: `(ID, attribute-name, value)`;
- relationships: `(ID1, relationship-name, ID2)`.

This naturally forms a graph.

## 11. SPARQL

**SPARQL** is a query language for RDF graph data.

It uses triple patterns with variables to match facts and relationships.

The lecture notes support for:

- aggregation;
- optional joins;
- subqueries;
- transitive/path queries.

## 12. N-ary relationships in RDF

Basic RDF triples represent binary relationships. More complex relationships can be represented using:

### Artificial/context entity

Create an intermediate entity and link it to each participant/attribute.

### Quads/context

Add contextual identity to a triple so additional information can be attached to the relationship.

RDF is widely used in knowledge bases such as DBpedia, YAGO, Freebase, and Wikidata. Linked Open Data aims to connect knowledge graphs so queries can span datasets.

## 13. Unstructured textual data and information retrieval

Traditional structured querying assumes explicit schema. Unstructured text instead uses **information retrieval** techniques.

Basic keyword retrieval:

- given query keywords, find documents containing those words.

More advanced systems rank documents by relevance because many documents may match.

## 14. TF-IDF ranking — course-slide formulation

The lecture presents ranking based on how strongly query terms occur in a document.

### Term Frequency

For document `d` and term `t`:

`TF(d,t) = log(1 + n(d,t) / n(d))`

where:

- `n(d,t)` = number of occurrences of term `t` in document `d`;
- `n(d)` = number of terms in document `d`.

### Inverse Document Frequency

The slide uses the simplified form:

`IDF(t) = 1 / n(t)`

### Relevance score

For query-term set `Q`:

`r(d,Q) = Σ[t ∈ Q] TF(d,t) × IDF(t)`

The lecture also notes that retrieval systems may account for word proximity and often ignore stop words.

## 15. Spatial data

A **spatial database** stores spatial-location information and supports spatial indexing and queries.

### Geographic data

Examples:

- road maps;
- land-use maps;
- elevation maps;
- political boundaries;
- land ownership.

May use longitude, latitude, and elevation on a round-Earth coordinate system.

### Geometric data

Examples:

- building designs;
- aircraft designs;
- integrated-circuit layouts.

Usually represented in 2D or 3D Euclidean coordinates such as `(X, Y, Z)`.

## 16. Time-series data

A **time series** is a sequence of observations describing how a system/process changes over time.

Examples:

- financial data;
- weather observations;
- sensor readings;
- user-click logs.

A typical record contains:

- a date/time/timestamp at a defined granularity;
- one or more numerical measures;
- contextual dimensions such as location or stock symbol.

Example:

```sql
CREATE TABLE sensor_data (
    ts TIMESTAMP,
    value NUMERIC
);

INSERT INTO sensor_data VALUES
('2026-01-01 10:00:00', 20.5),
('2026-01-01 10:01:00', 21.0);

SELECT *
FROM sensor_data
WHERE ts BETWEEN '2026-01-01 10:00:00'
             AND '2026-01-01 10:02:00';

SELECT date_trunc('minute', ts), AVG(value)
FROM sensor_data
GROUP BY 1;
```

---

# Cross-Module Concept Map

## 1. From business problem to database architecture

A useful end-to-end reasoning chain across Modules 1–7 is:

**Business requirement**
→ identify actors, interactions, information, and data requirements
→ choose data model(s)
→ identify source systems
→ design ingestion
→ choose storage organisation
→ choose processing/compute strategy
→ optimise physical access with partitioning/indexing/caching
→ integrate/history-manage data in warehouse/lakehouse structures
→ choose analytical/graph/vector/complex-data techniques according to the use case
→ deliver information through analytics, BI, ML, AI, or data products.

## 2. Operational vs analytical design

| Design concern | Operational orientation | Analytical orientation |
|---|---|---|
| Main goal | Fast reliable transactions | Fast large-scale analysis |
| System type | OLTP | OLAP / warehouse |
| Storage orientation | Usually row-oriented | Often column-oriented |
| Query shape | Small point queries | Scans, joins, aggregation |
| Data | Current state | Integrated history |
| Writes | Frequent individual updates | Batch/event loads |
| Optimisation | Keys, indexes, transaction efficiency | Partitioning, columnar storage, aggregation, dimensional models |

## 3. Storage, compute, and query performance are connected

Physical choices affect compute cost.

- larger rows → more pages → more I/O;
- poor layout → unnecessary scans;
- partition pruning → fewer partitions scanned;
- indexes → faster selective access but extra storage/write maintenance;
- cache hits → avoid slower storage reads;
- columnar layouts → reduce I/O for analytical column subsets;
- query optimisation → reduces intermediate rows and expensive operations.

## 4. Data integration pattern choices

| Need | Suitable concept from modules |
|---|---|
| Current application transactions | Operational relational database |
| Enterprise historical analysis | Data warehouse |
| Business-friendly metrics | Dimensional/star model |
| Full integration + history + lineage | Data Vault |
| Raw → clean → business-ready pipeline | Medallion architecture |
| Semi/unstructured large-scale storage | Data lake |
| Warehouse + lake capabilities | Lakehouse |
| Unified access across distributed environments | Data fabric |
| Relationship-heavy traversal | Graph database |
| Explicit semantics and reasoning | Knowledge graph / RDF |
| Semantic similarity | Vector database |
| Flexible/nested application data | JSON/XML/arrays |
| Location-aware queries | Spatial database techniques |
| Sequential observations | Time-series design |

## 5. High-value distinctions to remember

### Data source vs database vs warehouse

- **Data source:** origin of data.
- **Database:** managed system for storing/querying data.
- **Warehouse:** integrated analytical repository combining data from multiple sources, usually with history.

### ETL vs ELT

- **ETL:** transform before loading.
- **ELT:** load first, transform in target platform.

### Row vs column storage

- **Row:** good when whole records are frequently read/written.
- **Column:** good when analytics reads a few columns across many rows.

### Index vs partition

- **Index:** separate search structure that locates records efficiently.
- **Partition:** physically divides a table into subsets so irrelevant subsets can be skipped.

### Cache vs persistent storage

- **Cache:** fast temporary copy for repeated access.
- **Persistent storage:** authoritative durable data storage.

### Star schema vs Data Vault

- **Star/dimensional:** optimised for analytics and business consumption.
- **Data Vault:** optimised for integration, history, auditability, lineage, and change.

### Relational vs graph database

- **Relational:** relationships reconstructed through keys/joins; strong for tabular transactional and analytical workloads.
- **Graph:** relationships stored directly; strong for deep traversal and connected-data problems.

### Graph vs vector database

- **Graph:** explicit relationships.
- **Vector:** numerical similarity.

### Structured vs semi-structured vs unstructured

- **Structured:** predefined schema.
- **Semi-structured:** flexible/self-describing structure such as JSON/XML.
- **Unstructured:** text, image, audio, video without a conventional tabular schema.

---


---

# Module 8 — Transaction Management

## 1. What is a transaction?

A **transaction** is a sequence of SQL statements that is treated as one logical unit of work.

All statements in the transaction are either:

- **committed** together, meaning the changes become permanent; or
- **rolled back** together, meaning the changes are undone.

A transaction can contain both reads and writes. In the lecture framing, transactions are associated with a single session and are not nested.

The core idea is:

**all related operations succeed together or fail together.**

This is especially important when one business process touches multiple rows or tables.

## 2. ACID properties

Most DBMS transaction systems aim to provide the **ACID** properties.

### Atomicity

A transaction either succeeds completely or fails completely.

If one part of a logical operation cannot be completed, the transaction can be rolled back so that partial changes are not left behind.

### Consistency

A transaction should move the database from one valid state to another valid state.

Database rules, constraints, and relationships should remain valid after the transaction completes.

### Isolation

Concurrent transactions should not interfere in a way that produces an invalid result.

The lecture expresses this as the database reaching the same valid state whether transactions execute concurrently or sequentially.

### Durability

Once a transaction is successfully committed, its result should remain even if a later system failure occurs.

A compact memory aid is:

**A — all or nothing  
C — valid state  
I — concurrent transactions behave safely  
D — committed changes survive**

## 3. Implicit and explicit transactions

### Implicit transaction

An **implicit transaction** is automatically started by the DBMS when a qualifying statement is executed, but must still be explicitly completed with `COMMIT` or `ROLLBACK`.

The lecture uses SQL Server syntax:

```sql
SET IMPLICIT_TRANSACTIONS ON;

UPDATE Accounts
SET Balance = Balance - 500
WHERE AccountID = 101;

COMMIT TRANSACTION;

SET IMPLICIT_TRANSACTIONS OFF;
```

The important point is that the DBMS starts the transaction boundary automatically.

### Explicit transaction

An **explicit transaction** has boundaries deliberately defined by the developer.

Typical structure:

```sql
BEGIN TRANSACTION;

UPDATE Accounts
SET Balance = Balance - 500
WHERE AccountID = 101;

UPDATE Accounts
SET Balance = Balance + 500
WHERE AccountID = 202;

COMMIT TRANSACTION;
```

If an error occurs, the transaction can instead be rolled back.

Explicit transactions are useful when several SQL statements must form one logical unit.

## 4. Mixing implicit and explicit transaction control

The lecture advises avoiding confusing combinations of implicit and explicit transaction boundaries.

Although some combinations may be legal, mixing styles makes transaction behaviour harder to reason about.

A cleaner design is to make transaction ownership and transaction boundaries obvious.

## 5. Failure inside a transaction

A transaction may contain several statements and one of them may fail.

Example concept:

```sql
BEGIN TRANSACTION;

INSERT INTO table1(i) VALUES (1);
INSERT INTO table1(i) VALUES ('This is not a valid integer.');
INSERT INTO table1(i) VALUES (2);

COMMIT;
```

The invalid integer statement fails.

The important design question is whether the DBMS/application should continue, abort, or explicitly roll back the unit of work.

This is why error handling and transaction boundaries must be designed together.

## 6. Transaction lifecycle

The lecture identifies several transaction states.

### Active

The transaction is currently executing statements.

### Partially committed

The final statement has succeeded, but the transaction is not yet fully durable.

Changes may still be in memory and not yet permanently written.

### Committed

The transaction has completed successfully and its changes are permanent.

### Failed

An error has been detected and normal execution cannot continue.

### Aborted

Rollback has completed and the database has been restored to the pre-transaction state.

Typical successful path:

**Active → Partially Committed → Committed**

Typical failure path:

**Active → Failed → Aborted**

## 7. Locking mechanisms

A **lock** temporarily restricts access to a data item while a transaction is using it.

Locks are a core mechanism for controlling concurrent access.

### Shared lock (S lock)

A shared lock is associated with reading.

Key properties:

- used for reading data;
- multiple transactions may hold shared locks at the same time;
- prevents incompatible modification while the data is being read.

Conceptually:

```sql
SELECT *
FROM Accounts
WHERE AccountID = 101;
```

### Exclusive lock (X lock)

An exclusive lock is associated with modification.

Key properties:

- used for updating, inserting, or deleting;
- only one transaction can hold the exclusive lock on the relevant resource;
- incompatible operations from other transactions must wait.

Conceptually:

```sql
UPDATE Accounts
SET Balance = Balance - 500
WHERE AccountID = 101;
```

## 8. Lock contention and blocking

If one transaction holds an incompatible lock and another transaction needs the same resource, the second transaction may have to wait.

Example:

- T1 obtains an exclusive lock on Account 101.
- T2 tries to update Account 101.
- T2 waits until T1 commits or rolls back and releases the lock.

This is **blocking**.

Blocking is not automatically an error; it is a normal consequence of concurrency control. The problem becomes more serious when transactions form a circular wait.

## 9. Deadlock

A **deadlock** occurs when two or more transactions wait indefinitely for resources held by each other.

Lecture example:

- T1 locks Account A.
- T2 locks Account B.
- T1 tries to lock Account B and waits.
- T2 tries to lock Account A and waits.

Now:

**T1 waits for T2, while T2 waits for T1.**

This circular dependency is a deadlock.

## 10. How a DBMS handles deadlock

The lecture describes the typical DBMS response:

1. detect the circular dependency;
2. select one transaction as the deadlock victim;
3. roll back that transaction;
4. release its locks;
5. allow the other transaction to continue.

The application may need to retry the rolled-back transaction.

## 11. Deadlock prevention

The lecture recommends several practical strategies.

### Access resources in a consistent order

If every transaction locks resources in the same order, circular waiting can be avoided.

For example:

**always lock Account A before Account B.**

### Keep transactions short

Short transactions hold locks for less time and reduce contention.

### Commit promptly

Do not keep completed work open unnecessarily.

### Avoid user interaction while holding locks

Waiting for user input while a transaction owns locks can keep other transactions blocked for a long time.

## 12. Multi-table operations

A **multi-table operation** is a business process that inserts, updates, or deletes data across multiple related tables.

Why this matters:

- real business processes rarely affect only one table;
- related data is often distributed across multiple entities;
- all related changes should normally succeed or fail together.

Transactions provide the atomic boundary for this type of operation.

## 13. Multi-table inserts

The lecture presents multi-table insert syntax in which one source query can populate multiple target tables.

The intended benefits are:

- one source scan;
- one atomic operation;
- multiple destinations.

Three variants are introduced.

### Unconditional `INSERT ALL`

Every source row is inserted into every specified target table.

```sql
INSERT ALL
    INTO OrderArchive (OrderID, Amount)
        VALUES (OrderID, Amount)
    INTO AuditLog (RecordID, EventType)
        VALUES (OrderID, 'ORDER_LOADED')
SELECT OrderID, Amount
FROM StagingOrders;
```

Use this when every source row must create records in several targets.

### Conditional `INSERT ALL`

A source row is inserted into every target whose `WHEN` condition is true.

```sql
INSERT ALL
    WHEN Amount >= 1000 THEN
        INTO HighValueOrders (OrderID, Amount)
        VALUES (OrderID, Amount)
    WHEN Amount >= 500 THEN
        INTO ReviewOrders (OrderID, Amount)
        VALUES (OrderID, Amount)
SELECT OrderID, Amount
FROM StagingOrders;
```

One source row may go to multiple target tables if several conditions are true.

### Conditional `INSERT FIRST`

Conditions are evaluated in order and the row is inserted only into the first matching target.

```sql
INSERT FIRST
    WHEN Amount >= 1000 THEN
        INTO HighValueOrders (OrderID, Amount)
        VALUES (OrderID, Amount)
    WHEN Amount >= 500 THEN
        INTO MediumValueOrders (OrderID, Amount)
        VALUES (OrderID, Amount)
    ELSE
        INTO StandardOrders (OrderID, Amount)
        VALUES (OrderID, Amount)
SELECT OrderID, Amount
FROM StagingOrders;
```

This behaves like a mutually exclusive `switch/case` path.

## 14. Multi-table inserts in ELT / data warehousing

The lecture connects multi-table inserts with a Medallion-style warehouse loading pattern.

A staging or Bronze table can be scanned once and its rows routed into:

- a main Silver/Gold fact table;
- a high-value-order table;
- a regional table;
- other condition-specific targets.

The intended advantages are:

- no repeated scans of the same source;
- atomic loading;
- reduced risk of partial loads;
- convenient routing of rows to different analytical targets.

---

# Module 9 — Concurrent & Parallel Processing in Operation

> Important source note: the uploaded Module 9 guest lecture is titled **“Concurrent and Parallel Processing in Operation”**, but its actual content is primarily an operational case study of the Australian taxation data ecosystem, data sources, data matching, analytics, and automation. It does not provide a detailed treatment of database parallel-query algorithms or formal concurrency-control protocols.

## 1. Case study: lodging an individual tax return

The module uses the Australian individual tax-return process as an operational data case study.

The tax-return workflow combines:

- taxpayer-provided information;
- employer and payroll data;
- financial data;
- investment information;
- government-held data;
- historical tax records;
- deductions and offsets;
- automated pre-fill;
- matching and analytics.

The case illustrates how a large public-sector organisation integrates many data sources to support a single business process.

## 2. Australian individual tax model in the lecture

The slides describe a progressive individual income-tax model.

Taxable income may include:

- salary and wages;
- business or freelance income;
- investment returns such as interest, dividends, and rent;
- capital gains.

The lecture also identifies common deduction/offset categories such as:

- work-related expenses;
- donations;
- self-education costs;
- investment expenses;
- tax offsets.

The key database point is not the tax calculation itself, but the large amount of heterogeneous information that must be collected, matched, checked, and presented.

## 3. Tax-return lifecycle

The financial year runs from 1 July to 30 June.

Individuals lodge a return to the Australian Taxation Office (ATO). The lecture highlights **pre-filling**, where the ATO already holds or receives data and presents it to the taxpayer for confirmation or adjustment.

After assessment, the taxpayer may:

- receive a refund; or
- owe an additional balance.

This workflow is an example of a data-intensive digital service.

## 4. Digital ecosystem

The lecture describes the tax ecosystem as **connected and complex**.

The ecosystem includes:

- ATO app;
- ATO Online for individuals;
- online services for businesses;
- online services for agents;
- digital service providers;
- APIs;
- data stores;
- advanced analytics platforms;
- self-service tools;
- visualisation tools;
- business glossary;
- data asset register;
- visual lineage;
- descriptive analytics;
- predictive analytics;
- prescriptive AI;
- robotic process automation.

The important architectural idea is that a business service is supported by many interconnected applications, data stores, interfaces, governance assets, and analytical services.

## 5. First-party and third-party data

### First-party data

The lecture describes first-party data as information:

- sourced directly from a client; or
- created internally in organisational systems such as case-management systems.

Example use:

information collected directly to support a client decision or case.

### Third-party data

Third-party data is obtained from external organisations, government agencies, or other authorised providers.

It can be used to:

- pre-fill information;
- cross-check declarations;
- detect discrepancies;
- support compliance processes.

The distinction is important because source, ownership, authority, governance, and permitted use differ.

## 6. Data-management characteristics: the 5 Vs

The tax data landscape is presented through common big-data characteristics.

### Volume

Very large data holdings and transaction counts.

### Velocity

Large numbers of transactions arrive and are processed continuously or daily.

### Variety

The ecosystem includes structured and semi-structured data from many providers and systems.

### Veracity

Data needs to be accurate enough for pre-fill, matching, compliance, and decision making.

### Value

The lecture treats data as a major business asset that supports operational and analytical outcomes.

## 7. Pre-filled tax data

Examples of pre-filled information include:

- interest;
- dividends;
- gifts and donations;
- vehicle expenses;
- other information already reported by third parties.

Data providers can include:

- employers;
- health funds;
- government agencies;
- banks;
- investment organisations.

The ATO can also use:

- data previously submitted through its own apps;
- prior tax returns;
- current account information.

The larger lesson is that **data integration and matching reduce the amount of information a user must manually re-enter**.

## 8. Data matching

The lecture highlights cross-referencing datasets to improve matching and pre-fill.

Data matching is used to connect records from different sources that refer to the same taxpayer, transaction, property, account, or activity.

This relates directly to advanced-database topics such as:

- entity matching;
- master data;
- identity resolution;
- integration quality;
- data lineage;
- governance.

## 9. Common third-party data sources

The lecture lists several important categories.

### Financial institutions

Examples include:

- account balances;
- transactions;
- interest income.

These can be used to verify declarations and detect discrepancies.

### Employers and payroll providers

Examples include:

- salaries;
- wages;
- employee benefits.

These are central to pre-filling employment income.

### Real-estate data

Property sale, purchase, ownership, and price information can support capital-gains and property-related checks.

### Government agencies

Data from other agencies can be cross-checked against tax records.

### Utilities and service providers

These sources can help validate addresses or other activity.

### E-commerce platforms and payment processors

Digital transaction data can help identify sales and business activity.

## 10. Newer data sources

The lecture identifies emerging sources of operational data.

### Digital platforms and e-commerce

Online marketplaces and payment processors create large streams of transaction data.

### Social media and online presence

Online activity may provide additional contextual information.

### Blockchain and cryptocurrency

Blockchain transactions can provide data about digital-asset activities.

### Internet of Things

Connected devices such as smart meters and connected vehicles can generate usage and ownership information.

### AI and machine learning

AI/ML are presented as tools for analysing large datasets, finding patterns, and supporting anomaly or fraud detection.

## 11. How third-party data is used

The lecture gives four major operational uses.

### Matching returns

Compare taxpayer declarations with external reports to identify discrepancies.

### Risk profiling

Use information to identify cases requiring additional review or audit attention.

### Automated compliance checks

Analytics can flag anomalies automatically.

### Enforcement actions

Integrated information can support investigations and legal processes.

From a data-management perspective, this illustrates a pipeline:

**collect → integrate → match → analyse → identify anomaly/risk → support action**

## 12. Main operational issues

The lecture discusses uses such as:

- checking whether spending patterns align with reported income;
- identifying undeclared income;
- checking transaction-related tax obligations;
- analysing cross-border transactions;
- detecting patterns associated with fraud or money laundering.

These examples demonstrate why modern data systems need to handle large-scale integration, matching, analytics, and automated decision support.

## 13. International digital-tax examples

The lecture briefly lists examples of jurisdictions using digital and data-driven tax administration, including:

- Estonia;
- Australia;
- Norway;
- Brazil;
- Netherlands;
- Lithuania;
- Kazakhstan;
- United Kingdom.

The focus is on different combinations of automation, integration, analytics, governance, and AI-supported administration.

## 14. Future direction

The lecture closes with three major directions:

- **AI and machine learning for anomaly detection**;
- **blockchain for secure data sharing**;
- **real-time data validation**.

These point toward more automated, integrated, and continuously operating data ecosystems.


# Compact Revision Checklist

You should be able to explain, without notes:

- the difference between data, information, actors, and interactions;
- the five data characteristics: variety, value, veracity, velocity, volume;
- conceptual vs logical vs physical data models;
- what a data requirement is;
- operational vs warehouse vs consumption systems;
- the modern architecture layers from source to analytics;
- batch vs streaming ingestion;
- warehouse, lake, lakehouse, fabric, data product, exchange, and satellite patterns;
- the physical storage hierarchy and why slower media are used for larger/archival storage;
- fixed-length vs variable-length records;
- heap, sequential, clustering, B+ tree, and hash organisation;
- partitioning and partition pruning;
- row-oriented vs column-oriented storage;
- what an index is and the ordered/hash and dense/sparse distinctions;
- caching, cache hit ratio, cache coherence, and MVCC;
- relational algebra operations;
- parsing → optimisation → evaluation;
- query cost and cost-based optimisation;
- `EXPLAIN` vs `EXPLAIN ANALYZE`;
- ETL vs ELT;
- OLTP vs OLAP;
- fact vs dimension tables;
- star vs snowflake schema;
- Data Vault hubs, links, and satellites;
- Bronze/Silver/Gold in Medallion architecture;
- graph nodes, relationships, traversal, graph ML, and GraphRAG;
- knowledge graph semantics and ontology;
- vector embeddings and similarity search;
- JSON, XML, arrays, and semi-structured data;
- RDF triples and SPARQL;
- the course-slide TF-IDF formulation;
- spatial data and time-series data.
- ACID properties and why transactions are treated as one logical unit;
- implicit vs explicit transactions;
- transaction lifecycle: active, partially committed, committed, failed, aborted;
- shared vs exclusive locks;
- blocking, lock contention, and deadlock;
- deadlock prevention through consistent resource ordering and short transactions;
- unconditional `INSERT ALL`, conditional `INSERT ALL`, and `INSERT FIRST`;
- why multi-table inserts can support atomic ELT routing;
- first-party vs third-party data in the tax-data case study;
- the tax-data ecosystem and its 5 Vs;
- pre-fill, data matching, risk profiling, and automated compliance checks;
- emerging operational data sources such as digital platforms, blockchain, IoT, and AI/ML;
- the Module 9 future directions: anomaly detection, secure data sharing, and real-time validation.

