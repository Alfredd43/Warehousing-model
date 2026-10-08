# PetHaven prototype: demonstration runbook

Step-by-step script for the recorded video (brief item vi.e) and the live presentation. Everything runs in the provided Lab Environment.

- **The video (Part A)** shows one thing: a customer buys in a store (offline), the store's stock drops at once, the website still shows the old number, and the next sync refreshes the website. It is run entirely as queries in CloudBeaver.
- **Additional checks (Part B)** demonstrate the rest of the prototype (supplier deliveries, online checkout, transfers, data quality, reports) for the presentation or for questions.

Two equivalent ways to drive it:

- **CloudBeaver (recommended for the video):** run [`workspace/demo/cloudbeaver_demo.sql`](../workspace/demo/cloudbeaver_demo.sql) one statement at a time. Part A is steps A0–A5, Part B is sections 0–8.
- **Terminal:** the `demo.py` commands shown next to each step (prefix: `docker compose exec python python /workspace/scripts/demo.py`).

Target length: the video about 4 minutes (6 with the optional automatic sync); the additional checks about 8 minutes.

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
6. Make sure the automatic sync is **not running**, so the out-of-date website number stays on screen until you run the sync yourself in step A4. Step A0 checks this in CloudBeaver and stops it if needed. (A rebuild does not stop a running scheduler; it reconnects to the new database.)

## Video: an in-store sale, then the website refreshes (Part A)

Run these in CloudBeaver, one statement at a time. The numbers are what a fresh build shows.

| Min | Step | What to run (CloudBeaver) | What you will see | What to say |
| --- | --- | --- | --- | --- |
| 0:00 | Problem | – | – | PetHaven has five stores and a website. The website shows one combined stock number per product. Store sales are recorded in the store system, not on the website, so the website only learns about them when a sync runs (every 3 minutes). Until then it can show stock that has already been sold. |
| 0:45 | A0. Ready | `SELECT current_database();`, `scheduler_status`, the `UPDATE … 'stop_requested'` line | `pethaven_demo`; `never started` or `stopped` | (Off camera, or say:) the automatic sync is paused so we can see the website out of date. |
| 1:00 | A1. Before | The three `P001` queries: website number, shelf per store, `rpt_online_vs_actual` | Website **183**; Parramatta 37, all stores 183; status `in sync` | Dog food P001: the website shows 183 and the five stores really have 183. They agree. |
| 1:45 | A2. Buy offline | `SELECT store_ops.record_sale('101', ARRAY['P001'], ARRAY[3]);` | A receipt number | A customer buys 3 bags at the Parramatta till. This happens in the store system, not on the website. |
| 2:15 | A3. Store changed, website did not | Shelf at Parramatta; latest warehouse event; website number; `rpt_online_vs_actual`; `rpt_online_staleness` | Parramatta **37 → 34**; warehouse event `store_sale -3`, `STORE:receipt …`; website **still 183**, stores 180, `overstated - oversell risk`; 1 event pending | The store's stock dropped instantly, and the warehouse recorded the sale, traced to its receipt number. But the website still says 183: an online customer could try to buy stock that is gone. |
| 3:15 | A4. Website refreshes | `SELECT online.sync_website_stock();`, then the website number, `rpt_online_vs_actual`, `sync_run`, `rpt_last_sync_changes` | Website **180**, `in sync`; sync `manual`, 1 event, 0 mismatches; changes: Parramatta 37 → 34, website 183 → 180 | The sync takes the real shelf totals from the store system and updates the website. It runs every 3 minutes on its own; I ran it by hand so you can see it. The warehouse logs what each sync changed. |
| 4:15 | A5. (Optional) Automatic | In a terminal: `demo.py scheduler start`. Then in CloudBeaver: scheduler status, `record_sale('101', ARRAY['P001'], ARRAY[2])`, `rpt_online_vs_actual`; wait until `next_sync_at` (at most 3 min), run it again; `sync_run`; the stop `UPDATE` | `running`, `00:03:00`; website 180 vs stores 178 `overstated`; after the wait 178 / 178 `in sync`, `triggered_by = scheduled` | The same thing with nobody pressing anything: the website is never more than 3 minutes behind the stores. (You can cut the wait in editing.) |

Terminal equivalent of A1–A4: `online`, `sale S01 P001 3`, `online`, `sync`.

## Additional checks (Part B)

Optional, for the presentation or questions. Run Part B in CloudBeaver after Part A (the section numbers match), or use the terminal commands.

| Step | What to show | Terminal equivalent | What to say |
| --- | --- | --- | --- |
| 0. Three systems | P001 in each catalogue, `etl.v_item_list`, `etl.v_store_codes`, `supply.supplier` | `codes` | All three systems (in-store, online, supplier) use the same **item number**; what differs is the transaction ID — receipt number, order ID, supplier ID + supplier order number — plus store codes, units (cartons) and time zone (UTC). Starting point: in sync, nothing pending, 90/90 reconcile. |
| 1. In-store sale | 3-item receipt at Parramatta; shelf drops; staging rows (store 101, receipt number); 3 facts (S01, `STORE:receipt …`); website unchanged | `sale S01 P003 2 P005 1 P009 1` | Sale is instant in the store system. The ETL extracted it, mapped the store code and loaded 3 events in the same transaction, each traced to the receipt number — but the website still shows the old numbers. |
| 2. Supplier delivery | Supplier SUP-01, order PO-2001: 5 cartons to Chatswood; staging (cartons, UTC) vs fact (20 units, Sydney time, `SUPPLY:supplier SUP-01 order PO-2001 …`) | `supplier-delivery S03 P001 5 --order PO-2001` | Transformation: cartons → units, UTC → Sydney business date; lineage to the supplier order. |
| 3. Bag, pickup options, checkout | One-item order paid and held at Bondi, website −2 at once. Then a bag with duck, aquarium kit and 2 dog beds: checkout **blocked before payment** (no single store has 2 beds), nothing held. Remove the beds; pickup options show Newtown (both items) and Bondi (duck only, kit transferred). Choose Bondi: paid; duck from Bondi, kit from Newtown. Dispatch the kit (in transit; collect refused), receive it (ready) | `order 2026 P001 2`, `order 2026 P009 1 P018 1 P013 2`, `remove 10 P013`, `options 10`, `checkout 10 --pickup S02`, `dispatch 9`, `collect 9`, `receive 9` | Checkout checks real stock before taking payment, so nobody is charged for something that can't be supplied. The customer chooses from the stores that hold their items; anything the chosen store lacks is transferred in. |
| 4. Staleness → sync | `rpt_online_staleness`, `rpt_online_vs_actual` (before); `online.sync_website_stock()` (manual, "run sync now"); `sync_run`; `rpt_last_sync_changes` (after) | `report staleness`, `online`, `sync` | Events pending and which numbers are wrong. The sync copies the real shelf totals from the store system to the website; the warehouse records every before/after for the reports. Normally this runs every 3 minutes; here it is run by hand to show it on cue. Pending → 0. |
| 5. Stale website | Sell the last aquarium kit in store; the website still shows 1, so it goes in the bag; checkout blocks it before payment; `rpt_checkout_blocked` | `sale S05 P018 1`, `order 2026 P018 1`, `report blocked` | The business problem in one example: the stale number let the customer get to checkout for something that no longer exists — a lost sale, recorded with the reason. |
| 6. Click & collect | `rpt_open_reservations`: seed order 5 has 2 items in transit, order 3 is overdue. Receive and collect order 5; run the overdue job (cancels order 3); collect order 9 | `report reservations`, `receive 5`, `collect 5`, `cancel-overdue`, `collect 9` | Lines move held → in transit → arrived → collected. Uncollected orders are cancelled after 3 days and the stock goes back on the shelf, which the website only learns at the next sync. |
| 7. Data quality | New item P019 delivered and sold; `etl.v_data_quality` shows 2 rows rejected as "Unknown item P019"; reconciliation gap; `etl.add_item('P019')`; `run_etl()` loads them | `supplier-delivery S01 P019 2`, `sale S01 P019 1`, `report reconciliation`, `add-item P019`, `etl` | An item the warehouse does not know is rejected, never guessed; the store keeps trading; the gap is visible; once the data steward adds the item to the product list the waiting rows load. `etl_run` is the audit log. |
| 8. Reports + final sync | Reports 1–6; final `online.sync_website_stock()` | `report all`, `sync` | Six reports from the warehouse; finish with the website correct again. |

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
- [ ] Automatic sync not running before step A1 (step A0 shows "stopped" or "never started"); started only for the optional step A5.
- [ ] Font size large enough to read result grids.
- [ ] Show the check runs (`check_demo.py`, `check_scheduler.py`, `check_dashboard.py`) final lines at the start or end.
- [ ] Upload to YouTube/GitHub and put the link in the report (section vi.e).
