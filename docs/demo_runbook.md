# PetHaven prototype: demonstration runbook

Step-by-step script for the live presentation and the recorded end-to-end video (brief item vi.e). Everything runs in the provided Lab Environment. Two equivalent ways to drive it:

- **CloudBeaver (recommended for the video):** run [`workspace/demo/cloudbeaver_demo.sql`](../workspace/demo/cloudbeaver_demo.sql) one statement at a time. The steps below match its numbered sections.
- **Terminal:** the `demo.py` commands shown next to each step (prefix: `docker compose exec python python /workspace/scripts/demo.py`).

Target length: about 10 minutes, as the brief allows a 10–15 minute presentation.

## Before the demo (once)

1. Start Docker Desktop, then from the repository root: `docker compose up -d`.
2. Run the checks; the last line must be `TOTAL: 95 checks - PASS 95, FAIL 0`:

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
| 0:00 | Problem | – | – | Website shows one combined number per product for 5 stores, refreshed only when a sync runs. Store sales and deliveries happen in other systems, so between syncs the website is wrong: customers add items that no store can supply and only find out at checkout. |
| 1:00 | 0. Three systems | `etl.v_store_codes`, `etl.v_product_codes`, the same dog food in each system | `codes` | Three sources with their own codes, units (cartons) and time zone (UTC). The warehouse maps them through approved cross-references to one conformed code. Starting point: in sync, nothing pending, 90/90 reconcile. |
| 2:00 | 1. In-store sale | 3-item receipt at Parramatta; shelf drops; staging rows in store codes; 3 facts in warehouse codes; website unchanged | `sale S01 P003 2 P005 1 P009 1` | Sale is instant in the store system. The ETL extracted it, mapped codes and loaded 3 events in the same transaction — but the website still shows the old numbers. |
| 3:00 | 2. Delivery | 5 cartons to Chatswood; staging (cartons, UTC) vs fact (20 units, Sydney time) | `delivery S03 P001 5` | Transformation: cartons → units, UTC → Sydney business date. |
| 4:00 | 3. Bag, pickup options, checkout | One-item order paid and held at Bondi, website −2 at once. Then a bag with duck, aquarium kit and 2 dog beds: checkout **blocked before payment** (no single store has 2 beds), nothing held. Remove the beds; pickup options show Newtown (both items) and Bondi (duck only, kit transferred). Choose Bondi: paid; duck from Bondi, kit from Newtown. Dispatch the kit (in transit; collect refused), receive it (ready) | `order 2026 P001 2`, `order 2026 P009 1 P018 1 P013 2`, `remove 10 P013`, `options 10`, `checkout 10 --pickup S02`, `dispatch 9`, `collect 9`, `receive 9` | Checkout checks real stock before taking payment, so nobody is charged for something that can't be supplied. The customer chooses from the stores that hold their items; anything the chosen store lacks is transferred in. |
| 5:00 | 4. Staleness → sync | `rpt_online_staleness`, `rpt_online_vs_actual` (before); `online.sync_website_stock()`; `sync_run`; `rpt_last_sync_changes` (after) | `report staleness`, `online`, `sync` | Events pending and which numbers are wrong. The sync copies the real shelf totals from the store system to the website; the warehouse records every before/after for the reports. Pending → 0. |
| 6:30 | 5. Stale website | Sell the last aquarium kit in store; the website still shows 1, so it goes in the bag; checkout blocks it before payment; `rpt_checkout_blocked` | `sale S05 P018 1`, `order 2026 P018 1`, `report blocked` | The business problem in one example: the stale number let the customer get to checkout for something that no longer exists — a lost sale, recorded with the reason. |
| 7:30 | 6. Click & collect | `rpt_open_reservations`: seed order 5 has 2 items in transit, order 3 is overdue. Receive and collect order 5; run the overdue job (cancels order 3); collect order 9 | `report reservations`, `receive 5`, `collect 5`, `cancel-overdue`, `collect 9` | Lines move held → in transit → arrived → collected. Uncollected orders are cancelled after 3 days and the stock goes back on the shelf, which the website only learns at the next sync. |
| 8:30 | 7. Data quality | New product P019 delivered and sold; `etl.v_data_quality` shows 2 rejected rows with reasons; reconciliation gap; approve mappings; `run_etl()` loads them | `delivery S01 PP-CAT-TUNNEL 2`, `sale S01 9300601001194 1`, `report reconciliation`, `approve SUPPLY PP-CAT-TUNNEL P019`, `approve STORE 9300601001194 P019`, `etl` | Unknown codes are rejected, never guessed; the store keeps trading; the gap is visible; once approved the waiting rows load. `etl_run` is the audit log. |
| 9:30 | 8. Reports + final sync | Reports 1–6; final `online.sync_website_stock()` | `report all`, `sync` | Six reports from the warehouse; finish with the website correct again. |

## Questions to be ready for

| Question | Short answer | Where |
| --- | --- | --- |
| Why is the warehouse updated instantly if it is a separate system? | The ETL is change-data-capture plus a micro-batch load, run inside the source transaction, so the warehouse can never be behind or disagree. In production this would be asynchronous log-based CDC. | Arch 5.4, 11 |
| Why not match products by barcode or name? | Names differ by design; codes are matched only through an approved cross-reference so a wrong match can never corrupt stock. Unmatched rows wait in staging. | Arch 5.2–5.3 |
| What is the grain of the fact table? | One stock change for one product at one store. Current stock = sum of signed measures. | Arch 6.2 |
| Isn't a data warehouse for analysis, not operations? | Yes, and that is how it is used. The website number comes straight from the store system (like checkout does); the warehouse only records each sync and reports how stale the website was. | Arch 7, 10 |
| How do you know the warehouse is right? | Every sync reconciles all store/product pairs with the store system (`store_mismatches`, `rpt_reconciliation`), and 95 automated checks pass. | Arch 7, implementation_notes |
| What if the closest store doesn't have everything? | The customer is offered every store that holds at least one item, best first (fewest transfers). Whatever the chosen store lacks is taken from the nearest store that has it and transferred; the customer collects once everything has arrived. A store with none of the items isn't offered. | Arch 4.3, 4.5 |
| Two customers want the last one at the same time? | Bags hold nothing. Whoever checks out first gets it; the other customer's checkout is blocked and the item stays in their bag. | Arch 4.3 |
| What if no store has an item? | Checkout is blocked before payment: nothing is charged or held, the customer sees which items to remove, and can check out the rest. A paid order can therefore always be fulfilled. | Arch 4.3, Spec 5.3 |
| If checkout checks real stock, why does the sync still matter? | The product page and the bag still use the website number. When it is stale, customers add items that are gone and are let down at checkout (Report 3); when it is understated, items that are in stock can't be added at all. | Spec 2.1, 5.2 |
| Why a manual sync? | The problem is staleness; a manual trigger shows it on cue. A schedule only changes when the same function runs. | Arch 10 |

## Recording checklist

- [ ] Fresh `build.py` immediately before recording; CloudBeaver reconnected to `pethaven_demo`.
- [ ] Font size large enough to read result grids.
- [ ] Show the check run (`check_demo.py`) final line at the start or end.
- [ ] Upload to YouTube/GitHub and put the link in the report (section vi.e).
