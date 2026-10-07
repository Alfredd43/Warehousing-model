# PetHaven dashboard: start, demonstrate, verify

The dashboard is a local web app over the existing prototype database. It opens on an **Overview** for the company admin, has three report pages (the assignment's required reports: Website stock, Store stock, Orders & lost sales), a technical **Data & integration** page, and a **Demo actions** panel that records real business events through the existing source-system functions. The brief it implements is [Dashboard_Implementation_Spec.md](Dashboard_Implementation_Spec.md).

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
| Data & integration | Solution evidence | How did source records reach the warehouse, and can the data be trusted? | `etl.v_item_list` / `v_store_codes`, `etl.v_staging`, `etl.etl_run`, `etl.stg_website_sync_line`, `etl.v_data_quality`, `dw.rpt_reconciliation`, trace query |

**Refresh** only reads the reports again. It never runs the sync or the ETL. Filters and selections are kept in the URL, so a reload or a shared link shows the same view.

**Automatic sync.** The status line on Website stock shows "Automatic sync: every 3 min · next in …" while the scheduler runs (started with `docker compose exec python python /workspace/scripts/demo.py scheduler start`), or "not started / stopped (manual sync only)". When a scheduled sync is due, the page re-reads its reports a moment later, so the website numbers update on screen; the dashboard itself never runs the scheduled sync. The **Sync website stock now** button in the Demo actions is the manual sync.

## 3. Demonstration (about 10 minutes)

Rebuild first so the starting point is known: `docker compose exec python python /workspace/scripts/build.py`. Then reload the dashboard.

Every write happens in the **Demo actions** panel, which is labelled "Writes to the database". Each result shows the identifiers the database actually generated and links to the affected report and the data trace. No order, bag or run number is hard-coded.

| Time | Where | Action | What to point out |
| --- | --- | --- | --- |
| 0:00 | Website stock | Start on the Overview (all tiles green apart from stock alerts), then Website stock: automatic sync status, last sync time, "The website matches the stores for all 18 products" | The website shows one combined number per product. It changes only on a sync (every 3 minutes, or by hand) or the website's own sales. Keep the scheduler stopped for this walkthrough so the stale state stays on screen. |
| 1:00 | Demo → Scenario A, step 1 | Product P018 → **Preview store stock** | The real free units per store (2 after a clean build) and the website number. |
| 1:45 | Step 2 | **Sell remaining available units** | One till receipt per store. The report refreshes: P018 is "Website higher +2", and the stock events since the last sync go up. |
| 2:45 | Step 3 | **Create bag, add 1 unit, check out** | The bag accepts the item (the stale website shows 2), but checkout checks real stock first: **blocked**, nothing charged or held. Follow **View blocked item**. |
| 3:45 | Orders & lost sales | The new blocked item record and its source checkout record | Website snapshot from the source next to the report's reconstruction. Reason: "Combined stock insufficient". |
| 4:30 | Demo → Scenario A, step 4 | **Sync website stock** (manual) | Website 2 → 0. On Website stock the latest sync lists the correction; the collapsed section shows the store balance changes it recorded. |
| 5:15 | Step 5 | **Try adding 1 unit to a new bag** | Refused by the product page: this is the fix working, not another blocked checkout. |
| 6:00 | Demo → Record supplier delivery | Location NSW-CHATS, item P001, 5 cartons (supplier: the item's, SUP-01; order number automatic or typed) | "5 cartons × 4 units/carton = 20 units", UTC → Sydney time; the staged reference names the supplier ID and supplier order number. **View data trace** shows source → staging → transformation → warehouse. |
| 7:00 | Demo → Record supplier delivery, then Record in-store sale | Item P019 (not on the warehouse product list), 2 cartons; then sell P019 at S01 | Both source operations succeed. The yellow banner appears; Data & integration shows 2 records rejected as "Unknown item P019" and a reconciliation gap. |
| 8:00 | Demo → Add item to product list | Review and add P019; **Run ETL** | The waiting records load, the banner disappears, reconciliation matches again. Running ETL again says "No pending records to process" (no duplicates). |
| 9:00 | Orders & lost sales → Click & collect orders | Order 5 | Lines held at Chatswood are in transit to Bondi, so the whole order is not ready, even though one line is. Optional: Demo → Order lifecycle → Customer collects on order 5 is refused with the store system's reason. |

If a step's prerequisite is not met (for example P018 already sold out), the panel explains why. Choose another product, record a supplier delivery first, or rebuild. Items are never removed from the warehouse product list automatically; for a fresh rejection demonstration, rebuild the database.

## 4. Verification (7 October 2026)

All runs used the isolated `pethaven_check` database; the dashboard's write tests never touch `pethaven_demo`.

| Check | Command | Result |
| --- | --- | --- |
| Existing business rules | `docker compose exec python python /workspace/tests/check_demo.py` | 104 / 104 PASS |
| Dashboard API | `docker compose exec python python /workspace/tests/check_dashboard.py` | 67 / 67 PASS |
| Automatic sync | `docker compose exec python python /workspace/tests/check_scheduler.py` | 17 / 17 PASS |
| Overlay start-up | the command in section 1 | Container `student-dashboard` up on 127.0.0.1:8080; with the lab on another network it showed the 503 "database unavailable" state until it was attached with `docker network connect` |

`check_dashboard.py` builds `pethaven_check`, starts the server in-process and checks:

- the website comparison, stock, blocked items and reservations against their report views;
- that `/stock` ignores date parameters;
- website corrections filtered to `online_available`, with the count taken from those rows rather than `numbers_changed`;
- parameter validation (400), body validation (422), wrong content type (415), cross-origin writes (403), missing records (404) and business refusals (409);
- that a sale or supplier delivery changes store stock but not the website number, and that cartons are converted to units;
- that store codes (S01, S03) are mapped to each system's store code, that unknown store codes and item numbers are refused, and that a supplier order number cannot be delivered twice;
- that each staged record carries its transaction ID (receipt number; supplier ID + supplier order number);
- that the status endpoint reports the automatic sync and that the sync button records a manual sync;
- that a blocked checkout is committed with no order and no hold, appears in Report 3 with its attempt, and that the bag can be edited and paid on a second attempt;
- the stale-preview refusal of the sell-out scenario;
- the add-to-bag refusal after the sync;
- that supplier delivery and rejected-record traces are correct, that P019 is rejected as an unknown item, and that adding it to the product list plus ETL loads exactly two facts, a second run does nothing, and reconciliation recovers;
- the Sydney business date and the history date filter;
- the 503 response when the database cannot be reached.

Browser checks were done at 1440 × 900, 1280 px, 768 px and 375 px on all four pages and the demo panel. Scenario A was run through the demo panel; scenarios B and C were run through the same endpoints. At 375 px nothing wider than the screen exists outside the tab strip and the architecture diagram, which scroll within their own containers. Text colours were checked for contrast: the spec's `--text-muted` (#777168) measured 4.3:1 on the page background, so it was darkened to #6F695F (4.9:1).

## 5. Limitations

- The checks are sequential. They do not prove isolation under concurrent checkouts; that relies on the existing row locks in `store_ops.find_stock` / `online.checkout` and would need independent sessions to demonstrate.
- Large lists are paged only where they can grow (event history, staging, ETL runs, sync records). Report tables are small in this prototype and are filtered in the browser.
- No authentication: the server accepts writes only from localhost with a JSON body and a matching Origin.
- Not built (secondary or excluded in the brief): CSV export and a visual concurrent-checkout demonstration.
- The "Report reconstruction" values on a blocked item come from warehouse history. The source checkout record keeps its own website snapshot; the page shows both and flags any difference.
