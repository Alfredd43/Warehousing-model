# PetHaven dashboard: start, use, verify

The dashboard is a local web app over the existing prototype database. It is built around the four data use cases (Spec 9): it opens on an **Overview** of what needs attention, and three pages answer the use cases: Website stock, Orders & potential lost sales, and Store stock. It is read-only: business events are made with `demo.py` or the source systems' SQL functions. The brief it implements is [Dashboard_Implementation_Spec.md](Dashboard_Implementation_Spec.md).

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

**If the page says "Database or server unavailable"** while the lab is running, the lab was probably started from a different folder, so it runs as a different Compose project with its own network. Either stop that lab and start this repository's lab (README, Step 2), or attach the dashboard to the running lab's network:

```bash
docker network connect <other-lab-folder>_default student-dashboard
```

Use `docker network ls` to find the network name (`<folder name>_default`).

Without Docker, from the repository root with Python 3.11 and `psycopg2-binary` installed:

```bash
PGHOST=localhost python workspace/dashboard/server.py --port 8080
```

## 2. What each page shows

| Page | Data use case (user, impact) | Business question | Main data |
| --- | --- | --- | --- |
| Overview (start page) | Summary across UC1-UC4, mainly for the owner | What needs attention now? Website accuracy, next refresh, stock alerts, potential lost sales, open click & collect orders, units sold, with a "Needs attention" list linking to each page | `/api/overview` over `dw.rpt_online_vs_actual`, `rpt_online_staleness`, `rpt_current_stock_by_store`, `rpt_checkout_blocked`, `rpt_open_reservations`, `rpt_daily_sales` |
| Website stock | UC1 Website accuracy (owner, high); Report 2 | Does the website show what the stores can supply? How often does it refresh, when was the last refresh (automatic or manual), when is the next one? What did the last refresh change? | `dw.rpt_online_vs_actual`, `dw.rpt_online_staleness` (incl. scheduler status and interval), `dw.rpt_last_sync_changes`, `dw.sync_run` / `dw.sync_change` |
| Store stock | UC3 Low stock (store managers, medium) and UC4 Stock position (store staff, low); Report 1 | Which stores are low on stock? Where is stock available or reserved, and which events explain it? | `dw.rpt_current_stock_by_store`, `dw.fact_stock_event` (event history), units sold per product in the last 7 days (stock and sales chart) |
| Orders & potential lost sales | UC2 Blocked checkouts (owner, high); Report 3, plus open click & collect orders (Report 5) for store staff | What happened when a customer checked out, and where are open orders? | `dw.rpt_checkout_blocked` + `online.checkout_attempt*` (source record), `dw.rpt_open_reservations` |

**Reload** only reads the reports again. It never refreshes the website stock or runs the ETL. Filters and selections are kept in the URL, so a reload or a shared link shows the same view.

**Automatic website refresh.** The status line on Website stock shows "Automatic refresh: every 3 min · next in …" while the scheduler runs (started with `docker compose exec python python /workspace/scripts/demo.py scheduler start`), or "Automatic refresh: not running — the website only updates on a manual refresh". When a scheduled refresh is due, the page re-reads its reports a moment later, so the website numbers update on screen; the dashboard itself never runs the scheduled refresh. The manual refresh is `docker compose exec python python /workspace/scripts/demo.py sync`.

## 3. Demonstration

The dashboard is demonstrated in the recorded end-to-end test video, not live: [demo/video_demo_script.sql](../demo/video_demo_script.sql) shows each data use case (UC1-UC4) first as a report query, then on the dashboard page that answers it (lines marked `DASHBOARD`). The presentation plays that video sped up ([demo/demo_runbook.md](../demo/demo_runbook.md)).

To make your own business events while the dashboard is open, use `demo.py` (README, "In the terminal") and press **Reload**.

## 4. Verification (13 October 2026)

All runs used the isolated `pethaven_check` database; the dashboard checks never touch `pethaven_demo`.

| Check | Command | Result |
| --- | --- | --- |
| Existing business rules | `docker compose exec python python /workspace/tests/check_demo.py` | 105 / 105 PASS |
| Dashboard API | `docker compose exec python python /workspace/tests/check_dashboard.py` | 45 / 45 PASS |
| Automatic refresh | `docker compose exec python python /workspace/tests/check_scheduler.py` | 17 / 17 PASS |
| Overlay start-up | the command in section 1 | Container `student-dashboard` up on 127.0.0.1:8080; with the lab on another network it showed the 503 "database unavailable" state until it was attached with `docker network connect` |

`check_dashboard.py` builds `pethaven_check`, starts the server in-process, makes business events with the source systems' own SQL functions (as `demo.py` does) and checks:

- the website comparison, stock, blocked items, reservations and overview tiles against their report views;
- that `/stock` ignores date parameters;
- parameter validation (400), missing records and unknown endpoints (404), and that any write request is refused (405);
- that a sale changes warehouse stock but not the website number, that its event carries the receipt number, and that a supplier delivery's cartons are converted to units;
- that a blocked checkout appears in Report 3 with its attempt, and that its source record shows no order and an open bag;
- that the status endpoint reports the automatic refresh, and that the latest refresh's website corrections are filtered to `online_available`, with the count taken from those rows rather than `numbers_changed`;
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
