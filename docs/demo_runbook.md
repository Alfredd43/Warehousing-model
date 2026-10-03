# PetHaven prototype: demonstration runbook

Step-by-step script for the live presentation and the recorded end-to-end video (brief item vi.e). Everything runs in the provided Lab Environment. Two equivalent ways to drive it:

- **CloudBeaver (recommended for the video):** run [`workspace/demo/cloudbeaver_demo.sql`](../workspace/demo/cloudbeaver_demo.sql) one statement at a time. The steps below match its numbered sections.
- **Terminal:** the `demo.py` commands shown next to each step (prefix: `docker compose exec python python /workspace/scripts/demo.py`).

Target length: about 10 minutes, as the brief allows a 10–15 minute presentation.

## Before the demo (once)

1. Start Docker Desktop, then from the repository root: `docker compose up -d`.
2. Run the checks; the last line must be `TOTAL: 81 checks - PASS 81, FAIL 0`:

   ```bash
   docker compose exec python python /workspace/tests/check_demo.py
   ```

3. Build a clean demo database (do this again right before recording):

   ```bash
   docker compose exec python python /workspace/scripts/build.py
   ```

4. CloudBeaver (<http://localhost:8978>) connection: host `postgres`, port `5432`, database **`pethaven_demo`**, user/password `student`/`student`. After every rebuild, reconnect. Confirm with `SELECT current_database();`.
5. Open `workspace/demo/cloudbeaver_demo.sql` in the CloudBeaver SQL editor against that connection.

## Demo script

| Min | Step | What to show | Terminal equivalent | What to say |
| --- | --- | --- | --- | --- |
| 0:00 | Problem | – | – | Website shows one combined number per product for 5 stores, refreshed only when a sync runs. Store sales and deliveries happen in other systems, so between syncs the website is wrong and can accept orders nobody can fill. |
| 1:00 | 0. Three systems | `etl.v_store_codes`, `etl.v_product_codes`, the same dog food in each system | `codes` | Three sources with their own codes, units (cartons) and time zone (UTC). The warehouse maps them through approved cross-references to one conformed code. Starting point: in sync, nothing pending, 90/90 reconcile. |
| 2:00 | 1. In-store sale | 3-item receipt at Parramatta; shelf drops; staging rows in store codes; 3 facts in warehouse codes; website unchanged | `sale S01 P003 2 P005 1 P009 1` | Sale is instant in the store system. The ETL extracted it, mapped codes and loaded 3 events in the same transaction — but the website still shows the old numbers. |
| 3:00 | 2. Delivery | 5 cartons to Chatswood; staging (cartons, UTC) vs fact (20 units, Sydney time) | `delivery S03 P001 5` | Transformation: cartons → units, UTC → Sydney business date. |
| 4:00 | 3. Online orders | One-item order held at Bondi (the closest store), website −2 at once. Then a 3-item Bondi order: duck held at Bondi, aquarium kit taken from Newtown, 2 dog beds a shortfall (no single store has 2). Dispatch the kit (in transit; collect refused), receive it (ready) | `order 2026 P001 2`, `order 2026 P009 1 P018 1 P013 2`, `dispatch 10`, `collect 10`, `receive 10` | The customer collects everything at the closest store; anything it lacks comes from the next-nearest store and is transferred. Checked against real stock, not the website number. |
| 5:00 | 4. Staleness → sync | `rpt_online_staleness`, `rpt_online_vs_actual` (before); `run_sync()`; `sync_run`; `rpt_last_sync_changes` (after) | `report staleness`, `online`, `sync` | Events pending and which numbers are wrong; one call recalculates from the warehouse and logs every before/after. Pending → 0. |
| 6:30 | 5. Shortfall | Sell the last 2 aquarium kits in store; website still shows 2; order 1 online → shortfall; `rpt_shortfall_orders` | `sale S04 P018 1`, `sale S05 P018 1`, `order 2026 P018 1`, `report shortfall` | The business problem in one example: accepted on a stale number, nobody can supply it, recorded against the store it was meant to come from, with the reason. |
| 7:30 | 6. Click & collect | `rpt_open_reservations`: seed order 6 has 2 lines in transit, order 3 is overdue. Receive and collect order 6; cancel order 3; collect order 10 | `report reservations`, `receive 6`, `collect 6`, `cancel 3`, `collect 10` | Lines move held → in transit → arrived → collected. Cancelling puts stock back on the shelf where it is now, which the website only learns at the next sync. |
| 8:30 | 7. Data quality | New product P019 delivered and sold; `etl.v_data_quality` shows 2 rejected rows with reasons; reconciliation gap; approve mappings; `run_etl()` loads them | `delivery S01 PP-CAT-TUNNEL 2`, `sale S01 9300601001194 1`, `report reconciliation`, `approve SUPPLY PP-CAT-TUNNEL P019`, `approve STORE 9300601001194 P019`, `etl` | Unknown codes are rejected, never guessed; the store keeps trading; the gap is visible; once approved the waiting rows load. `etl_run` is the audit log. |
| 9:30 | 8. Reports + final sync | Reports 1–6; final `run_sync()` | `report all`, `sync` | Six reports from the warehouse; finish with the website correct again. |

## Questions to be ready for

| Question | Short answer | Where |
| --- | --- | --- |
| Why is the warehouse updated instantly if it is a separate system? | The ETL is change-data-capture plus a micro-batch load, run inside the source transaction, so the warehouse can never be behind or disagree. In production this would be asynchronous log-based CDC. | Arch 5.4, 11 |
| Why not match products by barcode or name? | Names differ by design; codes are matched only through an approved cross-reference so a wrong match can never corrupt stock. Unmatched rows wait in staging. | Arch 5.2–5.3 |
| What is the grain of the fact table? | One stock change for one product at one store. Current stock = sum of signed measures. | Arch 6.2 |
| How do you know the warehouse is right? | Every sync reconciles all store/product pairs with the store system (`store_mismatches`, `rpt_reconciliation`), and 81 automated checks pass. | Arch 7, implementation_notes |
| What if the closest store doesn't have everything? | Each missing line is taken from the next-nearest store that has the whole quantity and transferred to the closest store; the customer collects once everything has arrived. A line no single store can supply is a shortfall, and the rest of the order still goes ahead. | Arch 4.3, 4.5 |
| Why can a reserved order still become a shortfall? | It can't: a shortfall is an accepted order line no store could hold. Either the stock was sold since the sync (stale) or it was split across stores. | Spec 5.3 |
| Why a manual sync? | The problem is staleness; a manual trigger shows it on cue. A schedule only changes when the same function runs. | Arch 10 |

## Recording checklist

- [ ] Fresh `build.py` immediately before recording; CloudBeaver reconnected to `pethaven_demo`.
- [ ] Font size large enough to read result grids.
- [ ] Show the check run (`check_demo.py`) final line at the start or end.
- [ ] Upload to YouTube/GitHub and put the link in the report (section vi.e).
