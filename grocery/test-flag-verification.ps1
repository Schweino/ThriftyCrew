<#
  test-flag-verification.ps1 -SelfTest - the fixtures for the price-flag verifier (grocery/triage-plans/plan-2026-09-21-8.json).

  Every MUST FIRE is a confirmed defect of the 30 days ending 2026-09-21, built from its REAL published row and the
  store's REAL answer (out/comparison-2026-09-05..09.json and the out/regular, out/sams captures), and each must reach
  wrong-price or wrong-product AND have its cell named by audit-flag-verification.ps1 AND be held or withheld by the
  real apply-cell-quarantine.ps1 - not merely "fire":
    laundry pods / Hy-Vee (queue 2026-09-07-05e4c3) - the fuel-saver clause published as $0.10 each; Hy-Vee's own
        product 3786246 is $9.94 for 31 ct. The store's read is placed INSIDE the ad window (2026-09-02; the capture that
        exists is dated 2026-09-14): a sale can only be judged on price inside its own window, and the twin below proves
        the 2026-09-14 read can never confirm it.
    Whole Coconut / Fareway (2026-09-10-b91a0a) - 'KIND Almond & Coconut', whose own URL says kind-bars-almond-coconut.
    Shrimp / Sam's Club (2026-09-11-3b246c) - 'Member's Mark Shrimp and Corn Chowder, 24 oz., 2 pk.'.
    Bouillon / Walmart (2026-09-05-521f1c) - $0.0813/oz published for $17.97 of '1.82 pounds' whose size field and
        printed unit price ($1.65/lb) disagree with its own name: no reading reproduces $0.0813.
    a store back at an OLDER price - 0.25 published, the store's later read 0.50.
  The identity rules are a FROZEN excerpt of each commodity's rule (commodities.json at the plan's commit), so a later
  rule edit cannot silently change what these cases prove.
  Temp paths are per run (a guid) and removed in finally. The last line is the verdict.
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $root -Parent
if (-not $SelfTest) { Write-Output 'test-flag-verification: run with -SelfTest'; exit 3 }

. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $root 'pu-lib.ps1')
. (Join-Path $root 'match-lib.ps1')
. (Join-Path $root 'flag-verify-lib.ps1')
. (Join-Path $root 'cell-quarantine-lib.ps1')
$script:pass = 0; $script:fail = 0
function Ok([string]$m) { $script:pass++; Write-Output ('ok    ' + $m) }
function Bad([string]$m) { $script:fail++; Write-Output ('FAIL  ' + $m) }
function Obj([string]$json) { return (ConvertFrom-Json $json) }
$tmp = Join-Path $env:TEMP ('tfv-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
try {
  $cent = [string][char]0x00A2
  # ---- a FROZEN excerpt of the rules these cases route through --------------------------------------------------------
  $cat = Obj '[{"id":"laundry-pods","commodity":"Laundry Detergent Pods","unit":"each","include":["laundry\\s+(?:pods?|pacs?)","detergent\\s+(?:pods?|pacs?)","\\bflings\\b"],"exclude":["dishwasher","\\bdish\\b"]},
               {"id":"coconut","commodity":"Whole Coconut","unit":"each","include":["whole\\s+coconuts?\\b","young\\s+coconuts?\\b","coconuts?\\b"],"exclude":["\\bchunks?\\b","\\bmilk\\b","shredded","\\bbars?\\b","\\bchowder\\b"]},
               {"id":"shrimp","commodity":"Shrimp (frozen, raw)","unit":"lb","include":["shrimp"],"exclude":["breaded","\\bchowder\\b","\\bsushi\\b","\\bsoup\\b"]},
               {"id":"bouillon","commodity":"Bouillon (cubes / granules / base)","unit":"oz","include":["bouillon"],"exclude":["\\bcubes?\\s+of\\s+ice\\b"]},
               {"id":"long-grain-rice","commodity":"Long Grain Rice","unit":"oz","include":["long\\s+grain\\s+rice"],"exclude":["\\bmix\\b"]},
               {"id":"15-bean-soup-mix","commodity":"15 Bean Soup Mix","unit":"oz","include":["15\\s*bean"],"exclude":["\\bcanned\\b"]}]'
  $judge = New-TcIdentityJudge -Commodities $cat -GlobalExclude ([string[]]@('\bdog\s+food\b'))
  function Verdict($claim, $answer, [string]$id, [string]$unit) {
    $idv = $null; if ($null -ne $answer) { $idv = Test-TcStoreNameIdentity -Judge $judge -Id $id -Names (Get-TcStoreNames $answer) }
    return (Resolve-TcRereadVerdict -Claim $claim -Answer $answer -Unit $unit -Identity $idv)
  }
  # ---- the real rows ------------------------------------------------------------------------------------------------
  $cLaundry = Obj '{"item":"Gain Flings, EARN 10c OFF PER GALLON, -3.00 off with manufacturer''s digital coupon, $12.94","per_unit":0.1,"ad":"Gain Flings, EARN 10c OFF PER GALLON, -3.00 off with manufacturer''s digital coupon, $12.94","size":"","row_type":"sale","ad_from":"2026-08-31","ad_to":"2026-09-06","as_of":""}'
  $aLaundryIn = Obj '{"item":"Gain flings! Laundry Detergent Pacs, Original, 31 Count","ad_price":"$9.94","current_price":9.94,"size":"31 ct","as_of":"2026-09-02","product_id":3786246}'
  $aLaundryAfter = Obj '{"item":"Gain flings! Laundry Detergent Pacs, Original, 31 Count","ad_price":"$9.94","current_price":9.94,"size":"31 ct","as_of":"2026-09-14","product_id":3786246}'
  $aLaundryTrap = Obj '{"item":"Gain flings! Laundry Detergent Pacs, Original, 31 Count","ad_price":"$3.10","current_price":3.10,"size":"31 ct","as_of":"2026-09-14","product_id":3786246}'
  $aLaundryTrapIn = Obj '{"item":"Gain flings! Laundry Detergent Pacs, Original, 31 Count","ad_price":"$3.10","current_price":3.10,"size":"31 ct","as_of":"2026-09-03","product_id":3786246}'
  $cKind = Obj '{"item":"KIND Almond & Coconut","per_unit":1.33,"ad":"$7.98","size":"6 ct","row_type":"everyday","ad_from":"","ad_to":"","as_of":"2026-09-09"}'
  $aKind = Obj '{"item":"KIND Almond & Coconut","ad_price":"$7.98","size":"6 ct","regular":"$8.97","source_ad":"shop.fareway.com","as_of":"2026-09-10","found_by_term":"whole coconut","link_url":"https://shop.fareway.com/store/fareway-meat-grocery/products/20002358-kind-bars-almond-coconut-6-ea","current_price":7.98,"base_price":8.97,"marked_down":true}'
  $aKindNoSlug = Obj '{"item":"KIND Almond & Coconut","ad_price":"$7.98","size":"6 ct","as_of":"2026-09-10","current_price":7.98}'
  $cChowder = Obj '{"item":"Member''s Mark Shrimp and Corn Chowder, 24 oz., 2 pk.","per_unit":3.49,"ad":"$10.47","size":"48 oz","row_type":"everyday","ad_from":"","ad_to":"","as_of":"2026-09-09"}'
  $aChowder = Obj '{"item":"Member''s Mark Shrimp and Corn Chowder, 24 oz., 2 pk.","ad_price":"$10.47","size":"48 oz","as_of":"2026-09-11","current_price":"$10.47","base_price":11.48,"ad_to":"2026-10-11"}'
  $cBouillon = Obj '{"item":"Knorr Select Vegetable Base, Shelf Stable Granulated Bouillon, 1.82 pounds","per_unit":0.0813,"ad":"$17.97","size":"","row_type":"everyday","ad_from":"","ad_to":"","as_of":"2026-07-15"}'
  $aBouillon = Obj '{"item":"Knorr Select Vegetable Base, Shelf Stable Granulated Bouillon, 1.82 pounds","ad_price":"$17.97","size":"10.891 lb","as_of":"2026-08-31","current_price":"$17.97","wm_unit_price":"$1.65/lb","item_id":"198431752","price_type":"everyday"}'
  $cRice = Obj '{"item":"Synthetic Long Grain Rice 32 oz","per_unit":0.25,"ad":"$8.00","size":"32 oz","row_type":"everyday","ad_from":"","ad_to":"","as_of":"2026-09-01"}'
  $aRice = Obj '{"item":"Synthetic Long Grain Rice 32 oz","ad_price":"$16.00","current_price":16.00,"size":"32 oz","as_of":"2026-09-05"}'
  $wmHb = '14.4 ' + $cent + '/oz'
  $cHb = Obj '{"item":"Hurst''s HamBeens 15 Bean Dry Soup Mix with Seasoning, 20 oz","per_unit":0.1435,"ad":"$2.87","size":"20 oz","row_type":"everyday","ad_from":"","ad_to":"","as_of":"2026-09-19"}'
  $aHb = Obj '{"item":"Hurst''s HamBeens 15 Bean Dry Soup Mix with Seasoning, 20 oz","ad_price":"$2.87","current_price":"$2.87","size":"20 oz","as_of":"2026-09-21"}'
  $aHb | Add-Member -NotePropertyName wm_unit_price -NotePropertyValue $wmHb

  # ---- 1. THE VERDICT RULE ----------------------------------------------------------------------------------------
  $v = Verdict $cLaundry $aLaundryIn 'laundry-pods' 'each'
  if ($v.verdict -eq 'wrong-price') { Ok ('MUST FIRE  laundry pods 2026-09-07: $0.10 each against Hy-Vee''s own $9.94 / 31 ct read inside the ad window is wrong-price (' + $v.reason + ')') } else { Bad ('laundry pods in-window read gave ' + $v.verdict + ': ' + $v.reason) }
  $v = Verdict $cLaundry $aLaundryAfter 'laundry-pods' 'each'
  if ($v.verdict -eq 'could-not-look') { Ok 'MUST NOT FIRE  the same product read AFTER the sale ended (2026-09-14) neither confirms nor condemns a sale price: could-not-look, stays pending' } else { Bad ('laundry pods read after the window gave ' + $v.verdict + ': ' + $v.reason) }
  $v = Verdict $cLaundry $aLaundryTrap 'laundry-pods' 'each'
  if ($v.verdict -ne 'match') { Ok ('MUST NOT FIRE  a store record read after the window that reproduces the bad $0.10 each ($3.10 / 31 ct) is NOT a match (' + $v.verdict + ') - an ended sale can never confirm a sale price') } else { Bad 'an ended sale confirmed the $0.10 laundry price - the trap the brief named' }
  $v = Verdict $cLaundry $aLaundryTrapIn 'laundry-pods' 'each'
  if ($v.verdict -eq 'match') { Ok 'CLEAN TWIN  a real sale is still confirmed: $3.10 / 31 ct read INSIDE the window reproduces $0.10 each, so a sale price the store really charged is a match' } else { Bad ('an in-window sale the store confirms gave ' + $v.verdict + ': ' + $v.reason) }
  $v = Verdict $cKind $aKind 'coconut' 'each'
  if ($v.verdict -eq 'wrong-product' -and $v.reason -match 'kind bars almond coconut') { Ok ('MUST FIRE  Whole Coconut 2026-09-10: Fareway''s own URL name ''kind bars almond coconut'' is refused by coconut''s rule - wrong-product') } else { Bad ('KIND bar gave ' + $v.verdict + ': ' + $v.reason) }
  $v = Verdict $cKind $aKindNoSlug 'coconut' 'each'
  if ($v.verdict -eq 'match') { Ok 'MECHANISM  with the display name alone the same KIND row would be CONFIRMED, so the store''s own URL name is what catches it (this is why identity reads every name the store gives)' } else { Bad ('the KIND row without its URL gave ' + $v.verdict + ' - the mechanism case no longer isolates the URL name') }
  $v = Verdict $cChowder $aChowder 'shrimp' 'lb'
  if ($v.verdict -eq 'wrong-product') { Ok 'MUST FIRE  Shrimp 2026-09-11: the chowder is refused by shrimp''s own rule - wrong-product, although its $3.49/lb reproduces exactly' } else { Bad ('chowder gave ' + $v.verdict + ': ' + $v.reason) }
  $v = Verdict $cBouillon $aBouillon 'bouillon' 'oz'
  if ($v.verdict -eq 'wrong-price' -and @($v.readings).Count -ge 3) { Ok ('MUST FIRE  Bouillon 2026-09-05: no reading of Walmart''s own figures (size field, the name''s 1.82 lb, its printed $1.65/lb) gives $0.0813/oz - wrong-price, although the shelf price $17.97 matches') } else { Bad ('bouillon gave ' + $v.verdict + ' with ' + @($v.readings).Count + ' reading(s): ' + $v.reason) }
  $v = Verdict $cRice $aRice 'long-grain-rice' 'oz'
  if ($v.verdict -eq 'wrong-price') { Ok 'MUST FIRE  a store back at an OLDER price: 0.25 published, the store''s later read 0.50 - wrong-price' } else { Bad ('older-price case gave ' + $v.verdict + ': ' + $v.reason) }
  $v = Verdict $cHb $aHb '15-bean-soup-mix' 'oz'
  if ($v.verdict -eq 'match') { Ok 'MUST NOT FIRE  a flag the store confirms (same product, $2.87, 20 oz, printed 14.4 cents/oz) is a match and raises nothing' } else { Bad ('the confirmed HamBeens row gave ' + $v.verdict + ': ' + $v.reason) }
  # the bars, on integers
  $at = Test-TcPrintedUnitAgrees -OursPerUnit 0.0935 -CommodityUnit 'oz' -Printed ('9.3 ' + $cent + '/oz')
  $past = Test-TcPrintedUnitAgrees -OursPerUnit 0.0936 -CommodityUnit 'oz' -Printed ('9.3 ' + $cent + '/oz')
  if ($at -eq 'agree' -and $past -eq 'disagree') { Ok 'BAR  a printed unit price agrees within HALF its last digit: 0.0935 against 9.3 cents/oz is AT the bar (500 of 500 millionths) and agrees; 0.0936, one step past, disagrees' } else { Bad ("printed-unit bar: at=$at past=$past") }
  $hbNoPrint = Obj '{"item":"Hurst''s HamBeens 15 Bean Dry Soup Mix with Seasoning, 20 oz","ad_price":"$2.87","current_price":"$2.87","size":"20 oz","as_of":"2026-09-21"}'
  $c1 = $cHb.PSObject.Copy(); $c1.per_unit = 0.1436; $c1.ad = ''
  $c2 = $cHb.PSObject.Copy(); $c2.per_unit = 0.1437; $c2.ad = ''
  $v1 = Verdict $c1 $hbNoPrint '15-bean-soup-mix' 'oz'; $v2 = Verdict $c2 $hbNoPrint '15-bean-soup-mix' 'oz'
  if ($v1.verdict -eq 'match' -and $v2.verdict -eq 'wrong-price') { Ok 'BAR  a computed reading agrees within ONE ten-thousandth: 0.1436 against the store''s 0.1435 is AT the bar and matches; 0.1437, one step past, is wrong-price' } else { Bad ("computed-reading bar: 0.1436 -> $($v1.verdict), 0.1437 -> $($v2.verdict)") }
  # the store's figures disagreeing with themselves settle nothing
  $cSelf = $cBouillon.PSObject.Copy(); $cSelf.per_unit = 0.6171; $cSelf.ad = ''
  $v = Verdict $cSelf $aBouillon 'bouillon' 'oz'
  if ($v.verdict -eq 'could-not-look') { Ok 'MUST NOT FIRE  when the store''s own figures disagree (the name says 1.82 lb, its size field and unit price say 10.891 lb) and one agrees with ours, that is could-not-look, never a match' } else { Bad ('a self-contradicting store read gave ' + $v.verdict) }

  # ---- 2. THE RE-READ: only a LATER, FRESH read of the SAME product is an answer ---------------------------------------
  $rowsCarried = @((Obj '{"item":"KIND Almond & Coconut","ad_price":"$7.98","size":"6 ct","as_of":"2026-09-09","current_price":7.98}'))
  $rr = Find-TcStoreReread -Claim $cKind -Rows $rowsCarried
  if ($null -eq $rr.row) { Ok 'MUST NOT FIRE  a carried row (as_of no later than the claim''s own read) is not a re-read, so it cannot settle the flag' } else { Bad 'a carried row was taken as the store''s answer' }
  $rowsNotRev = @((Obj '{"item":"KIND Almond & Coconut","ad_price":"$7.98","size":"6 ct","as_of":"2026-09-12","current_price":7.98,"not_reverified":true}'))
  $rr = Find-TcStoreReread -Claim $cKind -Rows $rowsNotRev
  if ($null -eq $rr.row) { Ok 'MUST NOT FIRE  a row the lane marked not_reverified (stamped today, never re-read) is not a re-read' } else { Bad 'a not_reverified row was taken as the store''s answer' }
  $rr = Find-TcStoreReread -Claim $cKind -Rows @()
  if ($null -eq $rr.row -and $rr.why -match 'no read of this product later than 2026-09-09') { Ok 'MUST NOT FIRE  a throttled or walled lane leaves no row: could-not-look, and the reason names the date it is waiting past' } else { Bad ('an empty capture gave a row, or the wrong reason: ' + $rr.why) }
  $rowsId = @((Obj '{"item":"Gain flings! Laundry Detergent Pacs, Original, 31 Count","ad_price":"$9.94","size":"31 ct","as_of":"2026-09-01","product_id":3786246}'), (Obj '{"item":"Gain flings! Laundry Detergent Pacs, Original, 31 Count (renamed)","ad_price":"$9.94","size":"31 ct","as_of":"2026-09-02","product_id":3786246}'))
  $cById = Obj '{"item":"Gain flings! Laundry Detergent Pacs, Original, 31 Count","per_unit":0.3206,"ad":"$9.94","size":"31 ct","row_type":"everyday","as_of":"2026-09-01"}'
  $rr = Find-TcStoreReread -Claim $cById -Rows $rowsId
  if ($null -ne $rr.row -and [string]$rr.row.as_of -eq '2026-09-02') { Ok 'CLEAN TWIN  the same product is still found by the product id its own source row carries when the store renames it' } else { Bad 'a later read of the same product id was not found' }

  # ---- 3. END TO END: ledger -> audit -> the real apply-cell-quarantine -> second guards pass ---------------------------
  $storesN = @('Hy-Vee', 'Aldi', 'Family Fare', 'Fareway', "Baker's", "Sam's Club", 'Walmart')
  $cells = [ordered]@{
    'laundry-pods|Hy-Vee'         = @($cLaundry, $aLaundryIn, 'Laundry Detergent Pods', 'each')
    'coconut|Fareway'             = @($cKind, $aKind, 'Whole Coconut', 'each')
    "shrimp|Sam's Club"           = @($cChowder, $aChowder, 'Shrimp (frozen, raw)', 'lb')
    'bouillon|Walmart'            = @($cBouillon, $aBouillon, 'Bouillon (cubes / granules / base)', 'oz')
    "long-grain-rice|Baker's"     = @($cRice, $aRice, 'Long Grain Rice', 'oz')
    '15-bean-soup-mix|Walmart'    = @($cHb, $aHb, '15 Bean Soup Mix', 'oz')
  }
  # Each defect commodity keeps its REAL runner-up of that day (the u144 frozen boards), because withholding a row's only
  # priced store is refused by apply-cell-quarantine on purpose (recipes cost from that row) and would hold the board.
  $runnerUp = @{
    'laundry-pods' = @("Sam's Club", 0.1498, "Member's Mark Laundry Detergent Power Pacs, Blooming Breeze, 130 ct.")
    'coconut' = @("Baker's", 3.49, 'Fresh Brown Coconuts')
    'shrimp' = @('Walmart', 6.76, 'Great Value Frozen Raw Small Peeled & Deveined, Tail-off Shrimp, 12 oz Bag (60-80 Count per lb)')
    'bouillon' = @("Sam's Club", 0.1477, 'Knorr Granulated Chicken Bouillon, 40.5 oz.')
    'long-grain-rice' = @('Aldi', 0.3, 'Synthetic Aldi Long Grain Rice 32 oz')
  }
  $comp = New-Object System.Collections.ArrayList
  foreach ($k in $cells.Keys) {
    $p = $k -split '\|', 2; $cl = $cells[$k][0]
    $row = [pscustomobject]@{ store = $p[1]; per_unit = [double]$cl.per_unit; unit = $cells[$k][3]; type = [string]$cl.row_type; item = [string]$cl.item; ad = [string]$cl.ad; size = [string]$cl.size; ad_from = [string]$cl.ad_from; ad_to = [string]$cl.ad_to; as_of = [string]$cl.as_of }
    $rows = @($row)
    if ($runnerUp.ContainsKey($p[0])) { $ru = $runnerUp[$p[0]]; $rows += [pscustomobject]@{ store = $ru[0]; per_unit = [double]$ru[1]; unit = $cells[$k][3]; type = 'everyday'; item = $ru[2]; ad = ''; size = ''; ad_from = ''; ad_to = ''; as_of = '2026-09-20' } }
    [void]$comp.Add([pscustomobject]@{ commodity = $cells[$k][2]; id = $p[0]; unit = $cells[$k][3]; cheapest_store = $p[1]; cheapest_price = [double]$cl.per_unit; stores = $rows })
  }
  for ($i = 1; $i -le 60; $i++) {
    $st = @($storesN | ForEach-Object { [pscustomobject]@{ store = $_; per_unit = (1.0 + $i / 100.0); unit = 'oz'; type = 'everyday'; item = ('Filler ' + $i + ' at ' + $_); ad = '$1.00'; size = '1 oz'; as_of = '2026-09-20' } })
    [void]$comp.Add([pscustomobject]@{ commodity = ('Filler ' + $i); id = ('filler-' + $i); unit = 'oz'; cheapest_store = 'Hy-Vee'; cheapest_price = 1.0; stores = $st })
  }
  $board = [pscustomobject]@{ week_of = '2026-09-21'; built_at = '2026-09-21T06:00:00'; max_publish_age_days = 90; comparison = $comp.ToArray() }
  $boardF = Join-Path $tmp 'comparison-2026-09-21.json'
  [IO.File]::WriteAllText($boardF, ($board | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  $board = Read-JsonFile $boardF
  $flags = @(foreach ($k in $cells.Keys) {
      $p = $k -split '\|', 2; $cl = $cells[$k][0]
      [pscustomobject]@{ commodity = $cells[$k][2]; type = 'outlier'; detail = 'fixture'; id = $p[0]; unit = $cells[$k][3]; store = $p[1]; item = [string]$cl.item; per_unit = [double]$cl.per_unit; row_type = [string]$cl.row_type; ad = [string]$cl.ad; size = [string]$cl.size; ad_from = [string]$cl.ad_from; ad_to = [string]$cl.ad_to; as_of = [string]$cl.as_of }
    })
  $answerOf = @{}; foreach ($k in $cells.Keys) { $answerOf[$k] = $cells[$k][1] }
  $resolveFx = { param($e) $a = $answerOf[[string]$e.key]; $v = Verdict $e.claim $a ([string]$e.id) ([string]$e.unit); $v | Add-Member -NotePropertyName answer -NotePropertyValue ([pscustomobject]@{ item = [string]$a.item; current_price = [string]$a.current_price; size = [string]$a.size; as_of = [string]$a.as_of }) -Force; return $v }
  $res = Update-TcFlagLedger -Ledger (New-TcFlagLedger) -Flags $flags -Board $board -Today '2026-09-21' -Resolve $resolveFx
  $L = $res.ledger
  $open = @(@($L.entries.Keys) | ForEach-Object { $L.entries[$_] })
  $dis = @($open | Where-Object { @('wrong-price', 'wrong-product') -contains [string]$_.status })
  $matchClosed = @(@($L.closed) | Where-Object { [string]$_.status -eq 'match' -and [string]$_.key -eq '15-bean-soup-mix|Walmart' })
  if ($dis.Count -eq 5 -and $matchClosed.Count -eq 1 -and $open.Count -eq 5) { Ok 'MUST FIRE  the ledger holds all 5 frozen defects open as disagreements, and the store-confirmed flag CLOSED as match (5 open of 6 flagged)' } else { Bad ("ledger: open=$($open.Count) disagreements=$($dis.Count) matched=$($matchClosed.Count)") }
  $ledF = Join-Path $tmp 'flag-verification.json'
  [IO.File]::WriteAllText($ledF, ($L | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
  $auditOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'audit-flag-verification.ps1') -OutDir $tmp)
  $auditRc = $LASTEXITCODE
  $scope = Get-TcChildQuarantineScope $auditOut
  $named = @(); if ($scope) { $named = @($scope.cells | ForEach-Object { [string]$_.id + '|' + [string]$_.store }) }
  $want = @('laundry-pods|Hy-Vee', 'coconut|Fareway', "shrimp|Sam's Club", 'bouillon|Walmart', "long-grain-rice|Baker's")
  $missing = @($want | Where-Object { $named -notcontains $_ })
  if ($auditRc -eq 2 -and $missing.Count -eq 0 -and $named.Count -eq 5 -and $named -notcontains '15-bean-soup-mix|Walmart') { Ok 'MUST FIRE  audit-flag-verification exits 2 and names exactly the 5 contradicted cells in the QUARANTINE-CELL protocol guards reads (the confirmed one is not named)' } else { Bad ("audit rc=$auditRc named=[$($named -join ', ')] missing=[$($missing -join ', ')] :: " + (($auditOut | Select-Object -Last 3) -join ' / ')) }
  $fails = @($named | ForEach-Object { $p = $_ -split '\|', 2; New-TcGuardFailure -Message 'HARD FAIL: flag-verification' -Family 'cell' -Id $p[0] -Store $p[1] -Kind 'value' -Check 'flag-verification' })
  $disp = Get-TcGuardsDisposition -Failures $fails -Board $board
  if ([string]$disp.action -eq 'quarantine') { Ok 'MUST FIRE  guards'' own disposition over those failures is quarantine, under the circuit breaker (5 of 431 priced cells)' } else { Bad ('disposition was ' + $disp.action + ': ' + (@($disp.reasons) -join '; ')) }
  [void](Write-TcQuarantinePlan -OutDir $tmp -Disposition $disp -BoardPath $boardF)
  $last = [pscustomobject]@{ __meta = [pscustomobject]@{ stores = $storesN }; __rows = [pscustomobject]@{
      'coconut' = [pscustomobject]@{ u = 'each'; p = @(, @(3, 3.99, 0, '')) }
      'shrimp' = [pscustomobject]@{ u = 'lb'; p = @(, @(5, 5.82, 0, '')) }
      'bouillon' = [pscustomobject]@{ u = 'oz'; p = @(, @(6, 0.1681, 0, '')) }
      'long-grain-rice' = [pscustomobject]@{ u = 'oz'; p = @(, @(4, 0.5, 0, '')) } } }
  $lastF = Join-Path $tmp 'last-published.json'
  [IO.File]::WriteAllText($lastF, ($last | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  $apOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'apply-cell-quarantine.ps1') -OutDir $tmp -LastPublishedFile $lastF -LastPublishedDate '2026-09-20' -Today '2026-09-21')
  $apRc = $LASTEXITCODE
  $held = @($apOut | Where-Object { $_ -match '^\s+held\s' }); $withheld = @($apOut | Where-Object { $_ -match '^\s+withheld\s' })
  if ($apRc -eq 0 -and $held.Count -eq 4 -and $withheld.Count -eq 1 -and ($withheld[0] -match 'laundry-pods')) { Ok 'MUST FIRE  the real apply-cell-quarantine holds 4 cells at their last verified published price and WITHHOLDS laundry pods, which has none - nothing is invented' } else { Bad ("apply rc=$apRc held=$($held.Count) withheld=$($withheld.Count) :: " + (($apOut | Select-Object -Last 4) -join ' / ')) }
  $auditOut2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'audit-flag-verification.ps1') -OutDir $tmp)
  $auditRc2 = $LASTEXITCODE
  if ($auditRc2 -eq 0) { Ok 'MUST NOT FIRE  on the quarantined board the audit names nothing, so guards'' second pass can reach QUARANTINED instead of a hold' } else { Bad ("second audit over the quarantined board exited $auditRc2 :: " + (($auditOut2 | Select-Object -Last 2) -join ' / ')) }
  $qBoard = Read-JsonFile $boardF
  $res2 = Update-TcFlagLedger -Ledger (Read-JsonFile $ledF) -Flags @() -Board $qBoard -Today '2026-09-22' -Resolve $resolveFx
  $open2 = @(@($res2.ledger.entries.Keys) | ForEach-Object { $res2.ledger.entries[$_] } | Where-Object { @('wrong-price', 'wrong-product') -contains [string]$_.status })
  $heldCount = @($open2 | Where-Object { [string]$_.key -ne 'laundry-pods|Hy-Vee' }).Count
  if ($heldCount -eq 4) { Ok 'CLEAN TWIN  a held cell''s disagreement stays OPEN on the quarantined board, so the next build that produces the same claim is quarantined again rather than forgotten' } else { Bad ("after the quarantine the ledger kept $heldCount of 4 held disagreements open") }

  # ---- 4. ONE ALERT PER CELL, ONCE, NAMING BOTH PRICES AND THE STORE'S PRODUCT ----------------------------------------
  $sentLog = New-Object System.Collections.ArrayList
  $send = { param($s, $b) [void]$sentLog.Add([pscustomobject]@{ subject = $s; body = $b }); return $true }
  $L3 = Read-JsonFile $ledF
  $r0 = Invoke-TcDisagreementAlerts -Ledger $L3 -Send $send -NoAlert -Today '2026-09-21'
  $r1 = Invoke-TcDisagreementAlerts -Ledger $L3 -Send $send -Today '2026-09-21'
  $r2 = Invoke-TcDisagreementAlerts -Ledger $L3 -Send $send -Today '2026-09-21'
  $bou = @($sentLog | Where-Object { $_.subject -eq 'Grocery: price disagreement - Bouillon (cubes / granules / base) at Walmart' })
  if ($r0.sent -eq 0 -and $r0.due -eq 5 -and $r1.sent -eq 5 -and $sentLog.Count -eq 5 -and $r2.sent -eq 0 -and $bou.Count -eq 1 -and $bou[0].body -match 'Walmart says \$17\.97' -and $bou[0].body -match 'we publish \$0\.0813/oz' -and $bou[0].body -match 'Knorr Select Vegetable Base') {
    Ok 'MUST FIRE  a store disagreement pages ONE alert per cell, once, naming the cell, both prices and the store''s product ("Walmart says $17.97 ... we publish $0.0813/oz"); a -NoAlert run leaves all 5 DUE'
  } else { Bad ("alerts: noalert sent=$($r0.sent) due=$($r0.due); first sent=$($r1.sent); second sent=$($r2.sent); total=$($sentLog.Count); bouillon=$($bou.Count)") }
  $failSend = { param($s, $b) return $false }
  $L4 = Read-JsonFile $ledF
  $r3 = Invoke-TcDisagreementAlerts -Ledger $L4 -Send $failSend -Today '2026-09-21'
  $stillDue = @(@((ConvertTo-TcLedgerEntries $L4).Values) | Where-Object { -not [string]$_.alerted_at -and @('wrong-price', 'wrong-product') -contains [string]$_.status }).Count
  if ($r3.sent -eq 0 -and $r3.failed -eq 5 -and $stillDue -eq 5) { Ok 'MUST NOT FIRE  a send that failed stamps nothing, so all 5 stay DUE for the next run' } else { Bad ("failed sends: sent=$($r3.sent) failed=$($r3.failed) stillDue=$stillDue") }

  # ---- 5. THE OWED RE-READ LEADS THE NEXT WORKLIST, AND EMPTIES ITSELF ------------------------------------------------
  . (Join-Path $root 'capture-policy-lib.ps1')
  $allT = @(Get-AllTerms)
  $pick = $allT[0]
  $wOut = Join-Path $tmp 'wl-out'; New-Item -ItemType Directory -Path $wOut -ErrorAction Stop | Out-Null
  $pendClaim = [pscustomobject]@{ item = 'Fixture Walmart Product'; per_unit = 1.0; ad = '$1.00'; size = '1 oz'; row_type = 'everyday'; ad_from = ''; ad_to = ''; as_of = '2026-09-20' }
  $pend = [pscustomobject]@{ key = ([string]$pick.id + '|Walmart'); id = [string]$pick.id; commodity = 'x'; store = 'Walmart'; unit = 'oz'; claim = $pendClaim; claim_key = (Get-TcClaimKey $pendClaim); flag_types = @('outlier'); first_flagged = '2026-09-21'; last_flagged = '2026-09-21'; status = 'pending'; reason = ''; verdict_at = ''; answer = $null; attempts = 1; last_attempt = '2026-09-21'; alerted_at = ''; closed_at = ''; readings = @() }
  $Lw = [pscustomobject]@{ generated = '2026-09-21'; entries = [ordered]@{ ([string]$pend.key) = $pend }; closed = @() }
  [IO.File]::WriteAllText((Join-Path $wOut 'flag-verification.json'), ($Lw | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
  $wl = Get-CaptureWorklist -Store 'Walmart' -Today '2026-09-21' -OutDir $wOut
  $head = @($wl.Terms | Select-Object -First @($wl.VerifyTerms).Count | ForEach-Object { [string]$_.term })
  $vt = @($wl.VerifyTerms | ForEach-Object { [string]$_.term })
  if ($vt.Count -ge 1 -and ($head -join '|') -eq ($vt -join '|') -and @($wl.VerifyOwed) -contains [string]$pick.id) { Ok ('CLEAN TWIN  a pending Walmart flag''s commodity (' + $pick.id + ') leads the next Walmart worklist: its ' + $vt.Count + ' term(s) are the HEAD of Terms') } else { Bad ("worklist: verify=[$($vt -join ',')] head=[$($head -join ',')] owed=[$(@($wl.VerifyOwed) -join ',')] blind=$($wl.VerifyBlind) $($wl.VerifyWhy)") }
  $Lw2 = (Update-TcFlagLedger -Ledger (Read-JsonFile (Join-Path $wOut 'flag-verification.json')) -Flags @() -Board ([pscustomobject]@{ comparison = @([pscustomobject]@{ commodity = 'x'; id = [string]$pick.id; unit = 'oz'; stores = @([pscustomobject]@{ store = 'Walmart'; item = 'Fixture Walmart Product'; per_unit = 1.0; type = 'everyday' }) }) }) -Today '2026-09-22' -Resolve { param($e) [pscustomobject]@{ verdict = 'match'; reason = 'a built capture re-read it'; readings = @() } }).ledger
  [IO.File]::WriteAllText((Join-Path $wOut 'flag-verification.json'), ($Lw2 | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
  $wl2 = Get-CaptureWorklist -Store 'Walmart' -Today '2026-09-22' -OutDir $wOut
  if (@($wl2.VerifyTerms).Count -eq 0 -and @($wl2.VerifyOwed).Count -eq 0) { Ok 'CLEAN TWIN  once a built capture re-reads it (the ledger closes it as match) the next worklist no longer carries it - the owed list empties itself' } else { Bad ("the owed term survived its re-read: verify=$(@($wl2.VerifyTerms).Count)") }
  $wlF = Get-CaptureWorklist -Store 'Family Fare' -Today '2026-09-21' -OutDir $wOut
  if (@($wlF.VerifyTerms).Count -eq 0) { Ok 'MUST NOT FIRE  a Walmart verification prepends nothing to another store''s worklist' } else { Bad 'another store picked up a Walmart verification' }

  # ---- 6. THE REAL PAGER REGION (extracted from check-ad-cycles.ps1): a sanity kind leaves the batch alert ONLY when the
  #      verifier completed, ONLY when the flag names its cell, and never for a type the list does not name ----------------
  $spSrc = [IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))
  $spM = [regex]::Match($spSrc, '(?s)<<SANITY-PAGER-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<SANITY-PAGER-END>>')
  if (-not $spM.Success) { Bad 'the SANITY-PAGER region is gone from check-ad-cycles.ps1 - the pager cases examined nothing' }
  else {
    $pgDir = Join-Path $tmp 'pager'; New-Item -ItemType Directory -Path $pgDir -ErrorAction Stop | Out-Null
    $pgRows = '[{"commodity":"Oats / Oatmeal","type":"outlier-verified","detail":"store agrees"},{"commodity":"Anaheim Peppers","type":"outlier","detail":"x","id":"anaheim-peppers","store":"Baker''s"},{"commodity":"Cardamom","type":"wow","detail":"y","id":"cardamom","store":"Walmart"},{"commodity":"Old Flag","type":"outlier","detail":"a flag written before the cell fields"},{"commodity":"Mystery","type":"outlier-nonsense","detail":"z","id":"m","store":"Aldi"}]'
    [IO.File]::WriteAllText((Join-Path $pgDir 'guards-2026-09-21.json'), $pgRows, (New-Object Text.UTF8Encoding($false)))
    $gf = Get-Item (Join-Path $pgDir 'guards-2026-09-21.json')
    $flagVerifyOk = $true; $flagParts = @(); $flagKeys = @()
    . ([scriptblock]::Create($spM.Groups[1].Value))
    $onKeys = @($flagKeys); $onVerified = $sanityVerified
    $flagVerifyOk = $false; $flagParts = @(); $flagKeys = @()
    . ([scriptblock]::Create($spM.Groups[1].Value))
    $offKeys = @($flagKeys)
    if ($offKeys.Count -eq 4 -and ($offKeys -contains 'SANITY|Anaheim Peppers|outlier') -and ($offKeys -contains 'SANITY|Cardamom|wow')) { Ok 'MUST FIRE  when the verifier did NOT complete, every flag pages exactly as before (4 of 4 non-quiet flags, the two with cells included) - it fails closed' } else { Bad ('verifier off: paged [' + ($offKeys -join ', ') + ']') }
    if ($onVerified -eq 2 -and ($onKeys -notcontains 'SANITY|Anaheim Peppers|outlier') -and ($onKeys -notcontains 'SANITY|Cardamom|wow')) { Ok 'MUST NOT FIRE  when the verifier completed, an outlier and a wow that name their cell are put to the store instead of paged (2 verified)' } else { Bad ('verifier on: verified=' + $onVerified + ' paged [' + ($onKeys -join ', ') + ']') }
    if ($onKeys.Count -eq 2 -and ($onKeys -contains 'SANITY|Old Flag|outlier') -and ($onKeys -contains 'SANITY|Mystery|outlier-nonsense')) { Ok 'CLEAN TWIN  with the verifier on, a flag with no cell and a type the list does not name still page - the allowlist stays closed' } else { Bad ('verifier on: the uncovered flags did not page: [' + ($onKeys -join ', ') + ']') }
  }

  # ---- 7. THE NEW ALERTS RESOLVE THROUGH send-alert's OWN RESOLVER (the static audit cannot read a built subject) -------
  . (Join-Path $root 'alert-registry-lib.ps1')
  $rgd = Read-AlertRegistry (Join-Path $root 'alert-registry.json')
  $e5 = @(@((ConvertTo-TcLedgerEntries (Read-JsonFile $ledF)).Values) | Where-Object { [string]$_.key -eq 'bouillon|Walmart' })[0]
  $sub5 = (Format-TcDisagreementAlert $e5).subject
  $rc5 = Resolve-AlertClass -Registry $rgd.registry -TypeKey (Get-AlertTypeKey $sub5)
  if ($rc5.registered -and -not $rc5.ambiguous -and $rc5.class -eq 'page' -and [string]$rc5.entry.id -eq 'price-disagreement') { Ok ('MUST FIRE  ''' + $sub5 + ''' resolves to the registry''s price-disagreement entry, class page - and its type key carries the cell, so a return is that cell') } else { Bad ('the disagreement subject resolved to ' + $rc5.class + ' via ' + [string]$rc5.entry.id + ' (registered=' + $rc5.registered + ', ambiguous=' + $rc5.ambiguous + ')') }
  $rc6 = Resolve-AlertClass -Registry $rgd.registry -TypeKey (Get-AlertTypeKey 'Grocery: 3 price flag verification(s) overdue past the quarter')
  if ($rc6.registered -and -not $rc6.ambiguous -and $rc6.class -eq 'page' -and [string]$rc6.entry.id -eq 'price-flag-verification-overdue') { Ok 'MUST FIRE  the overdue-backlog subject resolves to price-flag-verification-overdue, class page' } else { Bad ('the overdue subject resolved to ' + $rc6.class + ' via ' + [string]$rc6.entry.id) }
}
catch { Bad ('the suite threw: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage) }
finally { try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch { } }
$cases = $script:pass + $script:fail
Write-Output ('flag-verification self-test ' + $(if ($script:fail -eq 0 -and $cases -eq 33) { 'pass' } else { 'FAIL' }) + ': ' + $script:pass + ' of ' + $cases + ' case(s) passed (33 expected)')
if ($script:fail -eq 0 -and $cases -eq 33) { exit 0 }
exit 1
