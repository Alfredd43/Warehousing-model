# Implementation status

Current verification results, what is built, and what is deliberately not implemented. The design is in [Architecture_and_Data_Model.md](Architecture_and_Data_Model.md); the rule → SQL → check mapping is in [traceability.md](traceability.md).

## Verification results (3 October 2026)

Run in the provided Lab Environment (PostgreSQL 15) from the repository root:

```bash
docker compose exec python python /workspace/scripts/build.py
docker compose exec python python /workspace/tests/check_demo.py
docker exec -i student-postgres psql -U student -d pethaven_demo < workspace/demo/cloudbeaver_demo.sql
```

| Measure | Result |
| --- | --- |
| Build (`build.py`) | All 10 SQL files applied without error |
| Behaviour checks (`check_demo.py`) | 81 / 81 PASS, exit code 0 |
| Demo script (`cloudbeaver_demo.sql`) | Runs top to bottom; the only error is the deliberate one in step 3c (collecting before a transfer arrives is refused) |
| Seed result | 157 source records staged → 148 fact rows loaded, 9 skipped, 0 rejected; 2 syncs; 0 events pending |
| Reconciliation after seed and after every sync | 90 / 90 store-product pairs match; `store_mismatches = 0` |
| ETL pass duration (CDC, one till sale) | about 5 ms average, under 10 ms for a whole sale |

## What is implemented

| Component | Objects |
| --- | --- |
| 3 source systems | `store_ops` (6 tables, 8 functions incl. transfers, EAN-13 validation), `supply` (4 tables, 1 function), `online` (6 tables, 3 functions incl. multi-line orders) |
| ETL | `etl` cross-references (2), staging (4), run log, CDC extract triggers (5), `v_transform`, `run_etl`, `load_dimensions`, `approve_product_mapping`, `v_staging`, `v_data_quality`, code look-ups |
| Data warehouse | `dim_product`, `dim_store`, `dim_date`, `fact_stock_event` (+4 indexes), `sync_run`, `sync_change`, `run_sync` |
| Reports | 8 views: stock by store, staleness, online vs actual, last sync changes, shortfall orders, daily sales, open reservations, reconciliation |
| Tooling | `build.py`, `demo.py` (13 commands), `cloudbeaver_demo.sql`, `check_demo.py` |

## Not implemented (out of scope)

| Item | Why | Effect |
| --- | --- | --- |
| Returns, stock adjustments | Not part of the staleness problem (Spec 2.2) | New event types would be needed; the fact design supports them |
| Splitting one order line across stores | Each line comes from one store (Spec 2.2) | A line only several stores together could fill becomes a shortfall (reason "no single store had enough"); other lines still go ahead |
| Customer-chosen pickup store | Pickup store = closest to the postcode (Spec 4.3) | The customer cannot pick a different store |
| Transit time and courier | Dispatch and receive are recorded steps only | No delivery estimate for transferred lines |
| Scheduled sync | Manual by design for the demonstration (Spec 6) | Staleness grows until someone runs the sync; the staleness report shows by how much |
| Online order status after placement | The store system owns the transfer/collection/cancellation lifecycle | `web_order.status` stays the outcome at placement; current state is in `store_ops.reservation` and `dw.rpt_open_reservations` |
| SCD type 2 history for prices | Prices are not part of the problem | `rpt_daily_sales` values sales at the current price |
| Separate databases per system / asynchronous CDC | The lab is one PostgreSQL instance | Documented as a trade-off (Arch 11) |

## Removed from the previous (v5) design

The earlier prototype (git history up to commit `ac499ca`) modelled a distribution centre, transfers, an overnight import, a midnight snapshot, a 5 am website copy, nine test scenarios and a Supabase backup option. It was replaced after the 29 Sep tutor feedback with this smaller design focused on the in-store / online stock sync problem. The `.env.example` file and `supabase_backup.md` were removed with it.
