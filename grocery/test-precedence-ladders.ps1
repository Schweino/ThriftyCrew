<#
  test-precedence-ladders.ps1 - the FROZEN semantics of an adjudicated ruling, measured not assumed.

  WHY THIS FILE EXISTS. PLAN-product-identity-2026-08-22.md section 10.5 asks the one question the
  identity table cannot be designed without: when a known-wrong forbids the commodity the rules
  proposed, does the product FALL THROUGH to the next commodity whose include also matched, or does
  it DROP off the board entirely? The plan says to read the answer out of compare-deals.ps1 rather
  than assume it. Reading it is not enough either - a reading is a second copy of the rule, and this
  estate's most reliable bug is a second copy. So the answer is pinned here as a fixture that runs
  the REAL engine on a two-commodity corpus built for the purpose.

  THE ANSWER, MEASURED 2026-08-22 (cases below):
    * The matcher is first-match-wins and returns ONE commodity per product name. known-wrong is
      applied AFTERWARDS, in compare-deals.ps1's "adjudicated-wrong cells" block, as a row-level DROP
      out of $matched.
    * So a forbidden product DROPS. It does NOT fall through to the next include-matching commodity.
      The comment at that block - "the store falls through to its next-best row" - means the store's
      OTHER products inside the SAME commodity, not this product's next commodity.
    * A ruling is scoped to (commodity, store): forbidding a commodity the rules never proposed is
      inert, and so is a ruling for a different store.
    * The match is on the normal form AND the unit-stripped core (known-wrong-lib.ps1 KwNorm/KwCore),
      so re-listing the same product at a new pack size does not escape a ruling.
    * A reversed entry (reversed_on AND reversed_by) is history, not a gate.
    * The candidates-<date>.json artifact is written BEFORE the drop, so it still lists a forbidden
      row. Anything reading candidates as "what the board priced" is reading it wrong.

  WHAT THIS MEANS FOR THE PLAN'S TWO LADDERS. Section 10.5 is right that there are two, and they are
  not symmetric:
    FORBID  human forbid (known-wrong) > adjudicated verdict (verdict-suppression) > nothing.
            It removes ELIGIBILITY. It never reassigns, and there is no fall-through.
    ASSIGN  human assign > rule proposal.
            NOTHING IN THE ENGINE IMPLEMENTS THIS TODAY. compare-deals has exactly one assignment
            path, the rules; discovery-verdicts' 'accepted' adds a product to the Hy-Vee catalog pull
            and lets the ordinary rules match it. So step 2's assign ladder is NEW capability, not a
            migration - and it can move a cell the current engine could never have moved. That is why
            step 2 must ship it empty by default, or its own acceptance test ("the board is
            byte-identical before/after") cannot pass.

  HERMETIC. Like run-test-guards-weekly.ps1, this copies the tree to %TEMP% and works there: it
  overwrites known-wrong.json and needs compare-deals.ps1 to find it at $PSScriptRoot. Nothing under
  the real grocery\ is read for data or written at all.

  Exit 0 = every case behaved. 1 = a case regressed (the semantics moved; step 2's precedence logic
  is now wrong). 3 = could not evaluate (the fixture tree could not be built).
#>
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
# COMPLETION MARKER CONTRACT. Every detector the chain calls must say it REACHED THE END - an exit code
# alone cannot tell a clean run from a crash three cases in. audit-guard-contract flagged this file the
# moment it was wired into check-ad-cycles, which is the contract working.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = $PSScriptRoot
$pass = 0
$failed = 0
function Say($s) { if (-not $Quiet) { Write-Output $s } }

# ---------------------------------------------------------------- the hermetic copy
$dst = Join-Path $env:TEMP 'tc-precedence-fixture'
# /XD out archive: out\ is 385 MB of capture data this fixture must never read (its whole point is a
# corpus of exactly one row), and archive\ is frozen code.
robocopy $root $dst /MIR /NFL /NDL /NJH /NJS /XD (Join-Path $root 'out') (Join-Path $root 'archive') /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) {
  Write-Output ("test-precedence-ladders: hermetic copy FAILED (robocopy rc=" + $LASTEXITCODE + ") - nothing was proven")
  Write-GuardComplete -Name 'precedence-ladders' -Summary 'BLIND: fixture tree could not be built'
  exit 3
}
$fxOut = Join-Path $dst 'out'
New-Item -ItemType Directory -Force (Join-Path $fxOut 'regular') | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Fixture([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }

# TWO COMMODITIES, ONE INCLUDE, ALPHA FIRST. This is the contested shape on purpose: both patterns
# want the product, so array order decides, and "does a forbid hand the row to beta?" has a visible
# answer. Empty exclude lists and an empty bands file keep every other engine rule out of the result.
$COMMODITIES = @'
[
  { "id": "alpha-thing", "label": "Alpha Thing", "unit": "oz", "include": ["\\bwidget\\b"], "exclude": [] },
  { "id": "beta-thing",  "label": "Beta Thing",  "unit": "oz", "include": ["\\bwidget\\b"], "exclude": [] }
]
'@
$comFile = Join-Path $dst 'fixture-commodities.json'
$bandFile = Join-Path $dst 'fixture-bands.json'
Write-Fixture $comFile $COMMODITIES
Write-Fixture $bandFile '{ "bands": {} }'

function Ads([string]$item, [string]$price, [string]$size) {
  return ('{ "today": "2026-08-21", "deals": [ { "store": "Aldi", "item": "' + $item + '", "ad_price": "' + $price + '", "size": "' + $size + '", "regular": "", "source_ad": "fixture" } ] }')
}
function Kw([string]$commodity, [string]$store, [string]$name, [bool]$reversed) {
  $rev = if ($reversed) { ', "reversed_on": "2026-08-22", "reversed_by": "fixture"' } else { '' }
  return ('{ "schema": 1, "entries": [ { "commodity": "' + $commodity + '", "store": "' + $store + '", "names": ["' + $name + '"], "ruled_by": "fixture", "ruled_on": "2026-08-22", "evidence": "fixture"' + $rev + ' } ] }')
}
$KW_NONE = '{ "schema": 1, "entries": [] }'

function Invoke-Board([string]$tag, [string]$kwJson, [string]$adsJson) {
  <#
    Runs the REAL compare-deals.ps1 in the copy and returns what it put on the board.
    NO STDERR REDIRECTION on the child: this file sets EAP=Stop, and in PS 5.1 redirecting a native
    child's stderr makes its first line a terminating throw (test-native-stderr-eap.ps1's founding
    bug). Everything asserted on is read back out of the written artifacts, not out of stdout.
  #>
  Write-Fixture (Join-Path $dst 'known-wrong.json') $kwJson
  $adsFile = Join-Path $fxOut 'ads-2026-08-21.json'
  Write-Fixture $adsFile $adsJson
  $od = Join-Path $dst ('board-' + $tag)
  if (Test-Path $od) { Remove-Item $od -Recurse -Force }
  New-Item -ItemType Directory -Force $od | Out-Null
  $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dst 'compare-deals.ps1') `
    -MinStores 1 -OutDir $od -AdsFile $adsFile -RegularDir (Join-Path $fxOut 'regular') -ExtraDir $fxOut `
    -CommoditiesFile $comFile -BandsFile $bandFile -OutName 'prec'
  $rc = $LASTEXITCODE
  $boardFile = Join-Path $od 'prec-2026-08-21.json'
  $candFile = Join-Path $od 'prec-candidates-2026-08-21.json'
  $cells = @()
  $cands = @()
  if (Test-Path $boardFile) { $cells = @((Read-JsonFile $boardFile).comparison) }
  if (Test-Path $candFile) { $cands = @((Read-JsonFile $candFile).commodities) }
  return [pscustomobject]@{ rc = $rc; ids = @($cells | ForEach-Object { [string]$_.id }); candIds = @($cands | ForEach-Object { [string]$_.id }) }
}

function Case([string]$name, [string]$expectIds, $result) {
  # $expectIds is the comma-joined commodity id list the board must carry, '' for an empty board.
  $got = (@($result.ids) -join ',')
  if ($result.rc -ne 0) { Write-Output ("  FAIL  {0}: compare-deals exited {1} - the case proved nothing" -f $name, $result.rc); $script:failed++; return }
  if ($got -eq $expectIds) { Say ("  PASS  {0}  board=[{1}]" -f $name, $got); $script:pass++ }
  else { Write-Output ("  FAIL  {0}  expected board=[{1}], got [{2}]" -f $name, $expectIds, $got); $script:failed++ }
}

Say 'test-precedence-ladders: the FORBID ladder, on the real engine'

# 1. BASELINE. No ruling: first-match-wins gives the row to alpha-thing. If this case ever stops
#    saying alpha, the fixture's contested shape is gone and every case below is vacuous.
$r1 = Invoke-Board 'a-baseline' $KW_NONE (Ads 'Acme Widget 16 oz' '$4.00' '16 oz')
Case 'baseline: first-match-wins gives the row to the EARLIER commodity' 'alpha-thing' $r1

# 2. THE PLAN'S QUESTION. A known-wrong on the commodity the rules proposed. The board goes EMPTY:
#    beta-thing, whose include matched the same name, does NOT inherit the row.
$r2 = Invoke-Board 'b-forbid-proposed' (Kw 'alpha-thing' 'Aldi' 'Acme Widget 16 oz' $false) (Ads 'Acme Widget 16 oz' '$4.00' '16 oz')
Case 'forbid the proposed commodity: the row DROPS, it does NOT fall through to beta' '' $r2
# and the same run proves WHERE the drop happens: candidates is written before it.
if (@($r2.candIds) -contains 'alpha-thing') {
  Say '  PASS  the drop is POST-MATCH: candidates-<date>.json still lists the forbidden row'
  $pass++
} else {
  Write-Output '  FAIL  candidates-<date>.json no longer lists the forbidden row - the drop moved earlier than the candidates write, and every reader of that artifact changed meaning'
  $failed++
}

# 3. A ruling on a commodity the rules never proposed is INERT. This is what makes the ladder a
#    forbid on (commodity, store, product) rather than a ban on the product.
$r3 = Invoke-Board 'c-forbid-unproposed' (Kw 'beta-thing' 'Aldi' 'Acme Widget 16 oz' $false) (Ads 'Acme Widget 16 oz' '$4.00' '16 oz')
Case 'forbid a commodity the rules never proposed: inert' 'alpha-thing' $r3

# 4. STORE SCOPE. Same commodity, same product, a different store's ruling: inert.
$r4 = Invoke-Board 'd-other-store' (Kw 'alpha-thing' 'Hy-Vee' 'Acme Widget 16 oz' $false) (Ads 'Acme Widget 16 oz' '$4.00' '16 oz')
Case 'a ruling for another store does not touch this one' 'alpha-thing' $r4

# 5. THE UNIT-STRIPPED CORE. The ruling names the 16 oz listing; the store now lists 24 oz. Still
#    forbidden - this is KwCore, and it is why a rename cannot launder a ruling.
$r5 = Invoke-Board 'e-core-rename' (Kw 'alpha-thing' 'Aldi' 'Acme Widget 16 oz' $false) (Ads 'Acme Widget 24 oz' '$6.00' '24 oz')
Case 'a re-listed pack size does not escape the ruling (KwCore)' '' $r5

# 6. REVERSAL. reversed_on + reversed_by makes the entry history. The row comes back.
$r6 = Invoke-Board 'f-reversed' (Kw 'alpha-thing' 'Aldi' 'Acme Widget 16 oz' $true) (Ads 'Acme Widget 16 oz' '$4.00' '16 oz')
Case 'a REVERSED ruling is history, not a gate' 'alpha-thing' $r6

# 7. THE ASSIGN LADDER DOES NOT EXIST YET. Frozen as a source fact, because the danger is a builder
#    reading section 10.5's "two ladders" and assuming the second one is already implemented and
#    merely needs migrating. compare-deals resolves a commodity in exactly ONE place. If a second
#    assignment path is ever added, this case must be updated DELIBERATELY - which is the point.
$cdSrc = Get-Content (Join-Path $dst 'compare-deals.ps1') -Raw
$resolveSites = @([regex]::Matches($cdSrc, 'Resolve-Commodity\s+-Matcher')).Count
if ($resolveSites -eq 1) {
  Say '  PASS  assign ladder: compare-deals still has exactly ONE assignment path (the rules) - a human assign is new capability, not a migration'
  $pass++
} else {
  Write-Output ("  FAIL  assign ladder: compare-deals now has {0} Resolve-Commodity call sites. Step 2's assign precedence was designed against ONE. Re-read the engine before changing the ladder." -f $resolveSites)
  $failed++
}

Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output ("test-precedence-ladders: {0} passed, {1} failed" -f $pass, $failed)
Write-GuardComplete -Name 'precedence-ladders' -Summary ("passed=" + $pass + " failed=" + $failed)
if ($failed -gt 0) { exit 1 }
exit 0
