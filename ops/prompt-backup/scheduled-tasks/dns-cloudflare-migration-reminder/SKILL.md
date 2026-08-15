---
name: dns-cloudflare-migration-reminder
description: One-time 2026-07-11 reminder: do the simplemoneyplaybook.com DNS-to-Cloudflare migration + custom feed subdomain
---

Remind Brad (schweino68@gmail.com) that today (around 2026-07-11) is when he planned to do the deferred DNS work now that he can move the simplemoneyplaybook.com domain between Cloudflare accounts.

Deliver this as a clear, friendly chat reminder (no email needed unless he asks). Say roughly:

"Reminder: you're now able to move simplemoneyplaybook.com to the right Cloudflare account, which unblocks the DNS-to-Cloudflare migration and the custom feed subdomain (feed.simplemoneyplaybook.com) we deferred on 7/8."

Then read the memory file C:\Users\Owner\.claude\projects\C--Codex\memory\price-feed-cloud.md (the "PENDING (blocked until ~2026-07-11)" section) and summarize the exact fix steps for him, emphasizing the risk: this is a full DNS migration that can take down the LIVE SITE and EMAIL if any record is missed. The careful order is: (1) inventory EVERY current DNS record at the present DNS host (Ghost site A/CNAME, MX/email, SPF/DKIM TXT, the google-site-verification TXT, anything else), (2) recreate them ALL in the Cloudflare zone BEFORE switching, (3) switch nameservers at the registrar to Cloudflare's, (4) confirm the site loads and email flows, (5) add feed.simplemoneyplaybook.com as a Custom Domain on the smp-feed Worker, (6) update the feed URL (SMPFEED const) in C:\Codex\ThriftyCrew\meal-prep\add-serving-scaler.ps1 and re-run it with -All so all 113 recipe widgets point at the new URL.

Ask him if he wants to do it now, and offer to walk through it step by step (he'll need his domain registrar login and a calm window). Do NOT start changing nameservers or DNS on your own - this is his call and needs his registrar access. If he says he still can't do it yet, offer to snooze the reminder to a later date.