# Simple Money Playbook — Enable Paid Subscriptions (Gating Setup)

How to turn on charging BEFORE publishing, so the vault is gated from day one.

---

## What "gating" actually requires (two separate things)
1. **Enable payments** — connect Stripe so people *can* be charged. (One-time setup.)
2. **Set each post's audience to "Paid subscribers only"** when publishing — this is what actually
   locks the content. (Our post files already tell you which weeks are free vs paid: only Weeks 1
   and 27 are free.)

This guide covers #1 (the part you asked about). #2 happens at publish time.

---

## Before you start — have these ready
- Your legal name, date of birth, home address
- Tax ID: **SSN** (US individual) or **EIN** (if you set it up as a business)
- A **bank account** (routing + account number) for payouts
- ~15–20 minutes

> Heads-up: Stripe runs an identity verification. It's usually instant but can occasionally take a
> day. So do this a few days before you plan to launch, not the morning of.

---

## Step-by-step: enable payments

1. Go to **substack.com**, open your **Simple Money Playbook** publication, and click **Dashboard**.
2. Click **Settings** (gear / left nav).
3. Scroll to the **Payments** section → click **Enable payments** (or "Set up payments").
4. Choose your **country** and **business type** (most solo creators pick **Individual**).
5. You'll be handed off to **Stripe**. Fill in:
   - Legal name, DOB, address
   - SSN/EIN (tax info)
   - Bank account for payouts
   - Verify your email/phone if asked
6. Stripe returns you to Substack once verification clears.

## Step-by-step: set your prices
(Settings → Payments → Subscription, after Stripe is connected)

- **Monthly:** `$5` ← note: $5/mo is Substack's *minimum*, so you're right at the floor (perfect for
  the "$5 is nothing" pitch)
- **Annual:** `$40` ← turn this ON (Substack annual minimum is $30, so $40 is fine). This is your
  churn-killer — an annual subscriber is locked in 12 months.
- **Founding member (optional):** set a minimum like `$75` with a short thank-you note. Lets early
  believers pay more to support the launch.
- **Free trial:** optional — at a $5 price the friction is already tiny, so you can leave it off.
- Click **Save**.

## Quick sanity check after setup
- Visit your public **subscribe page** (`maptosuccess.substack.com/subscribe`) — you should see the
  $5/mo and $40/yr options.
- Optionally "comp" yourself or a friend a free paid subscription to test the gated view.

---

## What it actually costs you (so there are no surprises)
- **Substack fee:** 10% of subscription revenue
- **Stripe processing:** ~2.9% + $0.30 per transaction
- So on a **$5/mo** sub you net roughly **$4.05**. On **$40/yr**, roughly **$34.50**.
- (This is why the annual plan helps twice: locks in the year *and* you eat the processing fee once
  instead of 12 times.)

---

## Then: gating the content at publish time
When you publish each post, set **"Who can read this?" → Paid subscribers**, EXCEPT Weeks 1 and 27
(set those to **Everyone / free**). You can also set the **default audience for new posts to Paid**
in Settings so you don't forget. Our `posts/substack-week-NN.md` files state the audience for each.
