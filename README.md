# PetHaven Data Solution

Assignment 2 prototype (32113 Advanced Database). PetHaven has five Sydney stores and an online store. The website shows one combined stock number per product, refreshed by a sync every 3 minutes, so between syncs customers can put items in their bag that no store can supply. Checkout checks real store stock before payment, so those items are blocked instead of being charged and cancelled. The prototype integrates **three source systems** (in-store, online, supplier) into **one data warehouse** through an ETL layer, refreshes the website number on a schedule straight from the store system, and uses the warehouse to report staleness, sync corrections and items blocked at checkout.

Every system identifies a product by the same **item number** (`P001`). What differs is each system's **transaction ID**, its store codes, and its units and time zone:

| Schema | Role | Transaction ID | Own codes and formats | Main objects |
| --- | --- | --- | --- | --- |
| `store_ops` | Source 1: store system (in-store tills, store stock, click & collect) | receipt number (`sale_no`) | store `101`; EAN-13 barcode as an attribute | `store`, `product`, `store_stock`, `sale`/`sale_line`, `reservation` |
| `supply` | Source 2: supplier delivery system | supplier ID + supplier order number | location `NSW-PARRA`, **cartons**, **UTC** | `supplier`, `location`, `item`, `supplier_delivery`/`supplier_delivery_line` |
| `online` | Source 3: online store | order ID (`order_no`) | collection point `CP-PARRAMATTA` | `product`, `online_stock` (website number), `collection_point`, `web_order`, `stock_sync`, `sync_schedule` |
| `etl` | ETL layer | – | – | staging tables, `item_list` (warehouse product list), `store_xref` (approved store-code mapping), `v_transform`, `run_etl`, `etl_run`, `v_data_quality` |
| `dw` | Integrated data warehouse | kept in `source_ref` | `S01`; `product_code` = the item number | `dim_product`, `dim_store`, `dim_date`, `fact_stock_event`, `sync_run`/`sync_change` (record of each sync), 8 report views |

How it behaves:

- **In-store sale / supplier delivery / collection / cancellation**: the store's stock changes immediately; the website number waits for the next sync.
- **Online shopping**: items go into a **bag** up to the (possibly stale) website number; nothing is held and bags never expire. The customer is offered every store that holds at least one bag item (fewest transfers first) and **chooses** where to collect. At **checkout, before payment**, real store stock is checked and locked, so whoever checks out first gets it. If any item can't be supplied by a single store, checkout is **blocked**: nothing charged, nothing held, and the customer removes it and tries again. Otherwise the order is **paid**, each item is held where it was found, items from other stores are **transferred** to the chosen store (dispatch → in transit → receive), and the website number drops at once. Orders not collected within 3 days are cancelled by the overdue job.
- **ETL**: every source record is captured into staging in its source format, with its transaction ID; the item is checked against the warehouse product list, the store code is mapped through the approved store-code mapping, quantities and times are converted (cartons → units, UTC → Sydney date), and the record is validated and loaded into `dw.fact_stock_event` in the same transaction. A record for an item the warehouse does not know is rejected as "Unknown item" and loads once a data steward adds the item.
- **Sync**: every 3 minutes (`SYNC_INTERVAL_SECONDS = 180` in `workspace/scripts/pethaven_db.py`) the scheduler runs `online.sync_website_stock()`: the online store takes the real shelf totals from the store system and updates the website. It can also be run by hand ("run sync now"). The warehouse is not involved in setting the number; through the ETL it records each sync (scheduled or manual, website before/after, store changes since the last sync, reconciliation) for the reports.

Documentation:

- Business case and rules: [00_req_feedback/Assignment2_Spec.md](00_req_feedback/Assignment2_Spec.md)
- Solution design (architecture, conceptual/logical models, ETL, rationale, trade-offs): [docs/Architecture_and_Data_Model.md](docs/Architecture_and_Data_Model.md)
- Rule → SQL → check mapping: [docs/traceability.md](docs/traceability.md)
- Demonstration script and Q&A: [docs/demo_runbook.md](docs/demo_runbook.md)
- Dashboard (start, demonstrate, verify): [docs/dashboard_runbook.md](docs/dashboard_runbook.md); its brief: [docs/Dashboard_Implementation_Spec.md](docs/Dashboard_Implementation_Spec.md)
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

This recreates the database `pethaven_demo`, creates the five schemas, loads the reference data and a week of sample trading through the source systems (so it all passes through the ETL), and runs two syncs, the last at build time. It ends with a summary: 155 source records staged, 146 stock events loaded, 0 rejected, 0 pending, 0 not reconciled. It does not start the automatic sync (Step 5).

Safe to rerun at any time. Only `pethaven_demo` and `pethaven_check` are ever dropped; the lab's own `lab` database is never touched.

### Step 5: Run the demo

**In CloudBeaver** (easiest): open <http://localhost:8978>, add a PostgreSQL connection (host `postgres`, port `5432`, database **`pethaven_demo`**, user/password `student`/`student`), then open [workspace/demo/cloudbeaver_demo.sql](workspace/demo/cloudbeaver_demo.sql) and run it one statement at a time. Reconnect after every rebuild.

**Start the automatic sync** (every 3 minutes) when you want it; it keeps running in the background until you stop it or the containers stop:

```bash
docker compose exec python python /workspace/scripts/demo.py scheduler start
```

`scheduler status` shows the interval, the last and the next sync; `scheduler stop` stops it. Leave it stopped while you record the step-by-step demo, so the stale website number stays until you run the sync yourself.

**In the terminal**: every command starts with `docker compose exec python python /workspace/scripts/demo.py`. Items are given by item number (`P001`), the same in every system; stores can be given as warehouse codes (`S01`), and the script prints each system's own store code.

| Command | What it does |
| --- | --- |
| `sale S01 P003 2 P005 1` | In-store till sale (one receipt, any number of items) |
| `supplier-delivery S03 P001 5 [--supplier SUP-01] [--order PO-2001]` | Supplier delivery, in cartons, for one supplier order |
| `order 2026 P009 1 P018 1 [--pickup S02]` | New bag from a customer postcode: shows pickup options, then checks out (real stock checked before payment) |
| `options 10` | Pickup options for bag 10 |
| `remove 10 P013` / `checkout 10 [--pickup S02]` | After a blocked checkout: remove an item from bag 10 / check out again |
| `cancel-overdue` | Cancel click-and-collect orders not collected within 3 days |
| `dispatch 6` / `receive 6` | Send order 6's lines held at other stores to its pickup store / book them in there |
| `collect 6` / `cancel 6` | Customer collects / cancels online order 6 |
| `online` | Website number vs real stock per product |
| `sync` | **Run sync now** (manual): stale "before", sync log, every number that changed |
| `scheduler start [--interval N]` / `stop` / `status` | Automatic sync every `SYNC_INTERVAL_SECONDS` (180 s) |
| `etl` | Run one ETL pass by hand; show the latest ETL runs |
| `add-item P019` | Add an item to the warehouse product list (data steward) |
| `codes` | The item list and each store's code in every system |
| `report stock [S01]` / `staleness` / `blocked` / `sales` / `reservations` / `reconciliation` / `all` | Reports 1–6 |

The full 10-minute demonstration, with what to say at each step, is in [docs/demo_runbook.md](docs/demo_runbook.md).

**In the dashboard** (web app over the same database):

```bash
docker compose -f docker-compose.yml -f workspace/dashboard/compose.dashboard.yml up -d dashboard
```

Open <http://localhost:8080>. It opens on an **Overview** for the company admin (what needs attention: website accuracy, next sync, stock alerts, lost sales, open click & collect orders), then the three required reports (Website stock, Store stock, Orders & lost sales), a technical **Data & integration** page with a source-to-warehouse trace, and a **Demo actions** panel that records sales, supplier deliveries, bags, checkouts, manual syncs and product-list additions through the source systems. Website stock shows the automatic sync's interval, the time since the last sync and a countdown to the next one. The overlay adds a `dashboard` service and leaves the lab files unchanged. The dashboard demonstration is in [docs/dashboard_runbook.md](docs/dashboard_runbook.md).

### Step 6: Run the checks

```bash
docker compose exec python python /workspace/tests/check_demo.py
```

Builds a separate database, `pethaven_check`, runs scripted business events and checks every rule in [docs/traceability.md](docs/traceability.md): immediate store updates, website staleness, bag, pickup options and checkout with the stock check before payment, first-to-checkout wins, transfers to the chosen store, blocked checkouts, overdue cancellation, online sales in the sales report, carton/UTC conversion, one item number in every system, transaction IDs in the lineage, rejection and recovery of unknown items, sync before/after and reconciliation. It ends with `TOTAL: 104 checks - PASS 104, FAIL 0`.

The automatic sync has its own checks (it starts the scheduler with a 2-second interval on `pethaven_check` and checks it syncs at that interval). The run ends with `TOTAL: 17 checks - PASS 17, FAIL 0`:

```bash
docker compose exec python python /workspace/tests/check_scheduler.py
```

The dashboard's API has its own checks, also on `pethaven_check`. The run ends with `TOTAL: 67 checks - PASS 67, FAIL 0`:

```bash
docker compose exec python python /workspace/tests/check_dashboard.py
```

### Step 7: Stop the lab

```bash
docker compose stop
```

Your data is kept. Avoid `docker compose down -v` and do not delete `data/`; if that happens, rerun Step 4. Stopping the lab also stops the automatic sync; start it again after the next `docker compose up -d`.

### Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `failed to connect to the docker API` or `Cannot connect to the Docker daemon` | Docker Desktop is not running. Start it, wait until the engine is running, and retry. |
| `Conflict. The container name "/student-postgres" is already in use` | Another copy of the course lab exists. In that lab's folder run `docker compose down`, without `-v`, then repeat Step 3. |
| `Connection refused` from `build.py` or `demo.py` | PostgreSQL is still starting. Wait 20–30 seconds and run the command again. |
| `can't open file '/workspace/C:/Program Files/Git/...'` | Git Bash rewrote the `/workspace` path. Use PowerShell, or put `MSYS_NO_PATHCONV=1` in front of the command, for example `MSYS_NO_PATHCONV=1 docker compose exec python python /workspace/scripts/build.py`. |
| `the input device is not a TTY` | Add `-T` after `exec` (`docker compose exec -T python python ...`). |
| Dashboard says "Database or server unavailable" | The lab was started from another folder, so its network is different. See [docs/dashboard_runbook.md](docs/dashboard_runbook.md), section 1. |
| `port is already allocated` (5432, 8978, ...) | Another program uses that port, often a locally installed PostgreSQL. Stop that program, then repeat Step 3. |
| Dashboard says "Automatic sync: not running" | The scheduler stopped (for example the `python` container restarted). Run `demo.py scheduler start` again; its log is in `/tmp/pethaven_sync_scheduler.log` inside the `python` container. |


## Repository layout

```text
docker-compose.yml, python/            Lab Environment (unchanged course files)
workspace/
  db/01_schemas.sql                    five schemas
  db/02_store_ops.sql                  Source 1: store system
  db/03_supply.sql                     Source 2: supplier delivery system
  db/04_online.sql                     Source 3: online store
  db/05_warehouse.sql                  star schema + sync log
  db/06_etl.sql                        extract -> transform -> validate -> load
  db/07_sync.sql                       load each website sync into the warehouse (for reporting)
  db/08_reports.sql                    report views
  db/seed/01_reference_data.sql        stores, items, suppliers, store codes per system, warehouse product list
  db/seed/02_business_history.sql      a week of trading and two syncs
  scripts/pethaven_db.py               shared settings, incl. SYNC_INTERVAL_SECONDS = 180
  scripts/build.py                     rebuild pethaven_demo
  scripts/demo.py                      demo commands (incl. scheduler start / stop / status)
  scripts/sync_scheduler.py            runs the website sync every SYNC_INTERVAL_SECONDS
  demo/cloudbeaver_demo.sql            the demonstration as SQL statements
  tests/check_demo.py                  104 behaviour checks
  tests/check_scheduler.py             17 automatic-sync checks
  tests/check_dashboard.py             67 dashboard API checks
  dashboard/server.py                  dashboard: local HTTP server and API routes
  dashboard/queries.py, actions.py     read queries over the report views / demo actions calling source functions
  dashboard/static/                    dashboard pages (HTML, CSS, JavaScript modules)
  dashboard/compose.dashboard.yml      optional Compose overlay that runs the dashboard on port 8080
docs/                                  design, traceability, demo runbook, implementation notes
00_req_feedback/                       brief, Spec, tutor feedback, subject notes
data/                                  lab database files created by Docker (not in Git)
```
