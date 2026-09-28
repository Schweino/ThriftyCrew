# ad-line-provenance-8d.ps1 - test-guards.ps1 section 8d, dot-sourced at its old place (split 2026-09-28).
# Runs in test-guards.ps1's scope: Check, Skip, FailEvidence, $script:failed and the fixture paths come from there.
# ---- 8d. AD-LINE PRICE PROVENANCE: the $0.10 laundry pod (2026-09-07, queue 2026-09-07-05e4c3) --------
# Hy-Vee's ad arrives as prose, so the engine reads the first money-shaped token anywhere in the line and a
# fuel-saver reward wearing a cent sign became a price. "Gain Flings, EARN 10c OFF PER GALLON, ... $12.94"
# published at $0.10 a pod and HELD THE laundry-pods CROWN for six days on the live board. Guard 10, the
# only check that compares what we publish to what a store charges, is structurally blind to it: it needs
# the row's own current_price and a Hy-Vee ad row does not carry one.
# THE ROW IS FROZEN, taken verbatim off comparison-2026-09-06 (the board that was live while it was wrong).
# It is planted onto a real ad-line cell rather than rebuilt from today's board, because the parser fix in
# compare-deals means today's board no longer contains it - and a fixture regenerated from live data would
# have nothing to find.
$g8dCmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') |
  Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1).FullName
$g8dBak = Backup $g8dCmpF
$g8dDoc = $g8dBak | ConvertFrom-Json
$g8dCent = [string][char]0x00A2
# the cells to plant on: Hy-Vee weekly-ad cells whose ad text IS the item line (that is what the guard
# scopes to) and which carry no product url, so nothing about name-drift or tile integrity moves.
$g8dCells = @()
foreach ($g8dRow in @($g8dDoc.comparison)) {
  foreach ($g8dS in @($g8dRow.stores)) {
    if (([string]$g8dS.source_ad) -ne 'Weekly Ad') { continue }
    if (([string]$g8dS.ad) -ne ([string]$g8dS.item)) { continue }
    if ($g8dS.PSObject.Properties['url'] -and $g8dS.url) { continue }
    $g8dCells += $g8dS
  }
}
if ($g8dCells.Count -lt 2) {
  Skip 'ad-line provenance: fewer than two Hy-Vee weekly-ad cells on the board, so the guard could not be exercised - it scopes to cells whose ad text IS the item line'
} else {
  function Set-G8dCell($cell, [string]$line, [double]$pu, [string]$basis) {
    $cell.item = $line; $cell.ad = $line; $cell.per_unit = $pu; $cell.basis = $basis; $cell.note = ''
  }
  # MUST FIRE - the founding row, exactly as it was published.
  $g8dLine = 'Gain Flings, EARN 10' + $g8dCent + ' OFF PER GALLON, -3.00 off with manufacturer''s digital coupon, $12.94'
  Set-G8dCell $g8dCells[0] $g8dLine 0.1 'per-each'
  ($g8dDoc | ConvertTo-Json -Depth 8) | Set-Content $g8dCmpF -Encoding UTF8
  Check 'ad-line provenance: a fuel-saver reward published as the price ($0.10 a pod against a $12.94 line)' 2 'ad-line price provenance'
  # MUST FIRE - the SECOND founding row (2026-09-18, queue 2026-09-18-f90ba6), frozen verbatim off
  # comparison-2026-09-17 as the OLD engine published it: a "SAVE 50c" savings read as the price, Hy-Vee
  # donuts at $0.50/each against the line's own $1.99. It and its protein-bars twin held the board from 09-14
  # to 09-18. The parser now strips SAVE-cents and coupon clauses and never reads a cents token beside a $
  # amount, so today's board no longer carries it; planted, the guard must still name it.
  $g8dLine2 = 'Hy-Vee mini donuts, SAVE 50' + $g8dCent + ', $1.99'
  Set-G8dCell $g8dCells[0] $g8dLine2 0.5 'per-each'
  ($g8dDoc | ConvertTo-Json -Depth 8) | Set-Content $g8dCmpF -Encoding UTF8
  Check 'ad-line provenance: a SAVE-cents savings published as the price ($0.50 a donut against a $1.99 line)' 2 'ad-line price provenance'
  # THE THIRD FOUNDING ROW (2026-09-28, queue 2026-09-28-b61b08), frozen verbatim off the 09-28 Hy-Vee ad: a
  # PERKS line. Brad's decision (c) (b3afe6953) publishes the $1.98 member price on a cell gated 'Perks
  # membership required'; the guard used to read the LAST token ($2.48, the non-member price) and withheld the
  # correctly priced cell. Guard and engine now share Get-TcPerksPrice, so:
  #   MUST FIRE - the line published at its NON-MEMBER price $2.48 (the engine read the wrong price);
  #   MUST FIRE - the line published at $1.98 with NO membership gate (the ruling's other half broken).
  # Its CLEAN TWIN, the same line at $1.98 with the gate, rides in the MUST NOT FIRE run below.
  function Set-G8dMember($cell, [bool]$on) {
    $lbl = if ($on) { 'Perks membership required' } else { '' }
    $cell | Add-Member -NotePropertyName membership -NotePropertyValue $on -Force
    $cell | Add-Member -NotePropertyName member_label -NotePropertyValue $lbl -Force
  }
  $g8dPerks = 'Bud by Dole celery hearts, SAVE! .50, $1.98 PERKS PRICES, NON- MEMBER PRICE $2.48'
  Set-G8dCell $g8dCells[0] $g8dPerks 2.48 'per-each'; Set-G8dMember $g8dCells[0] $true
  ($g8dDoc | ConvertTo-Json -Depth 8) | Set-Content $g8dCmpF -Encoding UTF8
  Check 'ad-line provenance: a Perks line published at its NON-MEMBER price ($2.48 celery where the ruled price is $1.98 Perks)' 2 'ad-line price provenance'
  Set-G8dCell $g8dCells[0] $g8dPerks 1.98 'per-each'; Set-G8dMember $g8dCells[0] $false
  ($g8dDoc | ConvertTo-Json -Depth 8) | Set-Content $g8dCmpF -Encoding UTF8
  Check 'ad-line provenance: a Perks member price ($1.98 celery) published WITHOUT the membership gate' 2 'without the membership gate'
  Set-G8dMember $g8dCells[0] $false
  # MUST NOT FIRE and CLEAN TWIN in one run, because each of these costs a full guards pass.
  #   MUST NOT FIRE - a real cents PRICE. "Bananas, 49c lb." IS quoted in cents and the cents token IS the
  #                   line's last money token, so a guard that simply distrusted cent signs would cry wolf
  #                   on every banana ad in Omaha.
  #   CLEAN TWIN    - the adjacent behaviour the fix was most likely to break: a per-N-pack cell, where the
  #                   published per-unit is the line's price DIVIDED by a count, must still reconcile.
  #                   Frozen from the same Hy-Vee ad: storage bags, 100 ct, $2.99 -> 0.0299 each.
  Set-G8dCell $g8dCells[0] ('Bananas, 49' + $g8dCent + ' lb.') 0.49 'per-lb marker'
  Set-G8dCell $g8dCells[1] 'Hy-Vee storage bags, 75 to 100 ct., $2.99' 0.0299 'per-100-pack'
  #   CLEAN TWIN    - the 09-28 Perks celery line at the RULED price, $1.98 per-each, gated. Planted on a
  #                   third cell when the board has one; the run asserts the guard counted it as a Perks line.
  $g8dPerksTwin = ($g8dCells.Count -ge 3)
  if ($g8dPerksTwin) { Set-G8dCell $g8dCells[2] $g8dPerks 1.98 'per-each'; Set-G8dMember $g8dCells[2] $true }
  else { Skip 'ad-line provenance CLEAN TWIN (Perks celery at $1.98, gated): fewer than three plantable Hy-Vee ad-line cells' }
  ($g8dDoc | ConvertTo-Json -Depth 8) | Set-Content $g8dCmpF -Encoding UTF8
  # ASSERT THIS GUARD'S OWN VERDICT, NOT THE SUITE'S EXIT CODE (2026-09-07). A must-not-fire written as
  # "expect exit 0" is hostage to every other invariant in a 31-run mutating suite: the first version of
  # this case failed while the ad-line check was correctly SILENT, because audit-tile-integrity was red
  # from an earlier case's prune (it rewrites product-urls.json, which stales name-drift.json - the chain
  # itself re-runs name-drift for exactly that reason, and this suite does not). Reading the guard's own
  # OK line proves it ran AND stayed quiet, which is the whole claim; the HARD FAIL check proves it is
  # not merely absent from the output.
  $g8dOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') | ForEach-Object { [string]$_ }) -join "`n"
  RestoreGuardState   # the fifth child-run site: it does not go through Check*, so it needs its own call
  $g8dOk    = ($g8dOut -match 'every ad-line cell publishes the price its own ad line quotes last')
  $g8dFired = ($g8dOut -match 'HARD FAIL: ad-line price provenance')
  # the Perks twin must have been READ as a Perks line, not skipped: "0 of them Perks lines" is a silent twin
  $g8dTwinSilent = ($g8dPerksTwin -and $g8dOk -and -not $g8dFired -and ($g8dOut -notmatch '[1-9]\d* of them Perks lines'))
  if ($g8dTwinSilent) {
    Write-Output '  FAIL  ad-line provenance CLEAN TWIN: the gated Perks celery cell ($1.98) was not read as a Perks line - the guard skipped it, so its silence proves nothing'
    FailEvidence $g8dOut; $script:failed++
  } elseif ($g8dOk -and -not $g8dFired) {
    Write-Output '  PASS  ad-line provenance MUST NOT FIRE + CLEAN TWIN: a real cents price (Bananas, 49c lb.) and a per-100-pack cell (storage bags, $2.99) both reconcile and the guard stays silent'
    $script:pass++
  } elseif (-not $g8dOk -and -not $g8dFired) {
    Write-Output '  FAIL  ad-line provenance: the guard printed NEITHER its ok line nor a finding - it did not run, so its silence proves nothing'
    FailEvidence $g8dOut; $script:failed++
  } else {
    Write-Output '  FAIL  ad-line provenance MUST NOT FIRE: a real cents price or a per-100-pack cell was reported as a wrong ad-line price - the guard is crying wolf'
    FailEvidence $g8dOut; $script:failed++
  }
  RestoreNow $g8dCmpF
}

