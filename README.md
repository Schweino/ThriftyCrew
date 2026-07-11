# Thrifty Crew — 52 Weekly Lessons

A year of weekly lessons for **parents teaching teens about money + life success**, inspired by
the book *From the Bottom, Now I'm Here* but written as a standalone, broadly-welcoming product
(recovery/addiction backstory removed; values-based, not faith-based; not financial advice).

**Built for:** a very-low-cost ($5/mo) parent membership. Each lesson = a self-contained weekly
drop a parent can act on this week with their kid.

## How each lesson is structured
- A one-line hook + **this week's big idea**
- 3–5 short teaching sections (warm mentor voice, written to the parent)
- **Try this together** — a concrete activity/conversation for the week
- **Questions to sit with** — reflection prompts split into *For you (the parent)* and *For your kid*
- A teaser for next week

## Files
- `STYLE-GUIDE.md` — the voice + hard rules every lesson follows
- `CURRICULUM.md` — the master 52-week spec (titles, ideas, activities, sources)
- `lessons/` — the 52 finished lessons (`lesson-NN-slug.md`)

## The 52-week arc (follows a teen's year)

### Quarter 1 — Foundations: Mindset & Money Basics (summer)
1. Future You Is a Real Person
2. The Compounding Secret
3. Win the First Five Minutes
4. The Gap Is the Score
5. Needs First, Then Wants
6. Your Kid's First Budget
7. Where Does the Money Go?
8. The First Job Conversation
9. Pay Yourself First
10. Opening the First Account
11. Allowance vs. Earning
12. Talking About Money Without Fighting
13. Quarter Review + Family Money Night

### Quarter 2 — Earning, Work & Reputation (fall)
14. No One Is Coming to Save You (and That's Good News)
15. Skills Beat Luck
16. Find the Thing That Pulls at You
17. The Internet Is a Tool, Not a Trap
18. Apply It or Lose It
19. Do the Work Before You're Paid for It
20. Your Reputation Travels Faster Than You Do
21. Show Up On Time, Every Time
22. How to Get a First Job
23. The First Interview
24. Be the Employee They Brag About
25. References Are Currency
26. Quarter Review + Celebrate the Climb

### Quarter 3 — Growing Money & Avoiding Traps (winter)
27. Time Is Your Superpower
28. Meet Compound Interest (Hands-On)
29. The Custodial Account Conversation
30. Boring Wins: Index Funds 101
31. The 401(k) and "Free Money"
32. The Trap That Looks Like Help
33. How a Credit Card Actually Tricks You
34. "Buy Now, Pay Later" Is the Same Trap
35. What "Affordable" Really Means
36. Good Debt, Bad Debt, and the Exit Plan
37. Student Loans Without the Panic
38. Credit Scores, Explained Simply
39. Quarter Review + Money That Grows

### Quarter 4 — Character, Choices & the Road Ahead (spring)
40. Want Less, Win More
41. Lifestyle Creep
42. The 30% Breathing Room Rule
43. The Highlight Reel
44. What Are You Really Buying?
45. Borrow Other People's Hindsight
46. How to Spot Good Advice From Bad
47. Choose Your Crowd
48. The Few Expensive Mistakes
49. Taming the Need to Fit In
50. The Gift of Giving
51. Your Kid's First Five-Year Plan
52. A Letter to Future You

---
*52 lessons, one consistent voice, every lesson actionable. Ready to drip weekly.*

---

## Automation engine (this repo)

This private repo also runs the **daily grocery + recipe pricing engine** that powers the live site, in
GitHub Actions, so the site stays current without a local machine being on.

- **`grocery/`** — cross-store Omaha price board. Pulls server-side store ads (Hy-Vee, Aldi, Family Fare),
  re-prices, overlays recipe-ingredient sales, publishes the board + recipe hub to Ghost.
- **`meal-prep/`** — recipe database, ingredient-to-board mapping, weekly re-costing (`top5-weekly.ps1`),
  serving-scaler injector (`add-serving-scaler.ps1`).
- **`.github/workflows/`** — the daily cron.

**Secrets:** the Ghost Admin key is never committed. Locally it lives in a gitignored `.ghostkey`; in CI it
is the `GHOST_ADMIN_KEY` repo secret. **Local dependency:** Walmart, Sam's, and Baker's block cloud access,
so they refresh weekly from a browser on the local machine and commit their data here; skipping that only
staleness those three stores (the engine emails a warning).
