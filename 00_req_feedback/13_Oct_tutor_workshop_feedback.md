# Class Transcripts – 13 Oct 2026

Notes: Speaker labels (Teacher / Student) are inferred from context. [?] = uncertain word, [inaudible] = could not be made out. Timestamps are from the original recordings.

---

## Recording 1 (≈5 min) – Presentation time slots & format

**[00:00] Teacher:** …each one of you will be presenting, and I will be asking a question to each one of you. So if there are five people, all five will be presenting, and all questions will be directed to all five. All right? So we will start from 7 to 7:15. If it gets extended, it will be 7:20.

**[00:22] Teacher:** Then same like that. So these are your time slots. I will ask if anyone has a preference for any of the time slots, and then I will put the group number. If not, I will just randomly select.

**[00:38] Teacher:** Does anyone want to have a preferred time slot?

**[00:45] Teacher:** These are the time slots.

*[01:01 – 01:24] Students choosing time slots – mostly inaudible.*

**[01:24] Teacher:** So these are your time slots. Remember it, take a photo, whatever is easy. But what happens is, sharp at 7, I want your slides to be up and running. You are going to present, remember that, right? So you have to bring your computer. Make sure your computer – whoever is sharing – is working. You can come early and check these adapters, if it's working. If not, have your own adapter cable as well.

**[01:53] Teacher:** I don't know if it would work for you, but make sure that it's working. So try working it out that way.

**[02:03] Teacher:** So for example, if one group is from 7 to 7:15, they will be in that particular time slot.

**[02:13] Teacher:** Try to come a bit earlier, but you don't have to stay for the whole duration. If you are done, you can leave, or if you want to stay, that's fine as well. That's an option.

**[02:28] Teacher:** I'll do the attendance while you're presenting. So that five-minute slot, like 15 to 20, might be for attendance – or I'll do it. So don't worry about that as well. Any questions?

*[02:47 – 03:30] Student question, partly inaudible – asking whether they need to bring student IDs to prove who they are on the day. [inaudible]*

**[03:32] Teacher:** Let's also do the meeting minutes. This will be your last meeting minutes. Have it ready so that I can just sign it off. [inaudible]

**[03:47] Teacher:** One very important thing for your presentation.

**[03:54] Teacher:** For your presentation, do not create multiple slides. Create three or four PowerPoint slides. What I am looking for is: start with your introduction of your business problem, how you are solving that business problem, what is the architecture that you have built, and then go to your working prototype. So the video that you created for submitting in your Assignment 2 – play that video sped up, but explain: okay, this is how we put in the data, how we transformed it, what reports and dashboards we have created, and the learnings at the end. So do not go too detailed, because you only have 10 minutes. Time yourself. Practise multiple times, but make sure it doesn't go beyond 10 minutes, because there's negative marking as well if you go beyond 10. So be careful with that.

---

## Recording 2 – from 16:12 (teacher consultation)

*[15:40 – 16:10] Before the teacher joins – unclear background talk.*

**[16:12] Student:** What we did is, first of all, we changed…

**[16:20] Student:** So what we did is we changed the names, because it was confusing last time – online, offline. So you made us do it as in-store, online, and then supplier delivery. We changed that. We reduced the sync time from 30 minutes to 3 minutes. And that's kind of it. And we've just…

**[16:41] Teacher:** Oh, okay, yeah. Instead of saying "shorten the web syncing", I would say "shorten extracting the data" – that should be from 30 minutes to 3 minutes.

**Student:** Okay, I'll change that.

**Teacher:** Because "sync" and "web syncing" mean completely different things.

**Student:** So I guess there are a lot of places we'll have to change that word then.

**Teacher:** Because you almost use "sync" everywhere.

**[17:09] Student:** And then, that's kind of it. So we've built the prototype now, we're done with it. Everything works – sync works. We added a couple of extra options, like cancelling orders and all that. And yeah, we've finished the first draft; the video script's ready. Mostly everything's done.

*[17:31 – 18:05] Pause / unclear.*

**[18:05] Teacher:** Any questions for me?

**Student 2:** I have questions.

**[18:11] Student 2:** Okay, sure. So initially we stated the business problem as: product stock is not updated between the in-store system and the online system. So we came up with the solution using sync, and…

**[18:32] Student 2:** …shorten the extract time to – five minutes, from…

**Student:** Three minutes. That's three minutes.

**[18:43] Student:** Yeah, we reduced it from 30 to 3, yeah.

**[18:51] Student 2:** …and a function to do the [stock] block before the customer actually checks out. But after these two parts, we realised that what we learn in this subject is more like the architecture of the database – like ETL, data transformation in the data warehouse.

**[19:13] Student 2:** So now my question is: for the presentation or the recording, to show the end-to-end data pipeline, should we just focus more on the data transformation and ETL part, instead of the sync and checkout block?

**[19:33] Student 2:** Because apart from the coding – I see these two parts are resolved by the Python function, but these [subject topics] are more like data technology and data models.

**[19:48] Teacher:** So there are two different things. One is your prototype and one is your presentation. For your prototype, you are actually showing us the code. So how was the data being ingested, like the ETL process, and how it was making sense of it – so extraction, transformation, cleaning the data, making sense of the data, creating reports and dashboards. That's your prototype.

**[20:11] Teacher:** Just very quickly, before you show that coding part, you should tell what your business problem was. And that business problem is like, "Oh, we are going to resolve this issue." You don't have to go through the architecture side, because that part is already in your document – in Assignment 2 you're already talking about your solution. The working prototype is all about your coding and the technologies that you have used.

**[20:37] Teacher:** For your presentation, assume that I don't have your document, so you have to show each and everything, end to end: your problem, your solution, your architecture, your working prototype, your reports and dashboards, and any limitations as well…

**[20:58] Teacher:** …or learnings.

**Student 2:** Yes. So the presentation will be more like the summary of the report?

**Teacher:** Yes.

**Student 2:** …and of the prototype. Yeah. And I have another question. We are thinking about what the use case for the dashboard is. So I [came up]…

**[21:22] Student 2:** …with four questions, and I gave them some business stories. Like: a store manager at the Parramatta store – he or she wants to see if the stock is available or reserved. Is this like the use case?

**Teacher:** Yes, okay.

**[21:44] Student 2:** So it's who wants to see what kind of information, and we use the dashboard to show them?

**Teacher:** Yes, okay. So that will be your role.

**Student 2:** Yes. Do we need to focus on one role, or different ones?

**Teacher:** All of them – you should have three dashboards in the report, right? So are you doing it for only one person? See, it goes back again to what your business problem was. Who are you trying to resolve it for? So if it's a stock issue, who is going to get impacted the most?

**[22:14] Student 2:** Ah, so the inventory manager?

**Teacher:** [unclear] doesn't care, but yeah, sure. The person who owns it – owns the company, right?

**Student 2:** Yeah.

**Teacher:** But – or basically the person who gets affected the most. And then you have to choose who's getting affected by that.

**[22:36] Teacher:** So high, medium, low, you can say – like who's being affected, what is the impact of the decision that you're trying to make, who has the most say in it. So you have to create your solution… It's never for one particular person, because in theory everyone gets the benefit of it. But who is the main person who's going to say yes or no to that solution?

**[23:07] Student 2:** Yeah. That's all my questions. Thank you.

**[23:10] Teacher:** Thank you.
