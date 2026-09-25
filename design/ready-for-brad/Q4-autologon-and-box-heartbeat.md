# Auto-logon, the lock, and the off-box boot page (Q4-tasks-dead-after-reboot, 2026-09-25)

Your ruling: "You set up Autologon; I build the lock and the boot page (Recommended)". The build is done and is
harmless until you do the two parts below. Queue item 2026-09-18-8491bf stays open until a real reboot proves it.

## Why

Every TC task runs only while Owner is signed in. The Windows Update restart on 2026-09-14 at 22:29 left the box
at the sign-in screen until 09-17 05:06, so 09-15 and 09-16 never ran and nothing paged, because the watcher
(health-heartbeat) is itself one of those tasks.

## What was built

- **TC Boot Watch** (`ops/boot-watch.ps1`), at every sign-in and every 15 minutes:
  - locks the desktop right after an AUTOMATIC sign-in, and only then: Autologon must be on
    (`AutoAdminLogon` = 1), the sign-in must come within 20 minutes of the boot, and it must be the first run for
    that boot. Signing out and back in later in the day never locks. While Autologon is off it never locks.
  - at the first sign-in after a reboot, however late, emails "the box rebooted and daily jobs were missed" with
    the reboot time, the sign-in time and every job that lost a day. A short restart that loses nothing is only
    written to the log.
  - sends a heartbeat to the website's Worker (`feed.thriftycrew.com/box-heartbeat`).
- **The off-box watcher** (`worker/box-heartbeat.js`): a Cloudflare cron on the smp-feed Worker checks every 15
  minutes and emails you "the box has gone silent" when no heartbeat has arrived for more than 60 minutes, then
  "the box is back" when they resume. It runs on Cloudflare, so it works when the box is off, asleep or sitting at
  the sign-in screen. And the box checks the watcher in return: if the cron stops checking for 2 hours, the box
  emails "the off-box heartbeat watcher is not checking".

## Part 1: Autologon (you, about 5 minutes)

An agent must never type or see your password, so this is yours.

1. Download **Autologon** from Microsoft Sysinternals: https://learn.microsoft.com/sysinternals/downloads/autologon
2. Run `Autologon64.exe`. Owner is not an administrator on this PC, so Windows will ask for administrator
   approval; approve it with the administrator account yourself.
3. Username `Owner`, Domain `DESKTOP-L652I1V`, Password: the account's real password (not the PIN). Click
   **Enable**. Autologon stores it encrypted; it is not written anywhere in the repo.
4. If Owner is a Microsoft account and Windows ignores the auto sign-in, the switch "For improved security, only
   allow Windows Hello sign-in for Microsoft accounts" (Settings, Accounts, Sign-in options) blocks it. Turning
   that off is your call.
5. Optional but worth knowing: with **Fast Startup** on, a Shut down and power-on is not a real boot, so the lock
   and the boot email do not fire for it. Restarts, including every Windows Update restart, are real boots and do.

## Part 2: turn on the off-box watcher (you, about 5 minutes, then one push)

The Worker code is already deployed with every push, but it does nothing until it has somewhere to store the last
heartbeat and a clock to check it on.

1. Cloudflare dashboard, account `bdf84c0d4146b198e8a14a59d08701ed`: **Storage and Databases, KV, Create
   namespace**, name it `tc-box-heartbeat`. Copy its **Namespace ID** (an id, not a secret).
2. Tell a session: "the box heartbeat KV id is `<id>`". It adds these two keys to `wrangler.jsonc` and declares
   them in `ops/cloudflare-estate.json` (the smp-feed worker's `crons` becomes `["*/15 * * * *"]`), and pushes:

       "kv_namespaces": [ { "binding": "BOX_KV", "id": "<id>" } ],
       "triggers": { "crons": ["*/15 * * * *"] }

   They go in the config file rather than the dashboard because the Worker deploys from git, and a deploy
   replaces bindings the config does not name.
3. No new secret is needed. The heartbeat signs itself with the same hash of the Ghost Admin key the pipeline
   already uses for `/ops-alert` and `/notify`, and the emails go through the Worker's existing Gmail secrets.

Cost: about 192 KV writes a day of the free plan's 1,000.

## Part 3: register the task (a session in the main checkout)

Once the commit that adds `ops/scheduled-tasks/tc-boot-watch.xml` is on origin/main and the main checkout has it:

    powershell -NoProfile -File C:\Codex\ThriftyCrew\ops\install-ops-tasks.ps1 -Install -Only 'TC Boot Watch'

It refuses if the script is not on disk yet. This registers one task for Owner and touches no other.

## How it is checked on the next reboot

After the next restart (a Windows Update one, or Start, Restart):

1. The box signs itself in and the screen locks within seconds.
2. `C:\Codex\ThriftyCrew\ops\out\logs\boot-watch-<date>.log` shows the boot, a sign-in within 20 minutes of it,
   and `LOCKED the workstation - auto-logon is on`.
3. No TaskScheduler event 332 ("user was not logged on") after the boot, and the 07:00 and 08:00 lanes run.
4. If the restart took under an hour, no "gone silent" email. If it took longer, you get "gone silent" and then
   "back".

When 1 to 3 hold, 8491bf can be closed with `grocery\triage-close.ps1 -Id 2026-09-18-8491bf -Disposition confirmed -Notes "auto-logon confirmed by the <date> reboot"`.
A deliberate test of the off-box half: disable TC Boot Watch for 75 minutes; the "gone silent" email should arrive,
and "back" within 15 minutes of enabling it again.
