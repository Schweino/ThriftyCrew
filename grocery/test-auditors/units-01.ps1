
# ---------------------------------------------------------------- 1. basis reconciler
# ALL THREE AT ONCE. Measured 2026-08-23 at 53.4s + 50.3s + 49.9s = 154s of this suite's 467. They are
# three independent processes over three FROZEN boards, and each verdict is read only from its own
# stdout - so the only thing serialising them was RunPS. Each gets its OWN report directory: the audit
# always writes basis-reconcile.json, and three simultaneous children in one directory would be three
# writers on one file. Nothing reads these reports (that is the whole point of -ReportDir, section 97),
# but a harness that races on a file it does not even read would look like a flaky auditor.
if (Use-Unit 'u001-1-basis-reconciler') {
$brCases = @(
  # MUST FIRE: Hy-Vee published $3.15/lb for corned beef brisket while the store's own size text printed
  # "($8.99/lb)" right there on the same row.
  @{ tag = 'br-conflict'; fixture = 'basis-conflict-board.json' },
  # MUST BE SILENT: same board with the cell corrected to the store's own rate.
  @{ tag = 'br-clean';    fixture = 'basis-clean-board.json' },
  # MUST NOT trip on sub-cent rounding (a store publishing "$0.01/ea" against our $0.0053 is rounding, not conflict)
  @{ tag = 'br-round';    fixture = 'basis-rounding-board.json' })
$br = RunPSMany @($brCases | ForEach-Object {
  $d = Join-Path $fixRep $_.tag
  $null = New-Item -ItemType Directory -Path $d -Force
  @{ script = 'audit-basis-reconcile.ps1'; args = @('-CompareFile', (Join-Path $fix $_.fixture), '-ReportDir', $d) } })
$r = $br[0]
if ($r.text -match 'corned-beef-brisket' -and $r.text -match 'disagree') { Ok 'basis-reconcile FIRES on the per-lb-rate conflict' }
else { Bad ('basis-reconcile MISSED its founding bug: ' + $r.text) }
$r = $br[1]
if ($r.text -match 'ok - every checkable cell agrees') { Ok 'basis-reconcile SILENT on the corrected board' }
else { Bad ('basis-reconcile false-positived on a clean board: ' + $r.text) }
$r = $br[2]
if ($r.text -match 'ok - every checkable cell agrees') { Ok 'basis-reconcile ignores whole-cent rounding noise' }
else { Bad ('basis-reconcile tripped on cent rounding: ' + $r.text) }
# STRICT MODE PILOT (backlog I179, 2026-09-19). audit-basis-reconcile runs under Set-StrictMode -Version Latest,
# so a board cell that has LOST a field it must carry (here `item`) throws and names the field. Unstrict the read
# was '' and the cell was checked against nothing under an empty name. MUST FIRE: the throw, and the field named.
# The three cases above are the CLEAN TWIN half: the real frozen boards still run clean under the mode.
$smBoard = Join-Path $fixRep 'br-strict-noitem-board.json'
[IO.File]::WriteAllText($smBoard, '{"comparison":[{"id":"corned-beef-brisket","commodity":"Corned Beef Brisket","unit":"lb","stores":[{"store":"Hy-Vee","per_unit":3.15,"size":"2.85 lbs ($8.99/lb)","ad":"$8.98","basis":"lb"}]}]}', (New-Object Text.UTF8Encoding($false)))
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', $smBoard, '-ReportDir', $fixRep)
# The child's error record is wrapped at its console width, so the words are matched with whitespace collapsed.
$smText = ($r.text -replace '\s+', ' ')
if ($r.rc -ne 0 -and $smText -match 'PropertyNotFoundStrict' -and $smText -match "property 'item' cannot be found") { Ok 'basis-reconcile runs STRICT: a board cell missing its item field throws and names the field (backlog I179 pilot)' }
else { Bad ('basis-reconcile read a missing item field quietly - Set-StrictMode is not in force (rc=' + $r.rc + '): ' + $r.text) }
} # u001-1-basis-reconciler

# ---------------------------------------------------------------- 1b. Baker's netWeight source
# Kroger returns NO unit price, so netWeight (the store's own package weight) is the only independent
# statement available for the estate's largest store. MUST FIRE on the 2026-07-24 Kerrygold class: reading
# "4 ct / 16 oz" as 16 oz PER STICK priced the pack 4x under and no band blinked.
if (Use-Unit 'u002-1b-baker-s-netweight-source') {
$rawFx = Join-Path $fix 'bakers-raw'
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-netweight-conflict-board.json'), '-RawDir', $rawFx, '-ReportDir', $fixRep)
if ($r.text -match 'butter' -and $r.text -match 'netWeight') { Ok "basis-reconcile FIRES when Baker's size disagrees with Kroger's own netWeight" }
else { Bad ('basis-reconcile missed the netWeight conflict: ' + $r.text) }
# MUST BE SILENT once the size is read correctly...
$r2 = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-netweight-clean-board.json'), '-RawDir', $rawFx, '-ReportDir', $fixRep)
if ($r2.text -match 'ok - every checkable cell agrees') { Ok 'basis-reconcile SILENT when the pack size matches netWeight' }
else { Bad ('basis-reconcile false-positived on a correct netWeight board: ' + $r2.text) }
# ...and must IGNORE a soldBy=WEIGHT row, whose netWeight is the random tray weight (Tyson reads 22.56 lb).
# Both fixtures carry that row; "checked 1 cell" proves it was skipped rather than silently agreeing.
if ($r.text -match 'checked 1 cell' -and $r2.text -match 'checked 1 cell') { Ok 'basis-reconcile ignores a per-pound (soldBy=WEIGHT) row, whose netWeight is a tray weight' }
else { Bad 'basis-reconcile is reading netWeight on a soldBy=WEIGHT row - that is the random tray weight, not a package size' }
} # u002-1b-baker-s-netweight-source

# ---------------------------------------------------------------- 1c. one NAME, two products
# 2026-07-28: the join keyed on store+item name and kept the first match, so a multipack cell was compared
# against the single-unit row of the same name and two perfectly correct rows produced a clean 2x "conflict"
# ("Kroger Original Cream Cheese" is both an 8 oz brick and a 2 ct / 8 oz pack; Sam's listed one Pledge
# 3-pack twice). The cell here is CORRECT at $3.29/16 oz, so silence proves the join picked the right row -
# a name-only join would compare it to the 8 oz single at $0.411/oz and flag.
if (Use-Unit 'u003-1c-one-name-two-products') {
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-namecollision-board.json'), '-RawDir', (Join-Path $fix 'bakers-raw-collision'), '-ReportDir', $fixRep)
if ($r.text -match 'ok - every checkable cell agrees' -and $r.text -match 'checked 1 cell') { Ok 'basis-reconcile picks the right row when two products share one name' }
else { Bad ('basis-reconcile cross-matched two products sharing a name: ' + $r.text) }
} # u003-1c-one-name-two-products

# ---------------------------------------------------------------- 2. pack-basis heuristic
# MUST FIRE: Sam's Pledge 3-pack whose 29 oz TOTAL was multiplied into an 87 oz each-size, making it the
# cheapest furniture polish in Omaha at a third of its real price.
if (Use-Unit 'u004-2-pack-basis-heuristic') {
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-board.json'), '-ReportDir', $fixRep)
if ($r.text -match 'furniture-polish' -and $r.text -match 'multiplied') { Ok 'pack-basis FIRES on the Pledge pack-total bug' }
else { Bad ('pack-basis MISSED its founding bug: ' + $r.text) }
# MUST BE SILENT on genuine bulk: 24 ct x 16.9 fl oz water and a 3 pk x 5 lb grits really are that cheap.
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-legit-bulk-board.json'), '-ReportDir', $fixRep)
if ($r.text -match 'ok - no multipack cell') { Ok 'pack-basis SILENT on legitimate bulk multipacks' }
else { Bad ('pack-basis false-positived on real bulk: ' + $r.text) }
} # u004-2-pack-basis-heuristic

# ---------------------------------------------------------------- 2b. pack-basis BLOCKS the decidable case
# 2026-08-02: the audit above named the Pledge row at 09:03 and the board published the wrong crown at 09:11
# anyway, because an advisory report is not in the publish path. The decidable subset now exits 2 and
# guards.ps1 delegates to it. What makes it decidable is arithmetic, not text: stated-size / count
# reproduces the single-unit size other stores actually sell (29/3 = 9.67 against 9.7 oz cans at four
# stores), so the printed number can only have been the pack TOTAL.
# The exit code is the assertion. A run that merely PRINTS the words while exiting 0 would leave the board
# publishable, which is the exact failure this test exists to prevent, so rc is checked separately from text.
if (Use-Unit 'u005-2b-pack-basis-blocks-the-decidable') {
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-board.json'), '-ReportDir', $fixRep)
if ($r.rc -eq 2 -and $r.text -match 'CONFIRMED PACK TOTAL' -and $r.text -match 'furniture-polish') { Ok 'pack-basis BLOCKS (exit 2) on the peer-size fingerprint of a pack total' }
else { Bad ("pack-basis did not block its own founding bug (rc=$($r.rc)): " + $r.text) }
# THE CLEAN TWIN, and the one that matters most: same count-first grammar, opposite meaning. Member's Mark
# hummus singles really are 2.5 oz EACH, so 16 x 2.5 = 40 oz is correct and the cell is right. The
# fingerprint must stay silent because 2.5/16 = 0.156 oz is a size nobody sells (peers are 8, 10, 17 oz).
# The row still shows up as an ADVISORY finding - that is intended - but it must not fail the publish.
# -AllowFile points at nothing on purpose: this case is about the FINGERPRINT, and a live ruling on the
# real hummus row must not be able to silence the drill that proves the fingerprint is not over-broad.
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-hummus-clean-board.json'), '-ReportDir', $fixRep, '-AllowFile', (Join-Path $fix 'no-such-allowlist.json'))
if ($r.rc -eq 0 -and $r.text -match 'hummus' -and $r.text -notmatch 'CONFIRMED PACK TOTAL') { Ok 'pack-basis fingerprint stays SILENT on a real per-item pack (hummus clean twin, still advisory)' }
else { Bad ("pack-basis fingerprint condemned a CORRECT per-item pack (rc=$($r.rc)): " + $r.text) }
} # u005-2b-pack-basis-blocks-the-decidable

# ---------------------------------------------------------------- 2c. coverage-gaps says WHY, not just WHAT
# 2026-08-02: audit-coverage-gaps validated candidates against include/exclude regexes only, while the engine
# also requires a basis it can express in the commodity's unit and the sanity band. So the daily alert's
# headline - "usually a too-strict include" - was FALSE for 29 of its 36 gaps: the top candidate matched and
# routed correctly, and the store was absent for a reason the audit never checked. A page that is 80 percent
# noise is how the real find in the same list (salt eating a berbere jar) gets skimmed past.
# Four frozen fixtures, one per reason, driven entirely off the fixture dir so no live file can move under
# them. The berbere fixture uses PRE-FIX rules on purpose: it must keep proving the classifier can SEE a
# first-match hijack after today's release exclude has made this particular one go away.
if (Use-Unit 'u006-2c-coverage-gaps-says-why-not-just') {
$cgFix = Join-Path $fix 'coverage-classify'
$cgArgs = @('-OutDir', $cgFix, '-ReportDir', $fixRep,
            '-CompareFile',    (Join-Path $cgFix 'comparison-fixture.json'),
            '-CandidatesFile', (Join-Path $cgFix 'candidates-fixture.json'),
            '-AllowFile',      (Join-Path $cgFix 'allowlist.json'))
$r = RunPS 'audit-coverage-gaps.ps1' ($cgArgs + @('-CommoditiesFile', (Join-Path $cgFix 'commodities.json')))
if ($r.text -match 'pork-chops\s+Hy-Vee\s+\[RULE-INVISIBLE\]')                { Ok 'coverage-gaps classifies the founding pork-chops bug as RULE-INVISIBLE' }
else { Bad ('coverage-gaps lost the RULE-INVISIBLE class: ' + $r.text) }
if ($r.text -match 'berbere-seasoning\s+Walmart\s+\[CLAIMED-BY\]' -and $r.text -match "gave this name to 'salt'") { Ok 'coverage-gaps classifies a first-match hijack as CLAIMED-BY and names the thief' }
else { Bad ('coverage-gaps cannot see a first-match hijack: ' + $r.text) }
if ($r.text -match 'lemons\s+Walmart\s+\[BASIS-NULL\]')                       { Ok "coverage-gaps classifies a bagged-per-lb row on an each commodity as BASIS-NULL" }
else { Bad ('coverage-gaps lost the BASIS-NULL class: ' + $r.text) }
if ($r.text -match 'frozen-waffles\s+' + [regex]::Escape("Sam's Club") + '\s+\[BAND-DROPPED\]') { Ok 'coverage-gaps classifies a band-rejected real price as BAND-DROPPED' }
else { Bad ('coverage-gaps lost the BAND-DROPPED class: ' + $r.text) }
# The whole point of the classification is WHICH ONES PAGE. Two actionable, and exit 2 because of them.
if ($r.rc -eq 2 -and $r.text -match '2 actionable, 2 explained') { Ok 'coverage-gaps pages on RULE-INVISIBLE + CLAIMED-BY and counts the rest as explained' }
else { Bad ("coverage-gaps paged on the wrong set (rc=$($r.rc)): " + $r.text) }
# ...and MUST NOT page when every gap is one the engine already explains. This is the assertion that would
# fail if someone "simplified" the classifier back into exit-2-on-any-gap.
$r = RunPS 'audit-coverage-gaps.ps1' ($cgArgs + @('-CommoditiesFile', (Join-Path $cgFix 'commodities-quiet.json')))
if ($r.rc -eq 0 -and $r.text -match 'no ACTIONABLE gap' -and $r.text -match 'BASIS-NULL' -and $r.text -match 'BAND-DROPPED') { Ok 'coverage-gaps stays QUIET (exit 0) when every gap is basis/band, while still reporting them' }
else { Bad ("coverage-gaps paged on gaps the engine itself explains (rc=$($r.rc)): " + $r.text) }
} # u006-2c-coverage-gaps-says-why-not-just

# ---- 2c-bis. THE AUDITOR'S OWN TWO BLIND SPOTS (2026-09-07, queue 2026-09-07-0e9482) -------------------
# Four of the five gaps on 2026-09-07 were not rule problems at all; they were this audit reporting things
# it could not see the explanation for.
#   RULED-WRONG - it never read known-wrong.json. A reasoner had already looked at 'Hy-Vee Pork & Beans in
#                 Tomato Sauce' and decided it is not a baked bean; the guard 'no product a reasoner already
#                 ruled wrong is priced' then removes it, and this audit paged on the resulting absence.
#                 That is a page asking a human to re-take a decision they already took, every day, forever.
#   AD-LINE     - Hy-Vee's ad feed is made of SENTENCES ("Hy-Vee rice, quinoa or Israeli-style couscous,
#                 ..."), and the candidate test is "does the pattern match the name", which cannot tell a
#                 product from a line that merely names one. One commodity must own such a line and every
#                 other commodity it names pages as CLAIMED-BY forever - with nothing fixable behind it,
#                 because the line carries no size and NO commodity can price it whoever owns it.
# The fixture is frozen from the real rows and lives in its own directory, so none of the five assertions
# in 2c above can move under it.
if (Use-Unit 'u007-2c-bis-the-auditor-s-own-two-blind') {
$cg2Fix  = Join-Path $fix 'coverage-classify-0e9482'
$cg2Args = @('-OutDir', $cg2Fix, '-ReportDir', $fixRep,
             '-CompareFile',     (Join-Path $cg2Fix 'comparison-fixture.json'),
             '-CandidatesFile',  (Join-Path $cg2Fix 'candidates-fixture.json'),
             '-AllowFile',       (Join-Path $cg2Fix 'allowlist.json'),
             '-CommoditiesFile', (Join-Path $cg2Fix 'commodities.json'))
$r = RunPS 'audit-coverage-gaps.ps1' ($cg2Args + @('-LedgerFile', (Join-Path $cg2Fix 'known-wrong-fixture.json')))
if ($r.text -match 'baked-beans\s+Hy-Vee\s+\[RULED-WRONG\]') { Ok 'coverage-gaps MUST FIRE: a product a reasoner already ruled wrong classifies RULED-WRONG instead of paging as a rule gap' }
else { Bad ('coverage-gaps still cannot see known-wrong.json - a ruled-out product is being paged as a coverage gap: ' + $r.text) }
if ($r.text -match 'quinoa-uncooked\s+Hy-Vee\s+\[AD-LINE\]' -and $r.text -match "gave it to 'rice'") { Ok 'coverage-gaps MUST FIRE: a multi-product ad line with no priceable owner classifies AD-LINE and names the owner' }
else { Bad ('coverage-gaps lost the AD-LINE class - every commodity named in a Hy-Vee ad sentence pages forever: ' + $r.text) }
# MUST NOT FIRE: the class must stay narrow. Both of these carry the words the AD-LINE test looks at and
# must still page, or the two new classes have become a way to silence real hijacks.
if ($r.text -match 'frozen-chimichangas\s+Walmart\s+\[CLAIMED-BY\]') { Ok 'coverage-gaps MUST NOT FIRE: a name with " or " in it whose owner PRICED it is still a plain CLAIMED-BY hijack, not an AD-LINE' }
else { Bad ('AD-LINE has widened past unpriceable ad sentences and is now swallowing real first-match hijacks: ' + $r.text) }
if ($r.text -match 'sea-salt\s+Hy-Vee\s+\[CLAIMED-BY\]' -and $r.text -match "gave this name to 'honey'") { Ok 'CLEAN TWIN: the honey line has no " or ", so it stays an actionable CLAIMED-BY - it is the allowlist that silences that one, not the class' }
else { Bad ('the honey/sea-salt line stopped classifying as CLAIMED-BY: ' + $r.text) }
if ($r.rc -eq 2 -and $r.text -match '3 actionable, 4 explained') { Ok 'coverage-gaps: 3 of the 7 fixture gaps page and 4 are explained (RULED-WRONG, AD-LINE and two BASIS-NULL)' }
else { Bad ("coverage-gaps paged on the wrong set with the new classes (rc=$($r.rc)): " + $r.text) }
# FIXTURE INTEGRITY, and it is the whole of the RULED-WRONG assertion: run the SAME fixture with an EMPTY
# ledger and the pork & beans row must go back to PRICED and paging. Without this, "RULED-WRONG" would be
# equally consistent with the row never having reached the classifier at all.
$r = RunPS 'audit-coverage-gaps.ps1' ($cg2Args + @('-LedgerFile', (Join-Path $cg2Fix 'known-wrong-empty.json')))
if ($r.text -match 'baked-beans\s+Hy-Vee\s+\[PRICED\]' -and $r.text -match '4 actionable, 3 explained') { Ok 'FIXTURE INTEGRITY: with the ruling removed the same row is PRICED and pages again, so RULED-WRONG is the ledger being read and not the row going missing' }
else { Bad ('the RULED-WRONG case proves nothing: with an EMPTY ledger the pork & beans row does not come back as PRICED (rc=' + $r.rc + '): ' + $r.text) }
} # u007-2c-bis-the-auditor-s-own-two-blind

# ---------------------------------------------------------------- 3. triage-due must FAIL CLOSED
# Run a COPY of the guard in a temp dir so the live queue is never touched ($PSScriptRoot decides its paths).
if (Use-Unit 'u008-3-triage-due-must-fail-closed') {
$tmp = Register-Fx (Join-Path $env:TEMP ('triage-fixture-' + [guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item (Join-Path $root 'triage-due.ps1') (Join-Path $tmp 'triage-due.ps1')
# ...AND EVERY LIB IT DOT-SOURCES. The fixture is a bare temp directory, so a guard that dot-sources a
# sibling dies on launch here while working perfectly in place - and a guard that cannot start FAILS OPEN
# through the checks below: all four then report "triage-due FAILED OPEN", which reads as the guard being
# broken rather than the fixture being incomplete. That is exactly what happened on 2026-08-31, the day
# triage-due.ps1 was changed to share mute-lib.ps1 instead of keeping its own copy of the mute rule.
# Derived from the script's own source rather than hard-coded, so the NEXT lib it takes on comes along by
# itself instead of blinding these four tests again and waiting for someone to read the error text.
foreach ($m in [regex]::Matches((Get-Content (Join-Path $root 'triage-due.ps1') -Raw), "\.\s+\(Join-Path\s+\`$root\s+'(?<f>[^']+)'\)")) {
  $dep = Join-Path $root $m.Groups['f'].Value
  if (Test-Path $dep) { Copy-Item $dep (Join-Path $tmp $m.Groups['f'].Value) -Force }
  else { Bad ('triage-due dot-sources ' + $m.Groups['f'].Value + ' which is not in grocery\ - the fixture cannot carry it and the guard cannot start') }
}
} # u008-3-triage-due-must-fail-closed
function RunTriage($content) {
  $qf = Join-Path $tmp 'triage-queue.json'
  if ($null -eq $content) { Remove-Item $qf -ErrorAction SilentlyContinue }
  else { [IO.File]::WriteAllText($qf, $content, (New-Object Text.UTF8Encoding($false))) }
  $o = PSChild (Join-Path $tmp 'triage-due.ps1') | ForEach-Object { [string]$_ }
  return ($o -join ' ')
}
# the exact 2026-07-28 failure: a queue file caught mid-rewrite reads as an empty string, and in PS 5.1
# '' | ConvertFrom-Json returns $null WITHOUT throwing - the catch never fires and IDLE gets printed.
if (Use-Unit 'u008-3-triage-due-must-fail-closed') {
$t = RunTriage ''
if ($t -match '^DUE') { Ok 'triage-due says DUE on an empty (mid-write) queue file' }
else { Bad ('triage-due FAILED OPEN on an empty queue - it said: ' + $t) }
$t = RunTriage '{ "items": [ {"id":"x","status":"op'
if ($t -match '^DUE') { Ok 'triage-due says DUE on truncated JSON' }
else { Bad ('triage-due FAILED OPEN on truncated JSON - it said: ' + $t) }
$t = RunTriage '{"items":[{"id":"a","status":"open","count":1,"subject":"fixture alert"}]}'
if ($t -match '^DUE' -and $t -match 'fixture alert') { Ok 'triage-due says DUE and names a genuinely open item' }
else { Bad ('triage-due missed an open item - it said: ' + $t) }
$t = RunTriage '{"items":[{"id":"a","status":"resolved","count":1,"subject":"done"}]}'
if ($t -match '^IDLE') { Ok 'triage-due says IDLE only when the queue is really clear' }
else { Bad ('triage-due cried wolf on a clear queue - it said: ' + $t) }
# W2 of design\PLAN-triage-token-cut-2026-09-25.md: a RETURN prints ONE short line per id, and the full RETURN line
# goes to a file the orchestrator names in the reviewer's dispatch (the block was about 10k characters on 09-25).
$d0 = (Get-Date).AddDays(-20).ToString('yyyy-MM-ddTHH:mm:ss'); $d1 = (Get-Date).AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ss'); $d2 = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$retQ = '{"items":[{"id":"p1","ts":"' + $d0 + '","type":"fixture return type","status":"resolved","count":1,"subject":"fixture return type"},{"id":"p2","ts":"' + $d1 + '","type":"fixture return type","status":"resolved","count":1,"subject":"fixture return type"},{"id":"cur9","ts":"' + $d2 + '","type":"fixture return type","status":"open","count":1,"subject":"fixture return type"}]}'
$retF = Join-Path $tmp 'returns.txt'
$env:TC_TRIAGE_DUE_RETURNS_FILE = $retF
try { $t = RunTriage $retQ } finally { Remove-Item Env:\TC_TRIAGE_DUE_RETURNS_FILE -ErrorAction SilentlyContinue }
$full = if (Test-Path $retF) { [IO.File]::ReadAllText($retF) } else { '' }
if ($t -match 'RETURN cur9' -and $t -notmatch 'closed 2 time' -and $full -match 'RETURN: cur9 .*closed 2 time\(s\) in 30 days') { Ok 'MUST FIRE: triage-due prints a RETURN as one short line and writes the full RETURN line to its file' }
else { Bad ('triage-due RETURN block did not split into a short line and a file - it said: ' + $t + ' | file: ' + $full) }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
} # u008-3-triage-due-must-fail-closed

# ---------------------------------------------------------------- 4. the PS 5.1 array-wrap trap, repo-wide
# @(Get-Content x | ConvertFrom-Json) does NOT unroll a JSON array in 5.1: it yields ONE element holding the
# whole array. That is how 54 sanity outliers became a single flag line. This is a CLASS check, not a
# site check - it fails if the pattern reappears anywhere in the live grocery scripts.
#
# WIDENED 2026-08-06, because this check watched one doorway and the bug walked through another two:
#   - the same no-unroll applies to @(Invoke-RestMethod ...) and @(Invoke-WebRequest ...); the cmdlet emits a
#     deserialized JSON array as ONE pipeline object exactly like ConvertFrom-Json does, and
#   - daily.yml is PowerShell too, but it lives in .github\workflows and this scan only read grocery\*.ps1.
# Cost of the gap: the cloud backup's stand-down gate read @(Invoke-RestMethod ...).Count -gt 0, which is
# always true, so runs #22 (07-24) through #34 (08-05) all stood down - 13 days with no backup, all green.
# A class check that only knows the one shape the class first appeared in is a site check wearing a costume.
if (Use-Unit 'u009-4-the-ps-5-1-array-wrap-trap-repo') {
$skipSelf = @('test-auditors.ps1', 'test-gate-count.ps1')   # these quote the pattern to describe and probe it
$scan = @(Get-ChildItem (Join-Path $root '*.ps1')) +
        @(Get-ChildItem (Join-Path (Split-Path $root -Parent) '.github\workflows\*.yml') -ErrorAction SilentlyContinue)
$patterns = @(
  '(?m)^.*@\(\s*Get-Content[^)\r\n]*\|\s*ConvertFrom-Json\s*\).*$',   # json-readers:allow the DETECTOR pattern - a frozen literal naming the shape this auditor hunts, not a read
  '(?m)^.*@\(\s*Invoke-(RestMethod|WebRequest)\b.*$'
)
$offenders = @()
foreach ($f in $scan) {
  if ($skipSelf -contains $f.Name) { continue }
  # PRODUCTION STATEMENTS ONLY for .ps1 (queue 2026-09-11-220094): a frozen fixture of this very trap inside
  # a guard's own -SelfTest block is not a live call site. A .yml has no such block and reads whole.
  $txt = if ($f.Extension -eq '.ps1') { Get-TcProductionText -Path $f.FullName } else { Get-Content $f.FullName -Raw }
  foreach ($p in $patterns) {
    foreach ($ln in ([regex]::Matches($txt, $p))) {
      if ($ln.Value -match '^\s*#') { continue }   # the explanatory comments are not code
      $offenders += ($f.Name + ': ' + $ln.Value.Trim())
    }
  }
}
if ($offenders.Count -eq 0) { Ok 'no live script or workflow wraps a JSON-array-returning call in @() (the PS 5.1 no-unroll trap)' }
else { Bad ("the PS 5.1 no-unroll trap is back in " + $offenders.Count + " place(s):`n      " + ($offenders -join "`n      ")) }

# and prove the trap is real, so nobody "fixes" the check by deleting it
$probe = Register-Fx (Join-Path $env:TEMP ('arr-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json'))
'[{"a":1},{"a":2},{"a":3}]' | Set-Content $probe -Encoding UTF8
$wrapped = @(Read-JsonFile $probe)   # readjson-wrap:allow deliberate probe proving the trap still behaves as documented
$assigned = Read-JsonFile $probe
Remove-Item $probe -Force -ErrorAction SilentlyContinue
if ($wrapped.Count -eq 1 -and @($assigned).Count -eq 3) { Ok 'the no-unroll trap still behaves as documented (wrapped=1, assigned-then-wrapped=3)' }
elseif ($wrapped.Count -eq 3) { Ok 'this PowerShell unrolls ConvertFrom-Json (newer host) - the class check above is belt-and-braces' }
else { Bad 'the array-wrap probe behaved unexpectedly - re-read the ps51-json-array-traps note' }
} # u009-4-the-ps-5-1-array-wrap-trap-repo

# ---------------------------------------------------------------- 5. send-alert must write the queue atomically
# The queue is read-modify-written by several processes; Set-Content truncates before it fills, which is the
# window that produced the empty read above. Assert the atomic swap + mutex are still in place.
if (Use-Unit 'u010-5-send-alert-must-write-the-queue') {
$sa = Get-Content (Join-Path $root 'send-alert.ps1') -Raw
# Write-TcAtomicFile since 2026-09-11: a bare Move-Item over the queue fails while a lock-free reader holds it.
if ($sa -match 'Write-TcAtomicFile[^\r\n]*\$qFile' -and $sa -match 'System\.Threading\.Mutex') { Ok 'send-alert still writes the queue via mutex + retried atomic swap (Write-TcAtomicFile)' }
else { Bad 'send-alert lost its mutex or its Write-TcAtomicFile swap - a concurrent read can see a truncated queue, or cost a write, again' }
if ($sa -match 'refusing to overwrite') { Ok 'send-alert still refuses to overwrite a queue that reads back empty' }
else { Bad 'send-alert lost the refuse-to-overwrite-empty guard - a bad read can wipe the backlog' }
} # u010-5-send-alert-must-write-the-queue

# ---------------------------------------------------------------- 5b. an alert body must never ride the command line
# FOUNDING BUG (2026-08-06). Every alerting script mailed like this:
#     & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "..." -Body $body
# Windows caps a whole command line at 32767 characters, and CreateProcess does not truncate at the cap - it
# REFUSES to start the process. So the one alert whose body is unbounded by construction (the watchers' full
# test-auditors output - this file's own output, 43,030 / 43,283 / 43,718 chars on 2026-08-03/04/05) never
# launched the mailer on any of the three consecutive days a guard was blind. There was no email and no
# triage-queue entry either, because the queue is written INSIDE send-alert.ps1, and the caller's catch
# swallowed the launch error and logged it as "test-auditors threw: ... The filename or extension is too
# long" - which reads like THIS script crashed rather than like the page never went out. A watcher was red
# for four days and nobody was told. The bug was in the delivery, wearing the costume of the thing it was
# meant to deliver.
# THE RULE NOW: alert-lib.ps1's Send-Alert is the only thing that may spawn send-alert.ps1, and it hands the
# body over as -BodyFile. The defect IS the call shape, so the call shape is what gets pinned.
if (Use-Unit 'u011-5b-an-alert-body-must-never-ride-the') {
$abBad = @()
$abDirs = @((Join-Path $root '*.ps1'), (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\*.ps1'))
foreach ($abG in $abDirs) {
  foreach ($abF in @(Get-ChildItem $abG -File -ErrorAction SilentlyContinue)) {
    # alert-lib is the one permitted spawner; send-alert is the target; this file carries the frozen bad
    # shape below as a MUST-FIRE fixture and would otherwise convict itself of the bug it is detecting.
    if (@('alert-lib.ps1', 'send-alert.ps1', 'test-auditors.ps1') -contains $abF.Name) { continue }
    # strip block comments then whole-line comments: the prose ABOUT the bad shape (here, in alert-lib and
    # in notify-desktop's founding-bug note) must not read as the bad shape itself.
    $abSrc = [regex]::Replace([IO.File]::ReadAllText($abF.FullName), '(?s)<#.*?#>', '')
    $abSrc = (($abSrc -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($abSrc -match '(?s)powershell[^\r\n]{0,240}-File[^\r\n]{0,160}send-alert\.ps1') { $abBad += $abF.Name }
  }
}
if ($abBad.Count -eq 0) { Ok 'no script spawns send-alert.ps1 itself - every alert goes through Send-Alert, whose body travels by file' }
else { Bad ('these script(s) invoke send-alert.ps1 through a child powershell again, so any alert body over 32767 chars will silently never send: ' + ($abBad -join ', ')) }
# MUST-FIRE: the detector has to still recognise the exact 2026-08-06 shape, or it is examining nothing.
$abFx = "  & powershell -ExecutionPolicy Bypass -File (Join-Path `$root 'send-alert.ps1') -Subject 'x' -Body `$body | Out-Null"
if ($abFx -match '(?s)powershell[^\r\n]{0,240}-File[^\r\n]{0,160}send-alert\.ps1') { Ok 'alert-shape detector still fires on the frozen founding call shape' }
else { Bad 'the alert-shape detector no longer matches its own founding bug - the check above proves nothing' }
# and the helper must keep the two properties the outage turned on: body by file, and a LOUD failed send.
$abLib = [IO.File]::ReadAllText((Join-Path $root 'alert-lib.ps1'))
if ($abLib -match '-BodyFile \$bf') { Ok 'alert-lib still passes the body as -BodyFile, not on the command line' }
else { Bad 'alert-lib no longer sends the body by file - an oversized alert can silently fail to send again' }
if ($abLib -match 'ALERT FAILED TO SEND') { Ok 'alert-lib still logs a failed send loudly (a dead page cannot read as a crashed check)' }
else { Bad 'alert-lib lost its ALERT FAILED TO SEND line - a page that never went out is indistinguishable from the check itself dying again' }
} # u011-5b-an-alert-body-must-never-ride-the

# ---------------------------------------------------------------- 6. coverage-gaps must share the engine's exclusions
# It kept its own opinion of what is not-food and reported engine-refused products as gaps forever.
# THE LIST IS A LIBRARY NOW (2026-09-09, backlog I82). It used to be an array literal cut out of
# compare-deals.ps1 by regex and run through Invoke-Expression, and this block asserted that the PARSE still
# worked. The property being defended never was the parse - it is that the auditor and the engine read the
# SAME list - so the assertion moves with the mechanism rather than being deleted with it.
if (Use-Unit 'u012-6-coverage-gaps-must-share-the') {
$cg = Get-Content (Join-Path $root 'audit-coverage-gaps.ps1') -Raw
if ($cg -match 'Get-TcGlobalExclude') { Ok 'coverage-gaps reads the engine GLOBAL_EXCLUDE through the library' }
else { Bad 'coverage-gaps no longer reads the engine GLOBAL_EXCLUDE - engine-refused products will be reported as gaps' }
# and prove the library still yields the real list rather than silently returning empty
$gexLib = Join-Path $root 'global-exclude-lib.ps1'
if (Test-Path $gexLib) {
  . $gexLib
  $ge = @(Get-TcGlobalExclude)
  if ($ge.Count -ge 20 -and ($ge -contains 'happy\s*tot')) { Ok ("the GLOBAL_EXCLUDE library yields the real list (" + $ge.Count + " tokens)") }
  else { Bad ("the GLOBAL_EXCLUDE library returned " + $ge.Count + " tokens - every auditor that reads it is now running on a different list than the engine") }
  # MUST NOT be a bare variable: a lifted $script: constant does not travel, so a library that exported
  # $GLOBAL_EXCLUDE instead of a function would work here and hand back nothing to a lifting caller.
  $gexSrc = Get-Content $gexLib -Raw
  if ($gexSrc -match '(?m)^function\s+Get-TcGlobalExclude') { Ok 'the exclude list is exported as a FUNCTION, so it survives being lifted' }
  else { Bad 'global-exclude-lib no longer exports a function - a bare $script: constant does not travel to a lifting caller' }
} else { Bad 'global-exclude-lib.ps1 is missing - every auditor that shares the engine exclusions is now blind' }
# and the engine must not have grown a second copy back
$cdtxt = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
if ($cdtxt -match '(?m)^\s*\$GLOBAL_EXCLUDE\s*=\s*@\(') { Bad 'compare-deals.ps1 has an array literal for $GLOBAL_EXCLUDE again - there are two copies of the list and they will drift' }
else { Ok 'compare-deals.ps1 holds no second copy of the exclude list' }
} # u012-6-coverage-gaps-must-share-the

# ---------------------------------------------------------------- 7. a locked log must not kill the pipeline
# 2026-07-28: a `tail -f` on ad-cycle-log.txt held the file open, Add-Content threw under EAP=Stop, and
# check-ad-cycles died mid-run TWICE - with no log line explaining it, because logging WAS the failure. An
# editor with the log open, a backup or an antivirus scan does the same. Reproduce the exact condition:
# hold an exclusive handle on a log file and assert the Log pattern survives it.
if (Use-Unit 'u013-7-a-locked-log-must-not-kill-the') {
$logProbe = Register-Fx (Join-Path $env:TEMP ('logprobe-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.txt'))
'seed' | Set-Content $logProbe -Encoding UTF8
$fs = [IO.File]::Open($logProbe, 'Open', 'ReadWrite', 'None')   # 'None' = no sharing, exactly like a lock
try {
  $probeScript = @'
$ErrorActionPreference = 'Stop'
$log = $args[0]
function Log($m) {
  $line = ("[" + (Get-Date).ToString('s') + "] ") + $m
  for ($i = 0; $i -lt 5; $i++) { try { Add-Content -Path $log -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 120 } }
  try { Write-Host ('[log locked, not written] ' + $line) } catch {}
}
Log 'first'
Log 'second'
Write-Output 'SURVIVED'
'@
  $pf = Register-Fx (Join-Path $env:TEMP ('logprobe-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.ps1'))
  Set-Content $pf $probeScript -Encoding UTF8
  $out = (PSChild $pf $logProbe | ForEach-Object { [string]$_ }) -join ' '
  Remove-Item $pf -Force -ErrorAction SilentlyContinue
  if ($out -match 'SURVIVED') { Ok 'a locked log file does not kill the run (retry-then-continue Log pattern)' }
  else { Bad ('a locked log file still terminates the run: ' + $out) }
} finally { $fs.Close(); Remove-Item $logProbe -Force -ErrorAction SilentlyContinue }
# and assert every pipeline logger actually uses that pattern rather than a bare Add-Content
$bare = @()
foreach ($n in 'check-ad-cycles.ps1','run-daily-local.ps1','send-alert.ps1','bakers-daily-scan.ps1','weekly-post-capture.ps1') {
  $p = Join-Path $root $n
  if (-not (Test-Path $p)) { continue }
  $t = Get-Content $p -Raw
  $m = [regex]::Match($t, '(?ms)^function Log\(.*?^\}|^function Log\([^\r\n]*$')
  $body = if ($m.Success) { $m.Value } else { '' }
  if ($body -notmatch 'catch') { $bare += $n }
}
if ($bare.Count -eq 0) { Ok 'every pipeline logger retries instead of dying on a locked file' }
else { Bad ('these loggers still die on a locked log file: ' + ($bare -join ', ')) }
} # u013-7-a-locked-log-must-not-kill-the

# ---- the golden regression guard itself (added 2026-07-29) --------------------------------------------
# It sat RED for weeks and nobody noticed, because it was not hermetic: the harness froze the DATA but let
# the engine read the LIVE commodities.json/price-bands.json, so every ordinary rule edit registered as
# "drift". On 2026-07-29 it reported 66 differences and not one was a code bug. Now that the rules are
# pinned it can only fail on a CODE change - which makes it safe to run daily, and makes red mean something.
# Three checks: the guard is green, its founding-bug fixture still exists, and the hermetic seal is intact.
if (Use-Unit 'u014-the-golden-regression-guard-itself') {
$rt = PSChild (Join-Path $root 'regression-test.ps1') | ForEach-Object { [string]$_ }
if ($LASTEXITCODE -eq 0) { Ok 'golden regression guard is GREEN on the hermetic frozen inputs' }
else { Bad ('golden regression guard is RED - the engine changed a known-good number: ' + (($rt | Select-Object -Last 3) -join ' | ')) }

$cdSrc = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
if ($cdSrc -match 'must NOT divide') { Ok "the weight-package divisor's founding-bug fixture is still in -SelfTest" }
else { Bad 'the "(3 lb bag) in NAME must NOT divide" fixture has been removed from compare-deals -SelfTest - that is the bug the regression guard was written for ($0.33/lb onions), and without it a green run cannot be distinguished from a blind one' }

$rtSrc = Get-Content (Join-Path $root 'regression-test.ps1') -Raw
if ($rtSrc -match 'CommoditiesFile' -and $rtSrc -match 'BandsFile') { Ok 'regression harness still pins the RULES as well as the data (hermetic)' }
else { Bad 'regression-test.ps1 no longer passes -CommoditiesFile/-BandsFile from regression-inputs - the hermetic seal is broken and the guard will drift red on ordinary rule edits again, which is how it stopped being read the first time' }

Write-Output ''
} # u014-the-golden-regression-guard-itself
# ---------------------------------------------------------------- N. the ZERO-ROWS rule must stay armed
# guards.ps1 guard 11 printed "ok ... (0 rows checked)" for five days after Baker's moved to the Kroger API and
# its row filter stopped matching anything. "No violations found" and "no rows examined" are the same zero, so
# the estate's cheapest anti-blindness rule is: a check that examined nothing must WARN. OkUnlessBlind enforces
# it. If that helper is deleted, loses its warn branch, or stops being CALLED, every converted guard silently
# reverts to passing on an empty examination - so this fixture is the watcher over the anti-blindness rule.
if (Use-Unit 'u015-n-the-zero-rows-rule-must-stay-armed') {
$gs = Get-Content (Join-Path $root 'guards.ps1') -Raw
if ($gs -match 'function OkUnlessBlind') { Ok 'guards.ps1 still defines OkUnlessBlind (the zero-rows rule)' }
else { Bad 'guards.ps1 LOST OkUnlessBlind - a guard that examines zero rows can print ok again (the guard-11 class)' }
# the helper must still WARN on empty, not just print a different ok
$mOub = [regex]::Match($gs, 'function OkUnlessBlind[\s\S]{0,2000}?\r?\n\}')
if ($mOub.Success -and $mOub.Value -match '\$checked -gt 0' -and $mOub.Value -match '\$warn\.Add') {
  Ok 'OkUnlessBlind still gates on the examined count and warns when it is zero'
} else { Bad 'OkUnlessBlind no longer warns on a zero examined count - the rule is present but toothless' }
# and it must still be WIRED to the guards that were converted. A helper nothing calls protects nothing.
# Count CALL sites only: a call passes its count as a variable ("OkUnlessBlind $mpSeen"), while the definition
# is "function OkUnlessBlind([int]$checked..." with no space before the paren. Matching on the space-then-$
# form excludes the definition without a fudge subtraction (the first version subtracted 1 for a definition
# that was never in the count, and reported 1 when there were 2).
$oubCalls = ([regex]::Matches($gs, 'OkUnlessBlind\s+\$')).Count
if ($oubCalls -ge 2) { Ok ("zero-rows rule is wired into $oubCalls guard(s)") }
else { Bad ("OkUnlessBlind is called by only $oubCalls guard(s) - the conversions were reverted") }
# guard 10 specifically. It is the ONLY check that compares what we PUBLISH to what the store CHARGES, and it
# was the last converted-era guard still printing its ok line with a bare Say - so it could announce
# "(0 rows verified)" as a pass. MUST-FIRE: this reads Bad against any guards.ps1 where that call is gone.
if ($gs -match 'OkUnlessBlind \$checked') { Ok 'guard 10 (the only what-we-publish-vs-what-the-store-charges check) cannot print ok on zero rows' }
else { Bad 'guard 10 prints its ok line with a bare Say again - it can announce "0 rows verified" as a pass, which is the guard-11 class' }
# BEHAVIOURAL fixture, not just a source grep: run the real helper both ways in an isolated scope.
$oubProof = & {
  $warn = New-Object System.Collections.ArrayList
  $Quiet = $true
  function Say($s) { }
  Invoke-Expression $mOub.Value
  OkUnlessBlind 5 'examined something' 'BLIND-5'
  $afterNonZero = $warn.Count
  OkUnlessBlind 0 'examined nothing' 'BLIND-0'
  [pscustomobject]@{ nonZero = $afterNonZero; zero = $warn.Count; msg = [string]$warn[0] }
}
if ($oubProof.nonZero -eq 0 -and $oubProof.zero -eq 1 -and $oubProof.msg -eq 'BLIND-0') {
  Ok 'zero-rows fixture: a non-zero count stays silent, a zero count raises exactly the blind warning'
} else { Bad ("zero-rows fixture FAILED: nonZero-warns=$($oubProof.nonZero) zero-warns=$($oubProof.zero) msg='$($oubProof.msg)'") }
} # u015-n-the-zero-rows-rule-must-stay-armed

# ---------------------------------------------------------------- Nb. guards must iterate the ENGINE's file set
# Item 9 (2026-07-30): compare-deals unions Walmart across 14 days; guards.ps1 answered "which files does the
# board price from?" with "newest per store", leaving 332 live Walmart cells outside guards 5 and 10 - the two
# gates written to stop a 2x pack price and a price the store is not charging. The fix put the answer in ONE
# shared function, and then reopened itself one day wide by re-deriving the AS-OF from the wall clock while the
# engine resolves it against $ads.today (measured 2026-07-30 08:19: walmart-regular-2026-07-15.json, 711 rows,
# was priced into comparison-2026-07-29 and skipped by both guards). compare-deals -SelfTest proves the
# BEHAVIOUR; what can still rot is the WIRING, so check that here, the same way the zero-rows rule is checked.
if (Use-Unit 'u016-nb-guards-must-iterate-the-engine-s') {
$gsFs = Get-Content (Join-Path $root 'guards.ps1') -Raw
if ($gsFs -match 'Select-EngineRegularFiles') { Ok 'guards.ps1 still resolves its file set through the shared engine definition' }
else { Bad 'guards.ps1 no longer calls Select-EngineRegularFiles - guards 5 and 10 are back to guarding a different file set than the board was priced from (item 9, and its one-day-wide reopening)' }
$mEfs = [regex]::Match($gsFs, 'function EngineFileSet[\s\S]{0,1500}?\r?\n\}')
if ($mEfs.Success -and $mEfs.Value -notmatch 'Select-RegularFileSet') { Ok 'EngineFileSet does not re-derive the file set or its as-of locally' }
else { Bad 'EngineFileSet builds its own file set again instead of calling the shared definition - that is exactly how the engine''s 14-day union and the guards'' window drifted apart in the first place' }
} # u016-nb-guards-must-iterate-the-engine-s

# ---------------------------------------------------------------- N+1. batch importers must read UTF-8
# The four batch importers used a bare Get-Content, which in PS 5.1 decodes a UTF-8 capture as Windows-1252
# and then SAVES the damage - the same bug that shipped 16 mangled board rows on 2026-07-29, 6 of them crowns.
# Source-grep that they are wired, then PROVE the decode end to end on a real UTF-8-no-BOM file, because a
# grep alone passes on an importer that dot-sources capture-lib and then ignores it.
# import-browser-batch.ps1 was ARCHIVED 2026-07-30 (0 surviving rows, 0 live board cells, 0 executable
# references - Baker's is 100% kroger-api now), so it is off this list; a file in archive\ is not a live
# importer and demanding it here would fail from the day it was archived. import-aldi-batch is now a SHIM
# that forwards to import-instacart-batch, so it holds no capture read of its own - the read it must be
# checked for lives in the file it forwards to, which is on this list in its own right.
if (Use-Unit 'u017-n-1-batch-importers-must-read-utf-8') {
foreach ($imp in @('import-walmart-batch.ps1','import-instacart-batch.ps1')) {
  $ip = Join-Path $root $imp
  if (-not (Test-Path $ip)) { Bad ("$imp is missing - it was a live staples-expansion importer"); continue }
  $it = Get-Content $ip -Raw
  if ($it -match "Get-Content \(Join-Path \`$root \`$Raw\) -Encoding UTF8" -and $it -match 'capture-lib') {
    Ok "$imp reads its capture as UTF-8 and repairs mojibake"
  } else { Bad "$imp reads its capture with the default (ANSI) encoding again - the next staples batch will ship mangled names" }
}
# Behavioural: a UTF-8-no-BOM line with an umlaut must survive the read the importers now perform.
$tmpU = Register-Fx (Join-Path $env:TEMP ('utf8probe-' + [guid]::NewGuid().ToString('N') + '.txt'))
try {
  $UML = [char]0x00FC   # u-umlaut, built from a code point so THIS file stays pure ASCII
  $want = 'eggs' + "`t" + 'Deutsche K' + $UML + 'che German Style Sauerkraut~~$3.49'
  [IO.File]::WriteAllText($tmpU, $want, (New-Object Text.UTF8Encoding($false)))   # no BOM, as a Blob download is
  $viaDefault = Get-Content $tmpU | Select-Object -First 1
  $viaUtf8    = Get-Content $tmpU -Encoding UTF8 | Select-Object -First 1
  if ($viaDefault -eq $want) {
    Ok 'utf8 fixture inconclusive on this box (ANSI read did not corrupt) - encoding assertion still enforced by the greps above'
  } elseif ($viaUtf8 -eq $want) {
    Ok 'utf8 fixture: the default read DOES corrupt an umlaut and the -Encoding UTF8 read the importers now use does not'
  } else { Bad 'utf8 fixture: -Encoding UTF8 did not round-trip an umlaut - the importer fix does not actually work here' }
} catch { Bad ('utf8 fixture threw: ' + $_.Exception.Message) }
finally { if (Test-Path $tmpU) { Remove-Item -LiteralPath $tmpU -Force -ErrorAction SilentlyContinue } }
} # u017-n-1-batch-importers-must-read-utf-8

# ---------------------------------------------------------------- N+2. allowlist-rot must cover ALL allowlists
# basis-reconcile-allowlist.json was omitted from guards' hygiene loop, and it is the one that suppresses
# FACTOR-level basis conflicts - the class that decides which store the board calls cheapest. It was therefore
# the only allowlist entries could age in forever with no expiry pressure at all.
if (Use-Unit 'u018-n-2-allowlist-rot-must-cover-all') {
$gtxt = Get-Content (Join-Path $root 'guards.ps1') -Raw
foreach ($al in @('multipack-allowlist.json','coverage-gap-allowlist.json','basis-reconcile-allowlist.json')) {
  if ($gtxt -match [regex]::Escape($al)) { Ok "allowlist-rot check still covers $al" }
  else { Bad "$al dropped out of guards' allowlist-rot loop - stale suppressions in it become invisible" }
}
# And every allowlist on disk must still expose a key the extractor recognises. A file that renamed its list
# would yield zero entries and the rot check would report a clean bill of health for a list it never opened.
foreach ($al in @('multipack-allowlist.json','coverage-gap-allowlist.json','basis-reconcile-allowlist.json')) {
  $ap = Join-Path $root $al
  if (-not (Test-Path $ap)) { continue }
  try {
    $ad = Read-JsonFile $ap
    if ($ad.PSObject.Properties['allow'] -or $ad.PSObject.Properties['gaps']) { Ok "$al still exposes a recognised entry list" }
    else { Bad "$al exposes neither .allow nor .gaps - guards' rot check is scanning ZERO entries from it" }
  } catch { Bad "$al does not parse: $($_.Exception.Message)" }
}
} # u018-n-2-allowlist-rot-must-cover-all

# ---------------------------------------------------------------- N+2b. guard 6 must NAME the stores it skipped
# FOUNDING BUG (found 2026-07-30): guard 6 ("a store's data collapsed") opened with `if ($files.Count -lt 2)
# { continue }` - a SILENT skip - and then printed "ok  no store's newest data file collapsed vs its recent
# history". On the live tree that skipped exactly one store, sams, whose single out\regular capture
# (sams-regular-2026-07-14.json, 60 rows) is IN the engine's file set and is the only possible source of 29
# published Sam's cells, 9 of them crowned CHEAPEST. So the one store guard 6 could not evaluate was the one
# carrying unrefreshable prices, and its own ok line said so to nobody. Same zero-rows collapse as guard 11:
# "no collapse found" and "no store examined" read identically.
# The decision now lives in Get-CollapseVerdict so it can be exercised directly. Frozen synthetic inputs only.
if (Use-Unit 'u019-n-2b-guard-6-must-name-the-stores-it') {
if ($gtxt -match 'function Get-CollapseVerdict') { Ok 'guards.ps1 defines Get-CollapseVerdict (guard 6''s decision is testable)' }
else { Bad 'guards.ps1 LOST Get-CollapseVerdict - guard 6''s <2-capture skip is unfixtured again' }
if (([regex]::Matches($gtxt, 'Get-CollapseVerdict\s+\$')).Count -ge 2) { Ok 'Get-CollapseVerdict is wired into guard 6 for BOTH the skip and the collapse decision' }
else { Bad 'Get-CollapseVerdict is not called twice by guard 6 - the silent `continue` or the collapse test was inlined again' }
if ($gtxt -match 'g6NoHistory' -and $gtxt -match 'OkUnlessBlind \$g6Checked') { Ok 'guard 6 reports its examined count and names the stores it could not evaluate' }
else { Bad 'guard 6 no longer reports g6Checked / g6NoHistory - it can print ok again while skipping a store in silence' }
$mCv = [regex]::Match($gtxt, 'function Get-CollapseVerdict[\s\S]{0,4000}?\r?\n\}')
if (-not $mCv.Success) { Bad 'could not extract Get-CollapseVerdict from guards.ps1 - the behavioural fixture below cannot run' }
else {
  $cv = & {
    Invoke-Expression $mCv.Value
    [pscustomobject]@{
      # MUST-FIRE 1: the founding silent skip - one capture, no history (the live sams shape).
      noHistory = (Get-CollapseVerdict 1 0 0)
      # MUST-FIRE 2: the founding collapse - family-fare-regular-<date>.PARTIAL.json, 177 rows -> 55.
      collapsed = (Get-CollapseVerdict 5 55 177)
      # CLEAN TWIN 1: an ordinary healthy refresh must stay silent.
      healthy   = (Get-CollapseVerdict 5 170 177)
      # CLEAN TWIN 2: under the 100-row floor the ratio is noise - must NOT be called a collapse.
      belowFloor = (Get-CollapseVerdict 5 20 60)
    }
  }
  if ($cv.noHistory -eq 'no-history' -and $cv.collapsed -eq 'collapsed' -and $cv.healthy -eq 'ok' -and $cv.belowFloor -eq 'ok') {
    Ok 'guard-6 fixture: a single capture reports no-history (was a silent skip), a halved file collapses, a healthy file and a below-floor file stay silent'
  } else {
    Bad ("guard-6 fixture FAILED: noHistory='$($cv.noHistory)' collapsed='$($cv.collapsed)' healthy='$($cv.healthy)' belowFloor='$($cv.belowFloor)'")
  }
}
} # u019-n-2b-guard-6-must-name-the-stores-it

# ---------------------------------------------------------------- N+2c. guard 9 must not let an ALT FEED mask a live capture's age
# FOUNDING BUG (found 2026-07-30): guard 9 redirects a store's freshness to its alt feed when that feed is
# newer (the 2026-07-29 fix, so Sam's would stop being aged on out\regular). It overwrote $fileDate wholesale,
# on the stated belief that the out\regular file left behind is an unused orphan. It is not: Select-RegularFileSet
# hands the engine the NEWEST dated capture for every store in out\regular and sams has exactly ONE, so
# sams-regular-2026-07-14.json is in the engine's file set. Guard 9 therefore printed "Sam's Club ... file 1d
# old" for a 16-day-old price set, and its >14-day HARD FAIL could never reach those rows - no pull writes that
# file, so no successful run could ever age or refresh it.
# Measured on the 2026-07-29 AND 2026-07-30 boards alike: 29 published Sam's cells name a product that exists
# in that capture and nowhere in the 2,475-row live out\sams feed, and 9 of those commodities crown Sam's
# CHEAPEST - so the rows are load-bearing and the masked age was a real, published staleness.
if (Use-Unit 'u020-n-2c-guard-9-must-not-let-an-alt') {
if ($gtxt -match 'function Test-MaskedStaleCapture') { Ok 'guards.ps1 defines Test-MaskedStaleCapture (the masked-age rule)' }
else { Bad 'guards.ps1 LOST Test-MaskedStaleCapture - a live out\regular capture can be aged by its alt feed again' }
if ($gtxt -match 'Test-MaskedStaleCapture \$') { Ok 'the masked-age rule is CALLED from guard 9''s redirect branch' }
else { Bad 'Test-MaskedStaleCapture is defined but never called - the rule is present and toothless' }
$mMs = [regex]::Match($gtxt, 'function Test-MaskedStaleCapture[\s\S]{0,4000}?\r?\n\}')
if (-not $mMs.Success) { Bad 'could not extract Test-MaskedStaleCapture from guards.ps1 - the behavioural fixture below cannot run' }
else {
  $t0 = [datetime]'2026-07-30'
  $ms2 = & {
    Invoke-Expression $mMs.Value
    [pscustomobject]@{
      # MUST-FIRE: the founding case. A 2026-07-14 capture, still priced from, masked by a 2026-07-29 feed.
      founding = (Test-MaskedStaleCapture ([datetime]'2026-07-14') ([datetime]'2026-07-29') $t0 $true 14)
      # CLEAN TWIN 1: same dates, but the file is NOT in the engine's file set - a true orphan. Ageing it
      # would be crying wolf, and this is the twin that proves we do not.
      trueOrphan = (Test-MaskedStaleCapture ([datetime]'2026-07-14') ([datetime]'2026-07-29') $t0 $false 14)
      # CLEAN TWIN 2: the live Baker's/Fareway shape - regular and alt captured the same day, no redirect at
      # all, so the ordinary age test already covered it. Measured 2026-07-30: both stores look exactly so.
      noRedirect = (Test-MaskedStaleCapture ([datetime]'2026-07-29') ([datetime]'2026-07-29') $t0 $true 14)
      # CLEAN TWIN 3: redirected AND live, but inside the 14-day cliff - not stale, must stay silent.
      withinCliff = (Test-MaskedStaleCapture ([datetime]'2026-07-25') ([datetime]'2026-07-29') $t0 $true 14)
    }
  }
  if ($ms2.founding -and (-not $ms2.trueOrphan) -and (-not $ms2.noRedirect) -and (-not $ms2.withinCliff)) {
    Ok 'guard-9 masked-age fixture: a still-priced-from capture masked by a newer alt feed is aged, while a true orphan, an unredirected store and a within-cliff capture all stay silent'
  } else {
    Bad ("guard-9 masked-age fixture FAILED: founding=$($ms2.founding) trueOrphan=$($ms2.trueOrphan) noRedirect=$($ms2.noRedirect) withinCliff=$($ms2.withinCliff)")
  }
}
} # u020-n-2c-guard-9-must-not-let-an-alt

# ---------------------------------------------------------------- N+3. -Accept must respect DROP verdicts
# audit-match-soundness -Accept used to bless the current name->commodity map wholesale, converting "judged
# wrong last week" into "reviewed and correct" - which is how bacon/Sam's and broccoli/Sam's, each dropped by
# the verify pass in THREE separate weeks, got baselined and published as crowns on 2026-07-29.
if (Use-Unit 'u021-n-3-accept-must-respect-drop') {
$ms = Get-Content (Join-Path $root 'audit-match-soundness.ps1') -Raw
if ($ms -match 'ACCEPT REFUSED' -and $ms -match 'verify-verdicts-\*\.json') { Ok '-Accept still carries the DROP-verdict gate' }
else { Bad 'audit-match-soundness -Accept lost its DROP-verdict gate - it is a rubber stamp again' }
if ($ms -match '\$ForceAccept') { Ok 'the override is the explicit -ForceAccept switch, not silence' }
else { Bad '-ForceAccept is gone - either the gate cannot be overridden at all (people will edit it out) or it no longer exists' }
# Behavioural: the SHARED quote recovery must capture a full apostrophe-bearing product name. The pattern
# lives in verdict-lib.ps1 (shared by the -Accept gate AND verify-apply's suppressions - both must agree on
# what "the same item" means), so the fixture dot-sources the lib and calls the REAL function rather than a
# copy. A naive [^']+ capture truncates "Member's ..." at the possessive and fails SILENT - the gate
# under-blocks on exactly the Member's Mark rows the founding bug was about.
if (-not (Test-Path (Join-Path $root 'verdict-lib.ps1'))) { Bad 'verdict-lib.ps1 is missing - the -Accept gate and verify-apply have lost their shared item-identity definition' }
else {
  $probe = & {
    . (Join-Path $root 'verdict-lib.ps1')
    return (Get-VerdictQuotedItem "TEST: 'Member's Mark Pinto Beans 12 lbs.' is a 12-lb bag of DRY pinto beans.")
  }
  if ($probe -eq "Member's Mark Pinto Beans 12 lbs.") { Ok 'verdict-lib quote capture survives an apostrophe in the product name' }
  else { Bad ("verdict-lib quote capture truncates at the apostrophe again - captured '" + $probe + "'") }
  if ($ms -match 'verdict-lib\.ps1') { Ok 'the -Accept gate sources verdict-lib (one definition of item identity)' }
  else { Bad 'audit-match-soundness no longer sources verdict-lib - the gate and verify-apply can disagree on what "the same item" means' }
}
} # u021-n-3-accept-must-respect-drop
# The END-TO-END half of this section (does the gate block the item the verdict actually JUDGED?) runs as
# fixture case (m) further down, because NewFxDir/RunPSAt are not defined until line ~621. Search
# 'verdict identity MUST-FIRE'.

# ---------------------------------------------------------------- N+4. the Walmart batch importer's invariants
# 2026-07-25: import-walmart-batch.ps1 was a SECOND Walmart writer with its own weaker size math (backed the
# size out of the unit price and rounded to ONE decimal; no engine check, no multipack filter). 6 of the 23
# rows it put inside the 14-day union window failed the builder's engine-reproduces-the-unit-price invariant
# by 3.3-7.1%, and one was CROWNED cheapest on the 2026-07-29 board (brown-gravy-mix $0.5333/oz vs Walmart's
# real $0.552/oz). Its -SelfTest now carries the frozen founding-bug row (the shipped 0.9-oz shape MUST fail
# the engine tolerance), the 2026-07-27 fish-sauce override, and the guard-5 multipack lockstep. Prove the
# fixture still fires, and that the importer runs the builder's OWN Build-Row, from its one home in
# walmart-row-lib.ps1, instead of re-forking it.
if (Use-Unit 'u022-n-4-the-walmart-batch-importer-s') {
$r = RunPS 'import-walmart-batch.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'MUST-FIRE' -and $r.text -match 'SELF-TEST PASS') { Ok 'import-walmart-batch verifies every batch row through the builder invariants (founding-bug fixture fires)' }
else { Bad ('import-walmart-batch -SelfTest failed or lost its founding-bug fixture: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$iwSrc = Get-Content (Join-Path $root 'import-walmart-batch.ps1') -Raw
$bwSrc = Get-Content (Join-Path $root 'build-walmart-deals.ps1') -Raw
$wrlPath = Join-Path $root 'walmart-row-lib.ps1'
$wrlSrc = if (Test-Path $wrlPath) { Get-Content $wrlPath -Raw } else { '' }
# ONE HOME, NOW BY DOT-SOURCE (2026-09-11). Until then the importer LIFTED Build-Row and six helpers out of
# build-walmart-deals.ps1's source off a hand-maintained list, and this check pinned the two ends of that
# list. Build-Row lives in walmart-row-lib.ps1 now and BOTH Walmart writers dot-source it, so the property is
# restated for the new shape: each writer dot-sources the library, the library defines Build-Row, the
# builder no longer defines its own (a second home is a fork), and the importer no longer reads the builder
# as text (a leftover lift would run a second copy). Each half is its own line, so a failure names itself.
$wrlDotRx = "(?m)^\.\s*\(Join-Path\s+\`$root\s+'walmart-row-lib\.ps1'\)"
if ($iwSrc -match $wrlDotRx -and $bwSrc -match $wrlDotRx) { Ok 'import-walmart-batch and build-walmart-deals both dot-source Build-Row from walmart-row-lib.ps1 (one home, no fork)' }
else { Bad 'a Walmart writer no longer dot-sources walmart-row-lib.ps1 - the second writer has re-forked the size math or gone back to lifting it (the 2026-07-25 class)' }
if ($wrlSrc -match '(?m)^function\s+Build-Row\s*\(' -and $bwSrc -notmatch '(?m)^function\s+Build-Row\s*\(') { Ok 'Build-Row is defined in walmart-row-lib.ps1 and nowhere in build-walmart-deals.ps1' }
else { Bad 'Build-Row is missing from walmart-row-lib.ps1 or defined again in build-walmart-deals.ps1 - two homes for the Walmart size math' }
if ($iwSrc -notmatch "Get-Content\s+\(Join-Path\s+\`$root\s+'build-walmart-deals\.ps1'\)") { Ok 'import-walmart-batch no longer reads build-walmart-deals.ps1 as source text (the lift is gone, not doubled)' }
else { Bad 'import-walmart-batch reads build-walmart-deals.ps1 as text again - a lift beside the dot-source runs a second copy of Build-Row' }
} # u022-n-4-the-walmart-batch-importer-s

