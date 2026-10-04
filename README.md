# PetHaven Data Solution

Assignment 2 prototype (32113 Advanced Database). PetHaven has five Sydney stores and an online store. The website shows one combined stock number per product, refreshed only when a sync runs, so between syncs customers can put items in their bag that no store can supply. Checkout checks real store stock before payment, so those items are blocked instead of being charged and cancelled. The prototype integrates **three source systems** into **one data warehouse** through an ETL layer, recalculates the website number from the warehouse on demand, and reports staleness, sync corrections and items blocked at checkout.

| Schema | Role | Own codes | Main objects |
| --- | --- | --- | --- |
| `store_ops` | Source 1: store system (tills, store stock, click & collect) | store `101`, barcode `9300601001019` | `store`, `product`, `store_stock`, `sale`/`sale_line`, `reservation` |
| `supply` | Source 2: delivery system | location `NSW-PARRA`, SKU `PF-DOG-ADT-3K`, **cartons**, **UTC** | `location`, `item`, `delivery`/`delivery_line` |
| `online` | Source 3: online store | collection point `CP-PARRAMATTA`, `WEB-10001` | `product`, `online_stock` (website number), `collection_point`, `web_order` |
| `etl` | ETL layer | – | staging tables, `product_xref`/`store_xref` (approved code mappings), `v_transform`, `run_etl`, `etl_run`, `v_data_quality` |
| `dw` | Integrated data warehouse | `S01`, `P001` | `dim_product`, `dim_store`, `dim_date`, `fact_stock_event`, `run_sync`, `sync_run`/`sync_change`, 8 report views |

How it behaves:

- **In-store sale / delivery / collection / cancellation**: the store's stock changes immediately; the website number waits for the next sync.
- **Online shopping**: items go into a **bag** up to the (possibly stale) website number; nothing is held and bags never expire. The customer is offered every store that holds at least one bag item (fewest transfers first) and **chooses** where to collect. At **checkout, before payment**, real store stock is checked and locked, so whoever checks out first gets it. If any item can't be supplied by a single store, checkout is **blocked**: nothing charged, nothing held, and the customer removes it and tries again. Otherwise the order is **paid**, each item is held where it was found, items from other stores are **transferred** to the chosen store (dispatch → in transit → receive), and the website number drops at once. Orders not collected within 3 days are cancelled by the overdue job.
- **ETL**: every source record is captured into staging in its source format, mapped to warehouse codes through approved cross-references, converted (cartons → units, UTC → Sydney date), validated and loaded into `dw.fact_stock_event` in the same transaction. Records with unmapped codes are rejected with a reason and load once the mapping is approved.
- **Sync** (`SELECT dw.run_sync();`): processes all events since the last sync, recalculates store totals and website numbers, publishes them, logs before/after and reconciles the warehouse with the stores.

Documentation:

- Business case and rules: [00_req_feedback/Assignment2_Spec.md](00_req_feedback/Assignment2_Spec.md)
- Solution design (architecture, conceptual/logical models, ETL, rationale, trade-offs): [docs/Architecture_and_Data_Model.md](docs/Architecture_and_Data_Model.md)
- Rule → SQL → check mapping: [docs/traceability.md](docs/traceability.md)
- Demonstration script and Q&A: [docs/demo_runbook.md](docs/demo_runbook.md)
- Verification results and limitations: [docs/implementation_notes.md](docs/implementation_notes.md)

## Runs in the provided Lab Environment

`docker-compose.yml`, `python/Dockerfile` and `python/requirements.txt` are the course lab files, unchanged. They provide:

- PostgreSQL 15 (`postgres:5432`, user `student`, password `student`);
- a Python 3.11 container;
- CloudBeaver at <http://localhost:8978>.

The lab's Neo4j and ClickHouse containers also start, but the prototype does not use them. All project code is in `workspace/`, which the compose file mounts as `/workspace`.

## How to run the project

You need **Docker Desktop** and **Git**. Nothing else needs installing: Python, PostgreSQL and all libraries run inside the lab containers.

Run every command from the **repository root** (the folder that contains `docker-compose.yml`). On Windows, use **PowerShell** or **Command Prompt**. In Git Bash, see [Troubleshooting](#troubleshooting).

### Step 1: Get the code (once)

```bash
git clone https://github.com/Alfredd43/Warehousing-model.git
```

```bash
cd Warehousing-model
```

### Step 2: Start Docker Desktop

Open Docker Desktop and wait until it says the engine is running. Every `docker` command below fails while Docker Desktop is closed.

If you have another copy of the course lab (for example from the workshops), stop it first. Run this in **that lab's folder**, without `-v`:

```bash
docker compose down
```

Both copies use the same container names (`student-postgres`, ...), so only one can run at a time. The other lab's data stays in its own `data/` folder; `docker compose up -d` in that folder brings it back later.

### Step 3: Start the Lab Environment

```bash
docker compose up -d
```

- **First time:** this downloads the database images and builds the Python container. It needs internet access and can take several minutes.
- **After that:** it starts in seconds.

Check that all five containers are `Up`:

```bash
docker compose ps
```

The first time PostgreSQL starts, it needs about 20–30 seconds to initialise. Wait that long before Step 4, or you may see `Connection refused`.

### Step 4: Build the database (one command)

```bash
docker compose exec python python /workspace/scripts/build.py
```

This recreates the database `pethaven_demo`, creates the five schemas, loads the reference data and a week of sample trading through the source systems (so it all passes through the ETL), and runs two syncs, the last at build time. It ends with a summary: 155 source records staged, 146 stock events loaded, 0 rejected, 0 pending, 0 not reconciled.

Safe to rerun at any time. Only `pethaven_demo` and `pethaven_check` are ever dropped; the lab's own `lab` database is never touched.

### Step 5: Run the demo

**In CloudBeaver** (easiest): open <http://localhost:8978>, add a PostgreSQL connection (host `postgres`, port `5432`, database **`pethaven_demo`**, user/password `student`/`student`), then open [workspace/demo/cloudbeaver_demo.sql](workspace/demo/cloudbeaver_demo.sql) and run it one statement at a time. Reconnect after every rebuild.

**In the terminal**: every command starts with `docker compose exec python python /workspace/scripts/demo.py`. Stores and products can be given as warehouse codes (`S01`, `P001`); the script prints each system's own code.

| Command | What it does |
| --- | --- |
| `sale S01 P003 2 P005 1` | Till sale (one receipt, any number of items) |
| `delivery S03 P001 5` | Supplier delivery, in cartons |
| `order 2026 P009 1 P018 1 [--pickup S02]` | New bag from a customer postcode: shows pickup options, then checks out (real stock checked before payment) |
| `options 10` | Pickup options for bag 10 |
| `remove 10 P013` / `checkout 10 [--pickup S02]` | After a blocked checkout: remove an item from bag 10 / check out again |
| `cancel-overdue` | Cancel click-and-collect orders not collected within 3 days |
| `dispatch 6` / `receive 6` | Send order 6's lines held at other stores to its pickup store / book them in there |
| `collect 6` / `cancel 6` | Customer collects / cancels online order 6 |
| `online` | Website number vs real stock per product |
| `sync` | **Run sync now**: stale "before", sync log, every number that changed |
| `etl` | Run one ETL pass by hand; show the latest ETL runs |
| `approve STORE 9300601001194 P019` | Approve a code mapping (data steward) |
| `codes` | Each store/product's code in every system |
| `report stock [S01]` / `staleness` / `blocked` / `sales` / `reservations` / `reconciliation` / `all` | Reports 1–6 |

The full 10-minute demonstration, with what to say at each step, is in [docs/demo_runbook.md](docs/demo_runbook.md).

### Step 6: Run the checks

```bash
docker compose exec python python /workspace/tests/check_demo.py
```

Builds a separate database, `pethaven_check`, runs scripted business events and checks every rule in [docs/traceability.md](docs/traceability.md): immediate store updates, website staleness, bag, pickup options and checkout with the stock check before payment, first-to-checkout wins, transfers to the chosen store, blocked checkouts, overdue cancellation, online sales in the sales report, carton/UTC conversion, rejection and approval of unmapped codes, lineage, sync before/after and reconciliation. It ends with `TOTAL: 93 checks - PASS 93, FAIL 0`.

### Step 7: Stop the lab

```bash
docker compose stop
```

Your data is kept. Avoid `docker compose down -v` and do not delete `data/`; if that happens, rerun Step 4.

### Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `failed to connect to the docker API` or `Cannot connect to the Docker daemon` | Docker Desktop is not running. Start it, wait until the engine is running, and retry. |
| `Conflict. The container name "/student-postgres" is already in use` | Another copy of the course lab exists. In that lab's folder run `docker compose down`, without `-v`, then repeat Step 3. |
| `Connection refused` from `build.py` or `demo.py` | PostgreSQL is still starting. Wait 20–30 seconds and run the command again. |
| `can't open file '/workspace/C:/Program Files/Git/...'` | Git Bash rewrote the `/workspace` path. Use PowerShell, or put `MSYS_NO_PATHCONV=1` in front of the command, for example `MSYS_NO_PATHCONV=1 docker compose exec python python /workspace/scripts/build.py`. |
| `the input device is not a TTY` | Add `-T` after `exec` (`docker compose exec -T python python ...`). |
| `port is already allocated` (5432, 8978, ...) | Another program uses that port, often a locally installed PostgreSQL. Stop that program, then repeat Step 3. |


## Repository layout

```text
docker-compose.yml, python/            Lab Environment (unchanged course files)
workspace/
  db/01_schemas.sql                    five schemas
  db/02_store_ops.sql                  Source 1: store system
  db/03_supply.sql                     Source 2: delivery system
  db/04_online.sql                     Source 3: online store
  db/05_warehouse.sql                  star schema + sync log
  db/06_etl.sql                        extract -> transform -> validate -> load
  db/07_sync.sql                       dw.run_sync(), the manual "run sync now" job
  db/08_reports.sql                    report views
  db/seed/01_reference_data.sql        stores, products, codes per system, approved mappings
  db/seed/02_business_history.sql      a week of trading and two syncs
  scripts/build.py                     rebuild pethaven_demo
  scripts/demo.py                      demo commands
  demo/cloudbeaver_demo.sql            the demonstration as SQL statements
  tests/check_demo.py                  93 behaviour checks
docs/                                  design, traceability, demo runbook, implementation notes
00_req_feedback/                       brief, Spec, tutor feedback, subject notes
data/                                  lab database files created by Docker (not in Git)
```
