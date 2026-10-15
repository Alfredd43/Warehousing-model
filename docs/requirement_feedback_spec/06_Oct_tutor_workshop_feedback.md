# Meeting Transcript: Prototype Check-in with Teacher (2026-10-06)

> Source: `20261006_203357.m4a` (about 5 min)
> Speaker labels were assigned from context. Lines marked `[?]` were unclear in the recording. Text in `[brackets]` was added to make the meaning clear.

---

**Teacher:** [Have you] started working on your prototype?

**Student:** Yes.

**Student:** Almost.

**Teacher:** Okay.

**Student:** So what we've done: like you said last time about the offline and online mismatch, we've made a model. We've kept three data sources. We added another one because we got one. We kept online, offline, and we've kept the supplier delivery as another data source.

So what happens now is the offline model correctly loads the data. If a purchase has been made, it automatically loads it into the offline base. But it doesn't go to the online one. There's a trigger every 30 minutes that runs an automatic sync.

**Teacher:** So what happens then? What's "offline"?

**Student:** Sorry, offline stores. I mean, like, in-store.

**Teacher:** In-store, yeah.

**Student:** An in-store transaction [isn't] loaded on the website [right away]. So the website still shows availability. If there were only 10 and someone bought five in the store, the online website still shows 10 for those 30 minutes.

**Teacher:** Because it's 30 minutes.

**Student:** Okay. I can reduce that.

**Teacher:** I think you should say five or two minutes.

**Student:** Five, two minutes?

**Teacher:** Yeah.

**Student:** Okay. So what will happen is it will still show 10. The customer will be able to add it to his bag. Let's say he adds six, but only five are available. He can add them to his bag, but it won't let him check out, because it will go back to the store and see that the items aren't available. So it gets rejected and it won't let him process a payment.

And like you said, five minutes: every five minutes it will get a new number, so it will go back to five. But if someone buys online, the online number is updated right away. So if someone buys two, five becomes three.

And we've kept three different data sources: online store, offline store, and the supplier delivery. Each one uses different codes. Online has barcodes, the offline store has a product code, and the supplier gives cartons. So they're all different. To translate all of them and get them into the dashboard, we'll be using the database.

**Teacher:** I would be careful with the words you're using. I would say **online**, **in-store**, and **supplier**.

And then I would also say, as you mentioned, that you'll have different attributes, let's say, or entities. The **item number** will be the same, because that's how we tell that it's a cup, or a pen, or whatever. That's the item number. How you tell whether it was purchased in-store or online is through your **order ID**, maybe.

**Student:** Or barcode.

**Teacher:** Or your barcode, their receipt number. They have those things. And maybe explain that with the supplier it's more about inventory, so that will be **supplier ID** and **supplier order**. So be very careful about which terms you're using.

But have you done the [setup] work? [?]

**Student:** Yeah, we even have a draft dashboard, and we've already set up the connections, so it does work.

And I have a question: when we present this project, how are we supposed to do it? Are we supposed to write each query, show you that it runs, then go back to the dashboard and show you that?

**Teacher:** Yes.

**Student:** Would it be able to [run live]? [?]

**Teacher:** So you don't write the query. You record it, and then you just play it.

**Student:** OK, I got it. So a video.

**Teacher:** So [show] the video.

**Student:** Because [writing it live] would take time. That was my question.

**Teacher:** OK. During the presentation, actually, you just need to show [the key points]. Don't say too many things. You say what your business problem is. You're telling it end to end: what the business problem is, what your solution is, what your prototype is, and how you've tested it. And then you record what's in the dashboard.

**Student:** OK. Got it.

**Student:** Will it [be]... [?]

**Teacher:** Yeah, sure.

**Student:** Will I write it too? [?]

**Teacher:** Here. Here we will. [?]

**Student:** Yeah, we will. Thank you.

**Student:** Thank you.

**Teacher:** Yeah. OK.

*(Unclear ending: "Easy... write the teaser.")* [?]

---

## Key Takeaways from the Teacher

1. **Shorten the sync interval** between in-store and online inventory from 30 minutes to about **5 (or 2) minutes**.
2. **Use consistent terms:** say *online*, *in-store*, and *supplier*. Don't say "offline."
3. **Explain the data entities clearly:**
   - **Item number** is shared across all channels and identifies the product.
   - **Order ID, barcode or receipt number** tell an online purchase from an in-store one.
   - **Supplier ID and supplier order** are for the supplier side, which is about inventory.
4. **Presentation format:** don't write queries live. **Pre-record a video** of the queries running and the dashboard, then play it.
5. **Presentation structure (end to end):** business problem, then solution, then prototype, then how you tested it, then the recorded dashboard demo. Keep it concise.
