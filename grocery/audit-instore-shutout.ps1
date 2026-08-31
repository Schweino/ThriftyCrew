<#
  audit-instore-shutout.ps1 - "this store returned rows, and the gate refused every one of them".

  WHY THIS EXISTS (2026-08-31). The in-store gate (instore-lib.ps1) is right and it is working: a row
  shipped from a fulfilment centre is not an Omaha shelf price, and admitting one is a false provenance
  claim. But a commodity where the gate refuses EVERY row from a store looks, to everything downstream,
  exactly like a commodity that store does not carry - and this estate has already paid for that
  confusion once. no-board-price-ok.json answers "may this skip board pricing?" by asking "is it
  carried?", and on 2026-08-31 an FC-only Walmart listing leaving the board took cost-recipes.ps1 down
  catalogue-wide and cost a live paid recipe its page.

  SUMAC IS THE PROOF THAT SHUTOUT != ABSENCE. It was ruled CARRIED on 2026-08-22 by a human who looked
  at the shelf. Today's Walmart capture returns three genuine sumac products and every one is FC or
  MARKETPLACE. If a shutout were allowed to read as absence, a standing human ruling would be
  overturned by a search-ranking artifact.

  WHAT THE 19 ACTUALLY ARE, measured 2026-08-31 and recorded so the next reader does not re-derive it.
  They are NOT one failure, they are two:

    CLASS A - the term never surfaces fresh produce AT WALMART (11 terms). walmart.com's relevance
      returns the national long-tail catalogue instead of the L St store's fresh SKU:
        acorn squash -> garden SEEDS          eggplant     -> a JAR of roasted eggplant
        mustard greens -> microgreen SEEDS    papaya       -> digestive-enzyme SUPPLEMENTS
        plantains -> plantain CHIPS           poblano      -> DRIED chili pods
        rutabaga -> turnip SEEDS              swiss chard  -> live plants and seeds
        fennel bulb -> fennel SEED            fresh artichokes -> JARRED hearts
      This is Walmart-specific, NOT a bad term: the SAME term returns real rows at other stores
      (eggplant 7 at Baker's, papaya 15, plantains 8; acorn squash 10 and artichokes 9 at Aldi).
      And it is NOT a produce blindness in the lane: carrots came back 21 of 21 STORE, brussels
      sprouts 15 of 15, green bell pepper 7 of 7.

    CLASS B - the RIGHT product, shipped only (8 terms). cayenne pepper, ground ginger, whole nutmeg,
      cumin seeds, saffron threads, mace spice, sumac, garlic infused oil all return the correct food
      under correct names; only the shipped listings rank. The shelf SKU exists and is not surfacing.

  A NOTE ON WHAT THIS IS NOT. The 19 all sit late in the pull (positions 356-571 of 580), which looks
  like a capture that degraded. It is not. build-pull-order.ps1 sorts terms into SHOPPER-VALUE order on
  purpose so a bot wall costs the long tail instead of the staples, so the tail is late BY DESIGN and
  rarer foods legitimately return fewer rows. That hypothesis was checked and dropped.

  SO THIS GUARD DOES ONE THING: it keeps the list visible and refuses to let it grow unnoticed. It does
  NOT rule on carriage - it is the shortlist a human reads before anyone promotes a NOT-CARRIED verdict
  on the strength of a store's silence, exactly as audit-search-terms.ps1 is for wrong terms. That
  auditor cannot see this class: it asks whether returned rows contain the commodity's distinguishing
  word, and "Roasted Eggplant, 24 oz Glass Jar" contains "eggplant".

  Usage:
    .\audit-instore-shutout.ps1              check (exit 1 if the shutout set GREW)
    .\audit-instore-shutout.ps1 -List        print the current set and exit 0
    .\audit-instore-shutout.ps1 -SelfTest
#>
# -BaselineSpec is a quote-free 'store=count[;store=count]' string, NOT a hashtable: a hashtable
# cannot cross a `powershell -File` argument boundary, and PS 5.1 strips embedded double quotes
# from a native exe's arguments, so a JSON literal would not survive either. The self-test drives
# the live ratchet through this.
param([switch]$SelfTest, [switch]$List, [string]$OutDir = '', [string]$BaselineSpec = '')

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'instore-lib.ps1')

# The measured set, 2026-08-31, walmart-regular-2026-08-31 (11,694 rows, 580 terms). A term may LEAVE
# this list freely - that is the lane improving. A term ARRIVING is a new silent hole and goes red.
$script:BASELINE = @{
  'Walmart' = 19
}

function Get-Shutouts {
  <# Per store: terms whose rows ALL fail the in-store gate. A term with no rows at all is NOT a
     shutout - that is an empty search, which audit-search-terms.ps1 owns. #>
  param([string]$Dir)
  $out = @()
  $newest = @{}
  foreach ($f in @(Get-ChildItem (Join-Path $Dir '*-regular-*.json') -File -ErrorAction SilentlyContinue)) {
    if ($f.BaseName -notmatch '^(.+)-regular-(\d{4}-\d{2}-\d{2})$') { continue }
    $store = $Matches[1]; $date = $Matches[2]
    if (-not $newest.ContainsKey($store) -or $date -gt $newest[$store].date) {
      $newest[$store] = [pscustomobject]@{ date = $date; path = $f.FullName }
    }
  }
  foreach ($store in ($newest.Keys | Sort-Object)) {
    $doc = $null
    try { $doc = Get-Content $newest[$store].path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    $rows = @($doc.deals)
    if (-not $rows.Count) { continue }
    # NO "skip a store with no signal" CHECK HERE, and its absence is deliberate. The first cut had one.
    # Neutering it left every case green, because it CANNOT fire: Test-InStore admits an absent
    # fulfillment (see instore-lib.ps1 - absent signal is not a verdict), so every row of a signal-less
    # capture counts as shelf, shelf always equals total, and no term can ever be a shutout. Dead code
    # that reads like a safeguard teaches the next reader that something is defended when nothing is.
    # What the store DOES need is to be named as unmeasurable rather than silently counted as clean, so
    # it is reported below instead of skipped here.
    $signal = @($rows | Where-Object { ('' + $_.fulfillment).Trim() }).Count
    $byTerm = @{}
    foreach ($r in $rows) {
      $t = ('' + $r.found_by_term).Trim()
      if (-not $t) { continue }
      if (-not $byTerm.ContainsKey($t)) { $byTerm[$t] = [pscustomobject]@{ total = 0; shelf = 0 } }
      $byTerm[$t].total++
      if (Test-InStore $r.fulfillment) { $byTerm[$t].shelf++ }
    }
    if ($signal -eq 0) {
      $out += [pscustomobject]@{ store = $store; term = '(no fulfillment signal)'; rows = $rows.Count
                                 date = $newest[$store].date; blind = $true }
    }
    foreach ($t in ($byTerm.Keys | Sort-Object)) {
      if ($byTerm[$t].total -gt 0 -and $byTerm[$t].shelf -eq 0) {
        $out += [pscustomobject]@{ store = $store; term = $t; rows = $byTerm[$t].total
                                   date = $newest[$store].date; blind = ($signal -eq 0) }
      }
    }
  }
  return @($out)
}

# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $t = Join-Path ([IO.Path]::GetTempPath()) ('shutout-' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Force $t)
  try {
    $U8 = New-Object System.Text.UTF8Encoding($false)
    function Cap($store, $date, $deals) {
      [IO.File]::WriteAllText((Join-Path $t ("{0}-regular-{1}.json" -f $store, $date)),
        (ConvertTo-Json ([ordered]@{ store = $store; deals = $deals }) -Depth 6), $U8)
    }
    Cap 'zed' '2026-08-31' @(
      [ordered]@{ found_by_term = 'carrots';  fulfillment = 'STORE' },
      [ordered]@{ found_by_term = 'carrots';  fulfillment = 'FC' },
      [ordered]@{ found_by_term = 'eggplant'; fulfillment = 'FC' },
      [ordered]@{ found_by_term = 'eggplant'; fulfillment = 'MARKETPLACE' })
    $r = @(Get-Shutouts -Dir $t)
    T 'a term whose rows are ALL refused is a shutout' (@($r | Where-Object { $_.term -eq 'eggplant' }).Count -eq 1) (($r | ForEach-Object { $_.term }) -join ',')
    T 'MUST NOT FIRE  a term with even ONE shelf row is not a shutout' (@($r | Where-Object { $_.term -eq 'carrots' }).Count -eq 0) (($r | ForEach-Object { $_.term }) -join ',')
    T '...and the row count travels with it' ((@($r | Where-Object { $_.term -eq 'eggplant' })[0]).rows -eq 2) ([string](@($r | Where-Object { $_.term -eq 'eggplant' })[0]).rows)

    # A capture with NO fulfillment field anywhere cannot be measured, and must SAY SO rather than
    # report a clean zero. (The earlier "it is skipped" assertion was vacuous - a signal-less capture
    # can never produce a shutout anyway, so it passed with the check neutered.)
    Cap 'old' '2026-08-01' @(
      [ordered]@{ found_by_term = 'sumac' },
      [ordered]@{ found_by_term = 'sumac' })
    $r = @(Get-Shutouts -Dir $t)
    T 'MUST FIRE  a capture with NO fulfillment signal is named UNMEASURABLE, not counted clean' `
      (@($r | Where-Object { $_.store -eq 'old' -and $_.blind }).Count -eq 1) (($r | ForEach-Object { $_.store + ':' + $_.term }) -join ',')
    T '...and no ordinary shutout is invented for it' `
      (@($r | Where-Object { $_.store -eq 'old' -and -not $_.blind }).Count -eq 0) (($r | ForEach-Object { $_.store + ':' + $_.term }) -join ',')

    # Only the NEWEST capture per store counts. ASSERTED ON THE DATE, not only on the absent term:
    # the first version checked just that a stale-only term was missing, which stayed green when the
    # selection was neutered, because one file per store is read either way and name order already
    # happened to pick the newest.
    Cap 'zed' '2026-08-30' @([ordered]@{ found_by_term = 'kale'; fulfillment = 'FC' })
    $r = @(Get-Shutouts -Dir $t)
    T 'MUST NOT FIRE  a term only in an OLDER capture for the same store is not read' `
      (@($r | Where-Object { $_.term -eq 'kale' }).Count -eq 0) (($r | ForEach-Object { $_.term }) -join ',')
    T '...and the shutout it DOES report is dated from the newest capture' `
      ((@($r | Where-Object { $_.term -eq 'eggplant' })[0]).date -eq '2026-08-31') ([string](@($r | Where-Object { $_.term -eq 'eggplant' })[0]).date)

    # THE GROWTH RATCHET, driven end to end. It had no fixture at all in the first cut - it lives in the
    # live path, and a neuter of it left every case green because nothing here ever ran that path.
    $selfPath = $PSCommandPath
    function LiveRC([int]$allow) {
      $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $selfPath -OutDir $t -BaselineSpec ("zed=" + $allow)
      return $LASTEXITCODE
    }
    T 'MUST FIRE  a shutout set OVER its baseline is red' ((LiveRC 0) -ne 0) 'stayed green over baseline'
    T '...and a set AT its baseline is green' ((LiveRC 1) -eq 0) 'red at baseline'
  }
  finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
  if ($bad -eq 0) { Write-Output 'audit-instore-shutout SELF-TEST PASS'; exit 0 }
  Write-Output ("audit-instore-shutout SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1
}

# ---------------------------------------------------------------------------------------------------
$dir = if ($OutDir) { $OutDir } else { Join-Path $root 'out\regular' }
$sh = @(Get-Shutouts -Dir $dir)
$base = $script:BASELINE
if ($BaselineSpec) {
  $base = @{}
  foreach ($pair in ($BaselineSpec -split ';')) {
    $kv = $pair -split '='
    if ($kv.Count -eq 2) { $base[$kv[0].Trim()] = [int]$kv[1].Trim() }
  }
}
foreach ($b in @($sh | Where-Object { $_.term -eq '(no fulfillment signal)' })) {
  Write-Output ("shutout: {0,-12} UNMEASURABLE - {1} row(s) and not one carries a fulfillment field, so this store cannot be checked at all. Unknown is not a pass." -f $b.store, $b.rows)
}
$sh = @($sh | Where-Object { $_.term -ne '(no fulfillment signal)' })
$byStore = @{}
foreach ($s in $sh) { if (-not $byStore.ContainsKey($s.store)) { $byStore[$s.store] = 0 }; $byStore[$s.store]++ }

foreach ($store in ($byStore.Keys | Sort-Object)) {
  Write-Output ("shutout: {0,-12} {1} term(s) returned rows and the in-store gate refused EVERY one" -f $store, $byStore[$store])
  foreach ($s in @($sh | Where-Object { $_.store -eq $store } | Sort-Object term)) {
    Write-Output ("            {0,-24} {1} row(s), all shipped/third-party" -f $s.term, $s.rows)
  }
}
if (-not $sh.Count) { Write-Output 'shutout: no store has a term whose rows are all refused' }

if ($List) { Write-Output 'INSTORE-SHUTOUT-COMPLETE (list only)'; exit 0 }

$grew = @()
foreach ($store in ($byStore.Keys | Sort-Object)) {
  $allow = 0
  if ($base.ContainsKey($store)) { $allow = [int]$base[$store] }
  if ($byStore[$store] -gt $allow) { $grew += ("{0} {1} > baseline {2}" -f $store, $byStore[$store], $allow) }
}
if ($grew.Count) {
  Write-Output ("SHUTOUT GREW: {0}. A NEW commodity now has no shelf row at that store. Read it before anything treats the silence as NOT-CARRIED - sumac was ruled CARRIED by a human on 2026-08-22 and this same lane sees only shipped rows for it." -f ($grew -join '; '))
  Write-Output ("INSTORE-SHUTOUT-COMPLETE grew={0}" -f $grew.Count)
  exit 1
}
Write-Output ("INSTORE-SHUTOUT-COMPLETE stores={0} shutouts={1} (at or under baseline)" -f $byStore.Count, $sh.Count)
exit 0
