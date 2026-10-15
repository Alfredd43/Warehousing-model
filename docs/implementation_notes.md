# Implementation status

Current verification results, what is built, and what is deliberately not implemented. The design is in [Architecture_and_Data_Model.md](Architecture_and_Data_Model.md); the rule → SQL → check mapping is in [traceability.md](traceability.md).

## Verification results (15 October 2026)

Run in the provided Lab Environment (PostgreSQL 15) from the repository root:

```bash
docker compose exec python python /workspace/scripts/build.py
docker compose exec python python /workspace/tests/check_demo.py
docker compose exec python python /workspace/tests/check_scheduler.py
docker compose exec python python /workspace/tests/check_dashboard.py
```

| Measure | Result |
| --- | --- |
| Build (`build.py`) | All 10 SQL files applied without error |
| Behaviour checks (`check_demo.py`) | 104 / 104 PASS, exit code 0 |
| Scheduler checks (`check_scheduler.py`, 2 s test interval) | 17 / 17 PASS; scheduled refreshes run at the test interval |
| Dashboard API checks (`check_dashboard.py`) | 38 / 38 PASS |
| End-to-end test script (`demo/video_demo_script.sql`) | Recorded test video: runs top to bottom on a fresh build with no errors and ends with 11 PASS checks (T1-T11); |
| Seed result | 155 source records staged → 146 fact rows loaded, 9 skipped, 0 rejected; 7 paid orders, 1 checkout blocked before payment; 2 refreshes; 0 events pending |
| Reconciliation after seed and after every website refresh | 90 / 90 store-product pairs match; `store_mismatches = 0` |
| ETL pass duration (CDC, one till sale) | about 5 ms average, under 10 ms for a whole sale |

## What is implemented

| Component | Objects |
| --- | --- |
| 3 source systems | `store_ops` (6 tables, 12 functions incl. checkout stock check, transfers and overdue cancellation, EAN-13 validation), `supply` (5 tables incl. suppliers and supplier orders, 1 function), `online` (13 tables incl. bag, checkout attempts, refresh log and scheduler registration, 9 functions incl. pickup options and the website refresh). All three key products on the same item number. |
| ETL | `etl` warehouse product list (`item_list`, `add_item`), store-code mapping (`store_xref`), staging (4), run log, CDC extract triggers (5), `v_transform`, `run_etl`, `load_dimensions`, `v_staging`, `v_data_quality`, look-ups (`v_item_list`, `v_store_codes`) |
| Data warehouse | `dim_product`, `dim_store`, `dim_date`, `fact_stock_event` (+4 indexes), `sync_run`, `sync_change`, `load_website_sync` (records each website refresh; the warehouse does not set the website number) |
| Reports | 8 views: stock by store, staleness, online vs actual, last refresh changes, items blocked at checkout, daily sales (both channels), open reservations, reconciliation |
| Automatic refresh | `sync_scheduler.py` runs the website refresh every `SYNC_INTERVAL_SECONDS` (180 s, set once in `pethaven_db.py`); `demo.py scheduler start / stop / status`; registration and heartbeat in `online.sync_schedule`; each website refresh tagged `scheduled` / `manual` / `seed` |
| Tooling | `build.py`, `demo.py` (18 commands), `video_demo_script.sql`, `check_demo.py`, `check_scheduler.py`, `check_dashboard.py` |

## Not implemented (out of scope)

| Item | Why | Effect |
| --- | --- | --- |
| Returns, stock adjustments | Out of scope (Spec 2.4) | New event types would be needed; the fact design supports them |
| Splitting one item across stores | Each item comes from one store (Spec 2.4) | An item only several stores together could supply is blocked at checkout (reason "no single store had enough"); the customer can remove it and buy the rest |
| Real stock check when adding to the bag | The bag uses the website number on purpose: that is where staleness shows | Customers can add items that are then blocked at checkout (Report 3) |
| Payment processing | Out of scope | "Paid" means the checkout succeeded; no card handling is modelled |
| Pickup at a store holding none of the items | Only stores holding at least one item are offered (Spec 4.3) | Everything would have to be transferred; not offered |
| Scheduled overdue cancellation | `cancel_overdue_orders` is run on demand (only the website refresh is scheduled) | Overdue orders stay held until someone runs it |
| Transit time and courier | Dispatch and receive are recorded steps only | No supplier delivery estimate for transferred lines |
| Automatic start of the scheduler | Started deliberately with `demo.py scheduler start` (not when the containers start), so a demonstration can keep a stale state on screen | After `docker compose up` or a `python` container restart, the website is refreshed only by hand until the scheduler is started; the dashboard shows "Automatic refresh: not running" |
| One store code in every system | Each system keeps its own store codes, as separate products from different vendors would | Store codes are mapped through `etl.store_xref`; every new store needs an approved mapping |
| Online order status after placement | The store system owns the transfer/collection/cancellation lifecycle | `web_order.status` stays the outcome at placement; current state is in `store_ops.reservation` and `dw.rpt_open_reservations` |
| SCD type 2 history for prices | Prices are not part of the problem | `rpt_daily_sales` values sales at the current price |
| Separate databases per system / asynchronous CDC | The lab is one PostgreSQL instance | Documented as a trade-off (Arch 11) |

## Changed after the 6 Oct tutor feedback

- **One item number in every system.** `store_ops.product`, `supply.item` and `online.product` all key on the item number (P001); the separate supplier SKU and web SKU, and the online store's `pos_barcode` link, were removed. The barcode, GTIN-14 and units per carton are attributes. `etl.product_xref` was replaced by the warehouse product list (`etl.item_list`): the data-quality demonstration now rejects an "Unknown item" (P019) until it is added with `etl.add_item` / `demo.py add-item`. The store-code mapping (`etl.store_xref`) stays.
- **Transaction IDs per system.** Receipt number (in-store), order ID (online), supplier ID + supplier order number (supplier; new `supply.supplier` table and `supplier_order_no`). Every warehouse event's `source_ref` carries the right one.
- **Website refresh every 3 minutes.** Scheduled by `scripts/sync_scheduler.py` (interval in `SYNC_INTERVAL_SECONDS`); manual "refresh now" kept for the demo video.
- **Wording:** in-store, online and supplier.

## Removed from the previous (v5) design

The earlier prototype (git history up to commit `ac499ca`) modelled a distribution centre, transfers, an overnight import, a midnight snapshot, a 5 am website copy, nine test scenarios and a Supabase backup option. It was replaced after the 29 Sep tutor feedback with this smaller design focused on the in-store / online stock mismatch problem. The `.env.example` file and `supabase_backup.md` were removed with it.
