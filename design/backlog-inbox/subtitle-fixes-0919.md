# Backlog run 2026-09-19: from the Money Hacks subtitle fixes (rounds 1 to 3)

Filed by the subtitle-fixes agent. The account of the rounds is `design\ready-for-brad\lessons\subtitle-fixes.md`,
`subtitle-fixes-2.md` and `subtitle-fixes-3.md`.

## build-content-hubs.ps1 writes to ghost unjournalled, always rewrites both hubs, and freezes subtitles at build time
`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

**Source.** Read at the base of this branch, 2026-09-19 (`.claude\skills\meal-macro\build-content-hubs.ps1`, 203
lines). It builds the two public directory pages, `/money-glossary/` and `/money-hacks/`, from live Ghost data.

**What is wrong, three things:**

1. **It writes to Ghost with a raw `Invoke-RestMethod`** (`Upsert-Page`, line 197), not through `lib\ghost-lib.ps1`'s
   `Invoke-GhostApi`. So a hub write gets no write-journal entry and no before-image (nothing
   `revert-ghost-write` can undo), and `TC_STAGE_WRITES` cannot stage it for review. It dot-sources `ghost-lib`
   only for `Get-GhostAcceptVersion`. Its existing-page lookup (line 190) is a GET inside `try { } catch { }`, so
   if that GET fails for any reason the script falls through to a **POST** of a new page with the same slug.
2. **It always rewrites BOTH hubs** (lines 200 and 201), with no switch to build one. It also rewrites each hub's
   own title, subtitle and meta every run, from literals in the script, and those literals still say *"real
   dollar examples"* (glossary subtitle and meta) and *"real numbers"* (money-hacks meta).
3. **It copies every card's subtitle into the hub's html at build time** (line 151 for Money Hacks, line 180 for
   the glossary), so any subtitle edit on a Money Hacks or glossary post leaves the hub showing the old line
   until somebody rebuilds it. This bit once already: round 1 went live on 2026-09-19 and the hub kept showing
   the renters and car-insurance lines it had just taken figures off (*"For about 15 dollars a month"*, *"Cut
   $300 to $600 a year"*) until a hand rebuild at 05:47 that morning (write-journal `897631adc2e8`). That rebuild
   had to be done from an offline copy of the script, edited so it wrote the money-hacks body only and left the
   glossary alone, because the script itself could do neither. Round 3's queue changes two more Money Hacks
   subtitles, so the same gap opens again the moment it is applied.

**Suggested fix:**

- Route its writes through `ghost-lib` (`Invoke-GhostApi`) so every hub write is journalled and can be staged,
  and make a failed lookup a refusal rather than a POST.
- Add a `-Only <slug>` switch (`money-hacks` or `money-glossary`), and leave the hub's own title, subtitle and meta
  alone unless asked, so a rebuild changes the card grid and nothing else.
- Have the subtitle-fix flow rebuild the hub: when a staged queue changes `custom_excerpt` on a post tagged
  Money Hacks or Glossary, the same apply (or the step right after it) rebuilds that one hub, staged like every
  other write. A reminder in a runbook is what we have today and it is why the gap happened.

**Check once built:** a rebuild with `-Only money-hacks` against a stubbed transport should leave the glossary
page's request count at zero, and the diff against the live hub on a day with no subtitle change should be empty.
