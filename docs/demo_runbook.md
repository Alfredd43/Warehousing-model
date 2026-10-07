# PetHaven prototype: demonstration runbook

Step-by-step script for the live presentation and the recorded end-to-end video (brief item vi.e). Everything runs in the provided Lab Environment. Two equivalent ways to drive it:

- **CloudBeaver (recommended for the video):** run [`workspace/demo/cloudbeaver_demo.sql`](../workspace/demo/cloudbeaver_demo.sql) one statement at a time. The steps below match its numbered sections.
- **Terminal:** the `demo.py` commands shown next to each step (prefix: `docker compose exec python python /workspace/scripts/demo.py`).

Target length: about 10 minutes, as the brief allows a 10–15 minute presentation.

## Before the demo (once)

1. Start Docker Desktop, then from the repository root: `docker compose up -d`.
2. Run the checks; each must end with `FAIL 0` (104, 17 and 67 checks):

   ```bash
   docker compose exec python python /workspace/tests/check_demo.py
   docker compose exec python python /workspace/tests/check_scheduler.py
   docker compose exec python python /workspace/tests/check_dashboard.py
   ```

3. Build a clean demo database (do this again right before recording):

   ```bash
   docker compose exec python python /workspace/scripts/build.py
   ```

4. CloudBeaver (<http://localhost:8978>) connection: host `postgres`, port `5432`, database **`pethaven_demo`**, user/password `student`/`student`. After every rebuild, reconnect. Confirm with `SELECT current_database();`.
5. Open `workspace/demo/cloudbeaver_demo.sql` in the CloudBeaver SQL editor against that connection.
6. Leave the automatic sync **stopped** for steps 0–8 (it is stopped after every build), so the stale website number stays on screen until you run the sync yourself in step 4. Step 9 starts it.

## Demo script

| Min | Step | What to show | Terminal equivalent | What to say |
| --- | --- | --- | --- | --- |
| 0:00 | Problem | – | – | Website shows one combined number per product for 5 stores, refreshed by a sync every 3 minutes. In-store sales and supplier deliveries happen in other systems, so between syncs the website can be wrong: customers add items that no store can supply and only find out at checkout. |
| 1:00 | 0. Three systems | P001 in each catalogue, `etl.v_item_list`, `etl.v_store_codes`, `supply.supplier` | `codes` | All three systems (in-store, online, supplier) use the same **item number**; what differs is the transaction ID — receipt number, order ID, supplier ID + supplier order number — plus store codes, units (cartons) and time zone (UTC). Starting point: in sync, nothing pending, 90/90 reconcile. |
| 2:00 | 1. In-store sale | 3-item receipt at Parramatta; shelf drops; staging rows (store 101, receipt number); 3 facts (S01, `STORE:receipt …`); website unchanged | `sale S01 P003 2 P005 1 P009 1` | Sale is instant in the store system. The ETL extracted it, mapped the store code and loaded 3 events in the same transaction, each traced to the receipt number — but the website still shows the old numbers. |
| 3:00 | 2. Supplier delivery | Supplier SUP-01, order PO-2001: 5 cartons to Chatswood; staging (cartons, UTC) vs fact (20 units, Sydney time, `SUPPLY:supplier SUP-01 order PO-2001 …`) | `supplier-delivery S03 P001 5 --order PO-2001` | Transformation: cartons → units, UTC → Sydney business date; lineage to the supplier order. |
| 4:00 | 3. Bag, pickup options, checkout | One-item order paid and held at Bondi, website −2 at once. Then a bag with duck, aquarium kit and 2 dog beds: checkout **blocked before payment** (no single store has 2 beds), nothing held. Remove the beds; pickup options show Newtown (both items) and Bondi (duck only, kit transferred). Choose Bondi: paid; duck from Bondi, kit from Newtown. Dispatch the kit (in transit; collect refused), receive it (ready) | `order 2026 P001 2`, `order 2026 P009 1 P018 1 P013 2`, `remove 10 P013`, `options 10`, `checkout 10 --pickup S02`, `dispatch 9`, `collect 9`, `receive 9` | Checkout checks real stock before taking payment, so nobody is charged for something that can't be supplied. The customer chooses from the stores that hold their items; anything the chosen store lacks is transferred in. |
| 5:00 | 4. Staleness → sync | `rpt_online_staleness`, `rpt_online_vs_actual` (before); `online.sync_website_stock()` (manual, "run sync now"); `sync_run`; `rpt_last_sync_changes` (after) | `report staleness`, `online`, `sync` | Events pending and which numbers are wrong. The sync copies the real shelf totals from the store system to the website; the warehouse records every before/after for the reports. Normally this runs every 3 minutes; here it is run by hand to show it on cue. Pending → 0. |
| 6:30 | 5. Stale website | Sell the last aquarium kit in store; the website still shows 1, so it goes in the bag; checkout blocks it before payment; `rpt_checkout_blocked` | `sale S05 P018 1`, `order 2026 P018 1`, `report blocked` | The business problem in one example: the stale number let the customer get to checkout for something that no longer exists — a lost sale, recorded with the reason. |
| 7:30 | 6. Click & collect | `rpt_open_reservations`: seed order 5 has 2 items in transit, order 3 is overdue. Receive and collect order 5; run the overdue job (cancels order 3); collect order 9 | `report reservations`, `receive 5`, `collect 5`, `cancel-overdue`, `collect 9` | Lines move held → in transit → arrived → collected. Uncollected orders are cancelled after 3 days and the stock goes back on the shelf, which the website only learns at the next sync. |
| 8:30 | 7. Data quality | New item P019 delivered and sold; `etl.v_data_quality` shows 2 rows rejected as "Unknown item P019"; reconciliation gap; `etl.add_item('P019')`; `run_etl()` loads them | `supplier-delivery S01 P019 2`, `sale S01 P019 1`, `report reconciliation`, `add-item P019`, `etl` | An item the warehouse does not know is rejected, never guessed; the store keeps trading; the gap is visible; once the data steward adds the item to the product list the waiting rows load. `etl_run` is the audit log. |
| 9:30 | 8. Reports + final sync | Reports 1–6; final `online.sync_website_stock()` | `report all`, `sync` | Six reports from the warehouse; finish with the website correct again. |
| 10:00 | 9. Automatic sync | Start the scheduler; `rpt_online_staleness` shows running, every 3 min, next sync due; sell 1 × P001 → website stale; after the next scheduled sync it is in sync, `sync_run.triggered_by = scheduled`. Or show the dashboard's Website stock page counting down | `scheduler start`, `sale S01 P001 1`, `online`, `scheduler status`, `scheduler stop` | The website is never more than 3 minutes out of date (`SYNC_INTERVAL_SECONDS = 180`, one setting). The manual sync is still there for when it's needed. |

## Questions to be ready for

| Question | Short answer | Where |
| --- | --- | --- |
| Why is the warehouse updated instantly if it is a separate system? | The ETL is change-data-capture plus a micro-batch load, run inside the source transaction, so the warehouse can never be behind or disagree. In production this would be asynchronous log-based CDC. | Arch 5.4, 11 |
| How does each system identify a product and a transaction? | The **item number** (P001) is the same everywhere; the barcode, units per carton and web title are attributes. Transactions differ: receipt number (in-store), order ID (online), supplier ID + supplier order number (supplier). The warehouse keeps that ID on every event (`source_ref`). | Arch 4, 13 |
| What if an item isn't known to the warehouse yet? | It is rejected as "Unknown item" and waits in staging — never guessed — until a data steward adds it to the product list. Store codes still differ per system and are mapped through an approved list. | Arch 5.2–5.3 |
| What is the grain of the fact table? | One stock change for one product at one store. Current stock = sum of signed measures. | Arch 6.2 |
| Isn't a data warehouse for analysis, not operations? | Yes, and that is how it is used. The website number comes straight from the store system (like checkout does); the warehouse only records each sync and reports how stale the website was. | Arch 7, 10 |
| How do you know the warehouse is right? | Every sync reconciles all store/product pairs with the store system (`store_mismatches`, `rpt_reconciliation`), and 188 automated checks pass (104 rules, 17 scheduler, 67 dashboard). | Arch 7, implementation_notes |
| What if the closest store doesn't have everything? | The customer is offered every store that holds at least one item, best first (fewest transfers). Whatever the chosen store lacks is taken from the nearest store that has it and transferred; the customer collects once everything has arrived. A store with none of the items isn't offered. | Arch 4.3, 4.5 |
| Two customers want the last one at the same time? | Bags hold nothing. Whoever checks out first gets it; the other customer's checkout is blocked and the item stays in their bag. | Arch 4.3 |
| What if no store has an item? | Checkout is blocked before payment: nothing is charged or held, the customer sees which items to remove, and can check out the rest. A paid order can therefore always be fulfilled. | Arch 4.3, Spec 5.3 |
| If checkout checks real stock, why does the sync still matter? | The product page and the bag still use the website number. When it is stale, customers add items that are gone and are let down at checkout (Report 3); when it is understated, items that are in stock can't be added at all. | Spec 2.1, 5.2 |
| How often does the website sync? | Every 3 minutes, from a small scheduler in the lab's Python container; the interval is one setting (`SYNC_INTERVAL_SECONDS`). A manual "run sync now" is kept for demonstrations. Why not every sale? It would put the website sync in the path of every till transaction; a short interval keeps the window small. | Arch 7, 10, 11 |

## Recording checklist

- [ ] Fresh `build.py` immediately before recording; CloudBeaver reconnected to `pethaven_demo`.
- [ ] Automatic sync stopped until step 9 (`demo.py scheduler status` shows "stopped" or "never started").
- [ ] Font size large enough to read result grids.
- [ ] Show the check runs (`check_demo.py`, `check_scheduler.py`) final lines at the start or end.
- [ ] Upload to YouTube/GitHub and put the link in the report (section vi.e).
