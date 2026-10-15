# PetHaven presentation runbook

How Group 3 presents Assignment 2 in the workshop: 3 to 4 slides, then the recorded end-to-end test video played sped up, then questions. The video itself is scripted in [video_demo_script.sql](video_demo_script.sql).

## 1. Rules for the presentation

From the brief and the tutor (6 and 13 Oct):

| Rule | Source |
| --- | --- |
| **10 minutes at most.** Going over is marked down. Time every rehearsal. | Tutor, 13 Oct |
| **3 or 4 slides only:** business problem, solution, architecture, then the working prototype (the video), and learnings at the end. Do not go into detail. | Tutor, 13 Oct |
| **Assume the tutor has not read the report.** Tell it end to end: problem, solution, architecture, prototype, reports and dashboard, limitations or learnings. | Tutor, 13 Oct |
| **No queries written live.** Play the recorded video, sped up, and explain over it how the data goes in, how it is transformed, and what the reports and dashboard show. | Tutor, 6 and 13 Oct |
| **Every member presents,** and the tutor asks each member a question. Anyone must be able to answer about any part. | Brief; tutor, 13 Oct |
| About 10 minutes of questions follow. | Brief |
| Slides open and running at the start of the slot. Bring your own laptop and adapter; arrive early to test the screen. | Tutor, 13 Oct |
| Bring the last meeting minutes ready for the tutor to sign. | Tutor, 13 Oct |

## 2. Running order (about 9:30)

| # | Part | Content | Time | Speaker |
| --- | --- | --- | ---: | --- |
| 1 | Slide 1: Business problem | PetHaven, the three systems, the problem statement, one example | 1:00 | Member 1 |
| 2 | Slide 2: Solution | The three parts of the solution and the gap the warehouse measures | 1:00 | Member 2 |
| 3 | Slide 3: Architecture | Sources → ETL → data warehouse → reports and dashboard; the data use cases | 1:30 | Member 3 |
| 4 | Video, sped up | The recorded end-to-end test, explained over the top | 5:00 | Members 4 and 5 |
| 5 | Slide 4: Learnings and limitations | What we learned, what the prototype does not do | 1:00 | Member 1 or 2 |

Fill in the speaker names once the group agrees. If the group has more or fewer members, split the video between two speakers and give each slide to one person.

## 3. Slide content

### Slide 1: Business problem

- PetHaven: a fictional Sydney pet-supplies retailer, five stores and a website. Customers buy in a store, or order online and collect from a store they choose. Suppliers deliver to each store in cartons.
- Three separate systems: store, supplier and online.
- **Problem statement:** product stock is not updated in real time between in-store and online sales, so stock sold in one channel can still show as available in the other.
- The website shows one combined number per product, and before this project it was updated once a day. Example: the last aquarium kits sell in store, the website still shows 2, and a customer only finds out at checkout.
- Each system records stock in its own way (transaction IDs, store codes, cartons, UTC), so nobody could measure how wrong the website was.

### Slide 2: Solution

| Part | What it does | Layer |
| --- | --- | --- |
| 1. Shorter data extraction | The website extracts real store stock every 3 minutes instead of once a day, plus a manual "refresh now" | Operational |
| 2. Real-stock check at checkout | Checked before payment; a checkout that cannot be supplied is blocked and nothing is charged | Operational |
| 3. ETL, data warehouse and dashboard | Integrates the three systems and measures the gap that parts 1 and 2 leave: how wrong the website still is, and which checkouts were blocked | Analytical |

### Slide 3: Architecture

- Diagram: Store, Supplier, Online → ETL (staging → validate → transform → load) → star schema (`fact_stock_event` with product, store and date dimensions) → report views → dashboard. Use Figure 1 from the report.
- One line each: same item number in every system; each system keeps its own transaction ID (`source_ref`); store codes mapped only through approved mappings; cartons → units, UTC → Sydney time.
- The four data use cases, by impact: UC1 business impact (sales and potential lost sales) and UC2 website stock (owner, high), UC3 low stock (store managers, medium), UC4 click & collect orders (store staff, low).

### Slide 4: Learnings and limitations

Learnings:

- Get the business case and the words right first: in-store, online and supplier; a sale channel is not a system.
- A shared item number plus each system's own transaction ID makes every warehouse number traceable to its source record.
- The operational fixes make the problem smaller; the warehouse is what measures what is left.
- Rejecting unknown records with a reason, instead of guessing, keeps the stock figures trustworthy.

Limitations:

- The website can still be up to 3 minutes out of date.
- All systems share one PostgreSQL database, and the ETL runs inside each source transaction (about 5 ms per sale).
- Prices are type 1 (history not kept); each item comes from one store; the scheduler and the overdue cancellation are started by hand.

## 4. Playing the video

Skip the video's opening (slides 1 and 2 already cover it) and play the rest at about 1.75× speed, which takes about 5 minutes. Pause or slow down only if a speaker needs more time on a result.

| Video section | What to say over it |
| --- | --- |
| 1-2 Baseline and test inputs | One event in each source system: a supplier delivery in cartons, two in-store sales, an online checkout that is blocked because the website still shows 2. |
| 3 ETL | How the data goes in: triggers copy each record to staging unchanged; the transform converts 5 cartons to 20 units, UTC to Sydney time, NSW-CHATS to S03; the ETL runs straight after every change. |
| 4 Warehouse | Events from all three systems in one fact table, each with its source reference. |
| 5 Reports and dashboard | UC1 (Overview): sales in the last 7 days and the blocked checkout, nobody charged. UC2 (Website stock): too high for P018, too low for P001; the manual refresh corrects both, and the refresh history shows what each refresh found. UC3 (Store stock): low-stock stores; Chatswood now has 73. UC4 (Click & collect orders): one overdue order, one waiting for a transfer. |
| 6 Traceability | One dashboard row traced back to the source checkout record. |
| 7 Validation | P019 is not on the product list: both records are rejected with a reason, then load once after the data steward approves it. |
| 8 Result | T1-T11 all PASS. |

## 5. Before the presentation

- [ ] Video exported, saved on the presenting laptop (not only online), and tested at 1.75×.
- [ ] Slides finished and timed with the video: under 10 minutes in two rehearsals in a row.
- [ ] Speaker names filled in above; every member has read the question list below.
- [ ] Laptop charged, adapter packed, last meeting minutes printed for signing.

## 6. Questions to prepare

Each member should be able to answer all of these.

| Question | Short answer |
| --- | --- |
| Why 3 minutes and not every sale? | Refreshing on every sale ties the three systems together and adds load to every till transaction. The checkout check already protects the moment the customer pays. The interval is one setting (`SYNC_INTERVAL_SECONDS`). |
| Does the warehouse change the website number or block checkouts? | No. The online system does both. The warehouse integrates the records and measures the gap. |
| What is the grain of the fact table? | One stock change for one product at one store, from any of the three systems. |
| Why one stock-event fact table? | Current stock is the sum of the signed changes, so the same rows give current stock, history and an audit trail. |
| What happens to a record for an unknown item or store? | It is rejected with a reason and stays in staging; the sale itself still goes through. It loads once a data steward approves the item. Nothing is matched by name. |
| Available vs reserved? | Available is the shelf. Reserved units were already taken off the shelf, so available is never shelf − reserved. |
| Why can a checkout be blocked? | Two reasons: the website number was out of date, or there was enough stock in total but no single store had the whole quantity. |
| Who uses the dashboard and why is the owner high impact? | Owner, store managers, store staff. The owner loses the sales and decides whether to keep the solution. |
| How did you test it? | 105 behaviour checks, 17 scheduler checks, 45 dashboard checks, and the recorded end-to-end test ending in T1-T11 PASS. |
| What would a production version change? | Separate databases, asynchronous change capture, a managed scheduler, type 2 price history. |
