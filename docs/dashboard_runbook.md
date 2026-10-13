# PetHaven dashboard: start, demonstrate, verify

The dashboard is a local web app over the existing prototype database. It opens on an **Overview** for the company admin, and has three report pages (the assignment's required reports: Website stock, Store stock, Orders & lost sales). It is read-only: business events are made with `demo.py` (section 3). The brief it implements is [Dashboard_Implementation_Spec.md](Dashboard_Implementation_Spec.md).

It is a localhost teaching prototype: a standard-library Python HTTP server plus static HTML, CSS and JavaScript. It is not production hosting.

## 1. Start

Prerequisites: the lab is running (`docker compose up -d`) and `pethaven_demo` is built (`docker compose exec python python /workspace/scripts/build.py`). The dashboard never builds or rebuilds a database.

From the repository root:

```bash
docker compose -f docker-compose.yml -f workspace/dashboard/compose.dashboard.yml up -d dashboard
```

Open <http://localhost:8080>. The port is published on this computer only (`127.0.0.1`).

The overlay adds one service, `dashboard` (container `student-dashboard`), built from the lab's own `python/Dockerfile`. The root `docker-compose.yml`, `python/Dockerfile` and `python/requirements.txt` are unchanged, and the lab's `python` container stays free for `build.py`, `demo.py` and the checks.

| Task | Command |
| --- | --- |
| Logs | `docker logs -f student-dashboard` |
| Restart after editing Python files | `docker restart student-dashboard` (static files need only a browser refresh) |
| Stop | `docker compose -f docker-compose.yml -f workspace/dashboard/compose.dashboard.yml stop dashboard` |
| Use the check database instead | set `DASHBOARD_DB: pethaven_check` in the overlay and recreate the service |

**If the page says "Database or server unavailable"** while the lab is running, the lab was probably started from a different folder, so it runs as a different Compose project with its own network. (This happened while the dashboard was being built: the running lab came from `D:\00_project\PetHaven_data_solution`.) Either stop that lab and start this repository's lab (README, Step 2), or attach the dashboard to the running lab's network:

```bash
docker network connect pethaven_data_solution_default student-dashboard
```

Use `docker network ls` to find the network name (`<folder name>_default`).

Without Docker, from the repository root with Python 3.11 and `psycopg2-binary` installed:

```bash
PGHOST=localhost python workspace/dashboard/server.py --port 8080
```

## 2. What each page shows

| Page | Assignment output | Business question | Main data |
| --- | --- | --- | --- |
| Overview (start page) | Summary for the admin | What needs attention now? Website accuracy, next sync, stock alerts, lost sales, open click & collect orders, units sold, with a "Needs attention" list linking to each page | `/api/overview` over `dw.rpt_online_vs_actual`, `rpt_online_staleness`, `rpt_current_stock_by_store`, `rpt_checkout_blocked`, `rpt_open_reservations`, `rpt_daily_sales` |
| Website stock | Required report 2 | Does the website show what the stores can supply? How often does it sync, when was the last sync (automatic or manual), when is the next one? What did the last sync change? | `dw.rpt_online_vs_actual`, `dw.rpt_online_staleness` (incl. scheduler status and interval), `dw.rpt_last_sync_changes`, `dw.sync_run` / `dw.sync_change` |
| Store stock | Required report 1 | Where is stock available or reserved, and which events explain it? | `dw.rpt_current_stock_by_store`, `dw.fact_stock_event` (event history), `dw.rpt_daily_sales` (Sales history tab) |
| Orders & lost sales | Required report 3 + open reservations | What happened when a customer checked out, and where are open orders? | `dw.rpt_checkout_blocked` + `online.checkout_attempt*` (source record), `dw.rpt_open_reservations` |

**Refresh** only reads the reports again. It never runs the sync or the ETL. Filters and selections are kept in the URL, so a reload or a shared link shows the same view.

**Automatic sync.** The status line on Website stock shows "Automatic sync: every 3 min · next in …" while the scheduler runs (started with `docker compose exec python python /workspace/scripts/demo.py scheduler start`), or "Automatic sync: not running — the website only updates on a manual sync". When a scheduled sync is due, the page re-reads its reports a moment later, so the website numbers update on screen; the dashboard itself never runs the scheduled sync. The manual sync is `docker compose exec python python /workspace/scripts/demo.py sync`.

## 3. Demonstration (about 10 minutes)

Rebuild first so the starting point is known: `docker compose exec python python /workspace/scripts/build.py`. Then reload the dashboard.

The dashboard is read-only. Business events are made in a terminal with `demo.py` (prefix each command below with `docker compose exec python python /workspace/scripts/demo.py`); press **Refresh** on the dashboard to see their effect.

| Time | Terminal (`demo.py …`) | Dashboard | What to point out |
| --- | --- | --- | --- |
| 0:00 | – | Overview (all tiles green apart from stock alerts), then Website stock: automatic sync status, last sync time, "The website matches the stores for all 18 products" | The website shows one combined number per product. It changes only on a sync (every 3 minutes, or by hand) or the website's own sales. Keep the scheduler stopped for this walkthrough so the stale state stays on screen. |
| 1:00 | `report stock` | Store stock, product P018 | After a clean build P018 has 1 free unit at Newtown (S04) and 1 at Penrith (S05). |
| 1:45 | `sale S04 P018 1`, then `sale S05 P018 1` | Website stock | One till receipt per store. P018 is "Website too high" by 2, and the stock events since the last sync go up. |
| 2:45 | `order 2026 P018 1` | Orders & lost sales | The bag accepts the item (the stale website shows 2), but checkout checks real stock first: **blocked**, nothing charged or held. |
| 3:45 | – | Orders & lost sales → the new blocked item | Its source checkout record: website snapshot from the source next to the report's reconstruction. Reason: "Website number was out of date". |
| 4:30 | `sync` | Website stock | Website 2 → 0. The latest sync lists the correction; the collapsed section shows the store balance changes it recorded. |
| 5:15 | `order 2026 P018 1` | – | Refused when adding to the bag: this is the fix working, not another blocked checkout. |
| 6:00 | `supplier-delivery S03 P001 5` | Store stock → P001 at Chatswood → event history | "5 cartons × 4 units/carton = 20 units"; the event's source reference names the supplier ID and supplier order number. |
| 7:00 | `supplier-delivery S01 P019 2 --supplier SUP-02`, then `sale S01 P019 1` | The yellow banner appears on every page | Both source operations succeed, but the ETL rejects 2 records as "Unknown item P019" and the warehouse no longer matches the store system (`report reconciliation` lists them). |
| 8:00 | `add-item P019`, then `etl` | The banner disappears | The waiting records load and reconciliation matches again. Running `etl` again finds nothing to process (no duplicates). |
| 9:00 | – | Orders & lost sales → Click & collect orders, order 5 | Lines held at Chatswood are in transit to Bondi, so the whole order is not ready, even though one line is. Optional: `collect 5` is refused with the store system's reason. |

If a step's prerequisite is not met (for example P018 already sold out), `demo.py` prints the source system's reason. Choose another product, record a supplier delivery first, or rebuild. Items are never removed from the warehouse product list automatically; for a fresh rejection demonstration, rebuild the database.

## 4. Verification (13 October 2026)

All runs used the isolated `pethaven_check` database; the dashboard checks never touch `pethaven_demo`.

| Check | Command | Result |
| --- | --- | --- |
| Existing business rules | `docker compose exec python python /workspace/tests/check_demo.py` | 104 / 104 PASS |
| Dashboard API | `docker compose exec python python /workspace/tests/check_dashboard.py` | 38 / 38 PASS |
| Automatic sync | `docker compose exec python python /workspace/tests/check_scheduler.py` | 17 / 17 PASS |
| Overlay start-up | the command in section 1 | Container `student-dashboard` up on 127.0.0.1:8080; with the lab on another network it showed the 503 "database unavailable" state until it was attached with `docker network connect` |

`check_dashboard.py` builds `pethaven_check`, starts the server in-process, makes business events with the source systems' own SQL functions (as `demo.py` does) and checks:

- the website comparison, stock, blocked items, reservations and overview tiles against their report views;
- that `/stock` ignores date parameters;
- parameter validation (400), missing records and unknown endpoints (404), and that any write request is refused (405);
- that a sale changes warehouse stock but not the website number, that its event carries the receipt number, and that a supplier delivery's cartons are converted to units;
- that a blocked checkout appears in Report 3 with its attempt, and that its source record shows no order and an open bag;
- that the status endpoint reports the automatic sync, and that the latest sync's website corrections are filtered to `online_available`, with the count taken from those rows rather than `numbers_changed`;
- that the shared "data may be incomplete" warning appears when P019 is rejected and clears once it is added to the product list and the ETL runs;
- the Sydney business date and the history date filter;
- the 503 response when the database cannot be reached.

Browser checks (7 October) were done at 1440 × 900, 1280 px, 768 px and 375 px. At 375 px nothing wider than the screen exists outside the tab strip, which scrolls within its own container. Text colours were checked for contrast: the spec's `--text-muted` (#777168) measured 4.3:1 on the page background, so it was darkened to #6F695F (4.9:1). On 13 October the Demo actions panel and the Data & integration page were removed; the four remaining pages were reloaded with no console errors.

## 5. Limitations

- The checks are sequential. They do not prove isolation under concurrent checkouts; that relies on the existing row locks in `store_ops.find_stock` / `online.checkout` and would need independent sessions to demonstrate.
- Large lists are paged only where they can grow (event history). Report tables are small in this prototype and are filtered in the browser.
- No authentication: the server is read-only and published on 127.0.0.1 only.
- Not built (secondary or excluded in the brief): CSV export and a visual concurrent-checkout demonstration.
- The "Report reconstruction" values on a blocked item come from warehouse history. The source checkout record keeps its own website snapshot; the page shows both and flags any difference.
