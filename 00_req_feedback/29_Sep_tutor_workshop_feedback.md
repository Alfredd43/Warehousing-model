# Tutor Feedback – Assignment 2 Business Case

2026-09-29

## TL;DR

The tutor said our current business case is off track. We need to refocus on one clear problem: **real-time product inventory sync between in-store and online sales**.

- Our three "data sources" (POS, digital, grooming) mix up a sales channel, a machine and a service, so they don't work as sources.
- The "duplicate customer accounts" problem was rejected. One membership works both in store and online at real retailers.
- Two data sources (in-store and online) are acceptable at this stage, even though the brief says three.
- Drop buzzwords like "omnichannel" unless we can explain exactly what they mean for our case.

## Key feedback from the tutor

1. **Our terminology is wrong.** The same issue was flagged in our Assignment 1.
    - POS is a till machine used to make a sale. It is digital and online, not manual or offline.
    - If a POS were offline, sales would sit in the till and never update the database.
    - "Digital" is a form of transaction, not a source.
    - Grooming is a service, not a system and not a sales channel.
2. **Separate how something is sold from what is sold.** Sales channels are *in store* or *online*. Grooming, pet food and pet toys are things the shop offers. A grooming booking is still paid through the till or online. The tutor used David Jones as the example: many services and products, two ways to buy.
3. **Duplicate customer accounts are not a real business problem.** One membership works online and in store (David Jones, Woolworths Rewards). If a customer chooses to buy in store instead of waiting for a subscription delivery, that's their choice, not a system flaw. Customers having several accounts is also not the store's issue to fix.
4. **The real problem is product inventory.** We discussed this with the tutor earlier, but it never made it into our report. When one customer buys in store while another buys online at the same time, stock may not update in real time.
5. **Understand the business case before writing it.** No fancy words for their own sake. The tutor is happy to help, but expects us to understand our own question first.

## Where we disagreed

The tutor rejected every point we pushed back on. Recording timestamps are included so anyone can re-listen.

| Time | What we argued | Tutor's response |
| --- | --- | --- |
| 00:43 | POS is manual/offline and needs separate upkeep | POS is online; offline would mean sales never reach the database |
| 02:07 | POS, online shopping and grooming are three separate digital systems | Grooming is a service, not a system |
| 02:39 | Grooming collects customer data (owner and pet names) | Online sales collect the same data; that's not a separate source |
| 02:57 | Sales and service are the same thing in retail | No. Service is what's offered; in store or online is how it's sold |
| 07:00 | Online and in-store accounts aren't merged, so a subscription ships when it isn't needed | One membership covers both channels; buying in store is the customer's choice |
| 08:38 | Retailers only share one account because they fixed this problem | This doesn't happen anywhere |
| 09:30 | We're late; could we email a new idea and get feedback instead | Feedback isn't a waste of time. Use it and work on inventory |
| 12:03 | The brief asks for three data sources | Work on two for now, but understand the business case clearly |

## Revised direction

**Problem statement:** product inventory does not update in real time across the pet store's in-store and online sales. Stock sold in one channel can still show as available in the other.

| Data source | What it records |
| --- | --- |
| In-store sales (POS till) | Products sold at the counter, quantities, time of sale |
| Online sales (website) | Products ordered online, quantities, time of order |

- Scope is **inventory of products** only: pet food, toys and so on. Not customer records, not grooming.
- Grooming can stay as one of the shop's offerings, but it is not a data source or the problem.

## Next steps

- [ ] Rewrite the business case around real-time product inventory sync
- [ ] Replace "POS / digital / grooming" with two sources: in-store sales and online sales
- [ ] Remove the duplicate-account and subscription example
- [ ] Go through the report and cut jargon ("omnichannel", "fragmented", etc.) we can't explain in plain words
- [ ] Recheck the Assignment 1 terminology feedback so we don't repeat it
- [ ] Split the work and agree on owners (still open: one teammate said after the meeting they weren't sure what the final conclusion was)
- [ ] Prepare specific questions before asking the tutor again

## About the recording

This summary comes from an auto-separated transcript of the roughly 13-minute consultation. Students' voices were not told apart, and a few lines were inaudible, including one teammate's name. Re-listen at the timestamps above if a point matters.
