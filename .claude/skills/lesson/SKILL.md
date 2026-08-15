---
name: lesson
description: Write and publish a new "Thrifty Crew" financial lesson to the Ghost site, following every established convention (voice, structure, SEO, paywall schema, tagging, topic-hub linking) so it fits the existing lessons exactly. New lessons get a NORMAL title (the Week 1-52 program is a closed, separate series). Invoke when Brad wants to add a lesson; he supplies the topic + key points, the skill drafts, gets approval, and publishes.
---

# Lesson — Thrifty Crew

Publish a new financial lesson so it fits the existing lessons **exactly**. Brad gives the topic and key points; you draft the lesson, get his approval, then publish and wire it in.

**Naming rule:** new lessons get a **normal title** (e.g. "How to Read a Pay Stub") — **not** "Week N." The **Week 1–52 program is a closed, finished series**; never add new "Week N" lessons to it. (To *edit* an existing week, see the legacy note in the cheat-sheet.)

## The one thing that makes everything "fit"

The site's **global Code Injection** automatically adds to **any post tagged `financial-lessons`**: the top-of-post financial disclaimer, the "Keep going" internal-link block, the breadcrumb JSON-LD, the 620px reading measure, the active-nav highlight, AND a keyword-matched **"Put it into practice" card** that links the single most relevant free tool (it reads the lesson's title + text and picks Where Do You Stand?, the Compound Interest Calculator, Budget Tracker, etc.). **So you never rebuild those per lesson**, and you don't hand-add the tool link. Tag it right and set the fields, and the styling + on-page SEO fit happens on its own. Do **not** touch the site Code Injection for a normal lesson.

Full background on why each piece exists: memory **[[ghost-migration]]**. The site is **LIVE** (public, indexed) at `www.thriftycrew.com`.

---

## Step 1 — Get the real substance (never fabricate) [[book-method-keep-asking]]

Ask Brad and keep asking until you can write it truthfully:
- The **topic / title** (a normal title — no "Week N"), and whether it's **paid** (default) or **free**.
- The **ONE big idea** (the single takeaway).
- Any **real examples, numbers, scripts, or stories** he wants in it. Do **not** invent his specifics.

## Step 2 — Write the lesson to spec

**Read memory [[brand-voice-brad]] first (THE voice) and `C:\Codex\ThriftyCrew\STYLE-GUIDE.md` (structure + hard rules).** Apply these **OVERRIDES** to the style guide (it is partly stale):
- Pricing is **$1/month or $10/year** (ignore the old "$5/mo").
- The reader may be doing this **for themselves OR to teach a young person**. Write so both land.
- **Always include the "For yourself:" question block** (added to every lesson in this project).
- **No "Week N" framing.** The lesson stands on its own.

**Voice: write as BRAD. Non-negotiable.** Match memory **[[brand-voice-brad]]** exactly. In short: a mix of **Morgan Freeman and Dave Ramsey** (calm, warm, steady, but tells the truth straight). **Analytical and data-first**: lead with a question or a real, 100%-accurate number, and never hand-wave a stat (Brad is analytical and vague claims read as fake). Warm and encouraging by default, balanced with objectivity and no-BS. Jokes now and then, never swears, mild vulnerability is welcome. Folksy and plain, never corporate or salesy. Short sentences. Concrete over abstract (real numbers, real scripts). ~**900-1,300 words** of teaching. Read it aloud before you publish; if it sounds like a press release or a term paper, rewrite it.

**Punctuation rule (HARD): no em dashes, anywhere.** They read as obviously AI and Brad hates them (memory [[writing-no-em-dashes]]). Use periods and commas instead, and split a sentence rather than joining it with a dash. Go easy on semicolons and exclamation points too.

**Hard rules (do NOT break):** no addiction / jail / recovery / DUIs / AA anywhere in the lesson; when money or investing comes up, include a light "this isn't financial advice, so check with a professional" caveat; values-based, not faith-based; age-appropriate; don't retell Brad's life story. Weave the motifs naturally: Future You, compounding/"stacking", the gap, needs-first-then-wants, value-first, reputation-travels, time-is-the-superpower, want-less-win-more, borrow-hindsight, celebrate-small-wins, pay-a-little-now-or-a-lot-later.

**Exact skeleton** (the `# <Title>` line is the POST TITLE, not part of the body):
```
# <Title>

*<one-line italic hook / promise of the lesson>*

**The big idea:** <1–2 plain sentences: the single core takeaway.>

## <Section heading 1>
<teaching content>

## <Section heading 2>
<teaching content>
(3–5 short sections total)

## Try this together
<A concrete, low-friction activity to do now — a script, a 15-minute exercise, a small challenge. Not vague.>

## Questions to sit with
**For yourself:**
- <3 self-directed reflection questions (for a solo adult)>

**For you (the parent):**
- <1–3 reflective questions for the parent>

**For your kid (ask them, or do it together):**
- <2–4 questions tuned to this lesson>
```

Save the source to **`C:\Codex\ThriftyCrew\lessons\<slug>.md`**. Then **show Brad the draft and iterate until he approves.**

## Step 2.5 — SEO pass (do this every time, before publishing)

The tag already handles the *mechanical* SEO (structured data, breadcrumb, paywall schema, mobile, speed, the Keep-going links). This step adds the *strategic* on-page SEO that actually wins search — it is NOT optional:

1. **Find the search phrases.** Name the ONE primary phrase a real person would type, plus 2–3 secondary ones. Reason it out; optionally WebSearch to sanity-check the wording people actually use. (e.g. topic "saving on vacations" → primary `how to save money on vacation`; secondary `when to book flights for the best price`, `hotel dynamic pricing`.)
2. **Keyword-led title tag + slug — separate from the display title.** Brad's display H1 stays creative/voicey. But the **MetaTitle** must LEAD with the primary phrase then the brand (under ~60 chars), and the **Slug** IS the primary phrase, short. Never derive either from a long creative title.
3. **Put the primary phrase in the first paragraph and at least one H2** — naturally, never stuffed. The words a searcher types should actually appear in the lesson; keep the voice, just make the vocabulary overlap.
4. **Answer the obvious question directly (featured-snippet bait).** If the topic has a clear "when / how much / how many / what" (e.g. *when to book flights*), give a crisp one-sentence or tight-list answer Google can lift verbatim.
5. **1–3 in-body internal links** to relevant existing lessons (beyond the auto Keep-going block) — deepens topical authority and crawl paths. Use real slugs and verify them.
6. **(Optional, strong for question-topics) Add an FAQ block.** If people search the topic as questions ("what is X", "how much Y"), end the lesson body with a small FAQ: `<div class="mts-faq"><h3>Common questions</h3><div class="mts-faq-item"><strong>Question?</strong><span>Short, accurate answer.</span></div> ...</div>`. The global injection turns that markup into **FAQPage structured data automatically** (snippet-eligible) and it adds rankable long-tail content. 2-4 Q&As, answers tight and 100% accurate.
7. Carry all of this into the Step 3 fields (MetaTitle, Slug, MetaDesc). That is where the SEO pass gets applied.

## Step 3 — Produce the HTML body & publish

1. Convert the approved lesson **body** (everything below the `# <Title>` line) to clean semantic HTML — `<p>`, `<strong>`, `<em>`, `<h2>`, `<ul><li>`, `<hr>`. No wrapper `<div>`, no inline styles, no `<h1>`. Render the "For yourself/parent/kid" labels as `<p><strong>For yourself:</strong></p>` above each `<ul>`. Save to a temp file, e.g. the session scratchpad `lesson-body.html`.
2. Decide the fields:
   - **Title (display H1):** Brad's normal title — can be creative/voicey. No "Week N".
   - **Slug:** the PRIMARY search phrase, short (from Step 2.5) — e.g. `save-money-on-vacation`, NOT a kebab of a long creative title. Prefix `free-` for a free lesson.
   - **Excerpt** (one-line hook that works solo OR when teaching a young person).
   - **MetaTitle:** KEYWORD-LED — primary phrase first, then ` | Thrifty Crew`, under ~60 chars (from Step 2.5). NOT just "{display title} | Thrifty Crew".
   - **MetaDesc:** front-load the primary phrase, add the benefit + a soft nudge, ~150 chars.
   - **Visibility:** `paid` (default). Only an explicitly-free lesson uses `public`.
3. Publish (a standalone lesson publishes at the current time — the latest entry in the Financial Lessons archive):
```
powershell -ExecutionPolicy Bypass -File "C:\Codex\ThriftyCrew\.claude\skills\lesson\publish-lesson.ps1" `
  -Title "How to Read a Pay Stub" -Slug "how-to-read-a-pay-stub" `
  -HtmlFile "<scratchpad>\lesson-body.html" `
  -Excerpt "One-line hook." `
  -MetaTitle "How to Read a Pay Stub | Thrifty Crew" `
  -MetaDesc "Benefit-led ~150-char description."
```
The script sets tag = `financial-lessons`, visibility, all meta/og/twitter fields, and the **paywall JSON-LD** (for gated lessons). It **upserts by slug** (safe to re-run). Add `-Draft` to stage for review; add `-Visibility public` for a free lesson. **It never emails members** — only send a new-lesson email if Brad explicitly asks, and confirm before doing so.

## Step 4 — Add it to the topic hub

Open `C:\Codex\ThriftyCrew\.claude\skills\lesson\build-hubs.ps1`, add the new lesson's **slug** to the matching hub's `lessons` array — hubs: `money-mindset-and-habits`, `budgeting-and-spending`, `saving-and-banking`, `earning-and-first-jobs`, `investing-basics`, `debt-and-credit` — then run it:
```
powershell -ExecutionPolicy Bypass -File "C:\Codex\ThriftyCrew\.claude\skills\lesson\build-hubs.ps1"
```
(It rebuilds the hub pages idempotently.)

## Step 5 — Verify live

Load `https://map-to-success.ghost.io/<slug>/?v=check` and confirm:
- the **financial disclaimer** banner is at the top,
- the **"Keep going"** block is at the end,
- the `<head>` has both the **breadcrumb** and the **paywall** JSON-LD,
- the browser tab **`<title>`** is the MetaTitle,
- and it appears at the top of `/financial-lessons/?v=check` (newest).

If anything is off, fix the field and re-run the publish script (it upserts). (Also spot-check the live URL on the custom domain `www.thriftycrew.com/<slug>/`.)

## Step 6 — Search visibility (the site is live and indexed)

The site is verified in **Google Search Console AND Bing Webmaster Tools** under `admin@thriftycrew.com` (memory [[google-search-console]]). The **sitemap auto-updates** the moment you publish (Ghost regenerates `/sitemap.xml`), so a new lesson is discoverable on its own. Nothing per-post is required. Two optional nudges for a lesson you want ranking fast:
- In **Google Search Console** -> URL Inspection -> paste the new URL -> **Request indexing** (jumps the crawl queue).
- Site-verification lives in a `google-site-verification` meta tag inside the site Code Injection. **Never strip it** when editing the injection.

---

## Cheat-sheet / gotchas
- **#1 rule: tag it `financial-lessons`** — that single tag drives the disclaimer, Keep-going links, breadcrumb, reading measure, and nav highlight.
- **Design is INHERITED, not built per-lesson.** The tag + global injection give every lesson the same serif headings, 620px reading measure, disclaimer, and Keep-going block — automatically consistent with the other 52. Do NOT add per-lesson visual flourishes (pull-quotes, callout boxes, colored panels); they'd make the lesson look *different* from the rest, which is the one thing this skill exists to prevent. "Design" here = clean semantic HTML + the fixed structure (hook → big idea → 3-5 H2 sections → Try this together → Questions). (Making ALL lessons richer visually is a separate project: new template + retrofit the existing ones.)
- **The Week 1–52 program is a CLOSED series** — new lessons are standalone with normal titles. To *edit* an existing week (rare), pass `-WeekNumber N` (keeps its archive slot) and keep its `Week N — …` title; never create new "Week N" lessons.
- Credentials + site URL live in **`ghost-config.ps1`**. On a custom-domain move, update `$apiUrl` there (the key is unchanged).
- Meta/OG/paywall are all handled by `publish-lesson.ps1` — don't set them by hand.
- Lessons have **no feature image**; they inherit the branded default og:image automatically.
- PowerShell 5.1 reads `.ps1` as ANSI, so keep the `.ps1` helper scripts ASCII (use `&rarr;` for arrows, etc.). Lesson HTML you pass via `-HtmlFile` is read as UTF-8. **But use NO em dashes in the lesson at all** (Brad's rule, memory [[writing-no-em-dashes]]); write with periods and commas.
- For a **meal-prep recipe** (not a lesson) the conventions differ (Recipe JSON-LD, cost-per-serving stats bar, `meal-prep` tag). See memory [[meal-prep-recipe-template]]; this skill is for financial lessons.
- **Voice + SEO + search-console are all baked in now.** The three memories that govern any creation: **[[brand-voice-brad]]** (write as Brad), **[[writing-no-em-dashes]]** (no em dashes), **[[google-search-console]]** (indexing). Read [[brand-voice-brad]] every time before drafting.
