<#
  test-board-clock.ps1 - the REAL engine judges a board at the real date, and a rollback reverts to its was-price.

  WHY THIS FILE EXISTS (2026-09-26, design\PLAN-board-clock-2026-09-26.md). compare-deals used the ad set's date
  ($ads.today, the D in comparison-<D>.json) as "today". ads-<D>.json is written only on a day a weekly ad is pulled,
  so with no ad due 09-24..09-26 the engine judged the 09-26 board at 09-23: 9 cells priced from sale and rollback
  windows that had ended 09-23..09-25, 5 of them crowned "Cheapest" on the live site. Two defects, one board:
    W1   every age and expiry read the ad date. Now they read -JudgeDate (default the real date of the run).
    W1b  a Sam's markdown arrives in its EVERYDAY file (marked_down, base_price, a 30-day TTL window) and was priced
         as everyday, so its window could never retire it. It is now a sale half with its window plus an everyday
         half at the store's own was-price, so the cell reverts on the day the window ends (Brad's D2).
  These cases run the REAL compare-deals.ps1 over a corpus of one commodity, in a per-run sandbox with the repo's
  shape, exactly as test-precedence-ladders.ps1 does - a reading of the engine is a second copy of the rule.

  THE FIXTURE, frozen: the ads file is for the 2026-09-23 ad set; Aldi has "Fixture Widget 10 oz" on sale at $2.00
  until 2026-09-25; Sam's Club has the same product marked down from $5.00 to $3.00 with a TTL window ending
  2026-09-25. Judged 2026-09-24 both sales are live and Aldi's $0.20/oz wins. Judged 2026-09-26 both have ended:
  Aldi's sale is gone, and Sam's reverts to $5.00 ($0.50/oz), which is then the only price on the board.

  HERMETIC: nothing under the real grocery\ is read for data or written. Exit 0 = every case behaved, 1 = a case
  regressed, 3 = could not evaluate (the sandbox could not be built or could not load its libraries).
  SCOPE OF A CLEAN REPORT: sound for the two defects above over this corpus; it says nothing about stores or row
  shapes it does not build.
#>
# gate-inputs: grocery\test-board-clock.ps1, grocery\compare-deals.ps1, lib\json-io.ps1, lib\guard-contract.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')        # Read-JsonFile
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')  # Exit-Guard: the completion marker
$root = $PSScriptRoot
$script:bcPass = 0; $script:bcFail = 0; $script:bcRan = 0
function Say($s) { if (-not $Quiet) { Write-Output $s } }
function Case([string]$label, [bool]$ok, [string]$got) {
  $script:bcRan++
  if ($ok) { Say ('  PASS  ' + $label); $script:bcPass++ } else { Write-Output ('  FAIL  ' + $label + '   got: ' + $got); $script:bcFail++ }
}

# ---- the sandbox: <base>\grocery beside <base>\lib with EVERY lib\*.ps1, named per run (test-precedence-ladders) ----
$base = Join-Path $env:TEMP ('tcbc-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$g = Join-Path $base 'grocery'
New-Item -ItemType Directory -Path (Join-Path $base 'lib') -Force -ErrorAction Stop | Out-Null
robocopy $root $g /MIR /NFL /NDL /NJH /NJS /XD (Join-Path $root 'out') (Join-Path $root 'archive') /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) {
  Write-Output ('test-board-clock: hermetic copy FAILED (robocopy rc=' + $LASTEXITCODE + ') - nothing was proven')
  Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
  Exit-Guard -Name 'board-clock' -Summary 'BLIND: fixture tree could not be built' -Code 3
}
foreach ($lf in @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $root) 'lib') -Filter '*.ps1' -File)) {
  Copy-Item -LiteralPath $lf.FullName -Destination (Join-Path $base ('lib\' + $lf.Name)) -ErrorAction Stop
}
try {
  # A SANDBOX IS PROVEN BY RUNNING A SUBJECT IN IT: the engine dot-sources rollback-ttl-lib, which loads ..\lib.
  $subject = Join-Path $g 'rollback-ttl-lib.ps1'
  $probe = @(& powershell -NoProfile -ExecutionPolicy Bypass -Command ("`$ErrorActionPreference = 'Stop'; try { . '" + $subject + "'; 'BC-SANDBOX-LOADED' } catch { 'BC-SANDBOX-LOAD-FAILED ' + `$_.Exception.Message; exit 1 }"))
  if (-not ($LASTEXITCODE -eq 0 -and (@($probe) -contains 'BC-SANDBOX-LOADED'))) {
    Write-Output ('test-board-clock: the sandbox cannot load its libraries: ' + (@($probe) -join ' | '))
    Exit-Guard -Name 'board-clock' -Summary 'BLIND: the sandbox could not load lib\ - nothing was proven' -Code 3
  }

  $fx = Join-Path $g 'out'
  New-Item -ItemType Directory -Force (Join-Path $fx 'regular') | Out-Null
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  function Put([string]$p, [string]$t) { [IO.File]::WriteAllText($p, $t, $utf8) }
  $com = Join-Path $g 'fixture-commodities.json'
  Put $com '[ { "id": "fixture-widget", "label": "Fixture Widget", "unit": "oz", "include": ["\\bwidget\\b"], "exclude": [] } ]'
  $bands = Join-Path $g 'fixture-bands.json'
  Put $bands '{ "bands": {} }'
  $ads = Join-Path $fx 'ads-2026-09-23.json'
  Put $ads '{ "today": "2026-09-23", "deals": [ { "store": "Aldi", "item": "Fixture Widget 10 oz", "ad_price": "$2.00", "size": "10 oz", "regular": "", "source_ad": "fixture weekly ad", "ad_from": "2026-09-20", "ad_to": "2026-09-25" } ] }'
  $sams = Join-Path $fx 'sams-deals-2026-09-23.json'
  Put $sams ('{ "store": "Sam''s Club", "price_type": "everyday", "deals": [ { "store": "Sam''s Club", "item": "Fixture Widget 10 oz", "ad_price": "$3.00", "size": "10 oz", "regular": null, ' +
    '"source_ad": "everyday club price (fixture)", "as_of": "2026-09-23", "sams_item_id": "FIXTUREWIDGET1", "marked_down": true, "base_price": 5.00, ' +
    '"ad_from": "2026-08-26", "ad_to": "2026-09-25", "ad_basis": "TTL - fixture" } ] }')

  function Invoke-Board([string]$tag, [string]$judge) {
    $od = Join-Path $g ('board-' + $tag)
    New-Item -ItemType Directory -Force $od | Out-Null
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $g 'compare-deals.ps1'), '-MinStores', '1', '-OutDir', $od,
      '-AdsFile', $ads, '-SamsFile', $sams, '-RegularDir', (Join-Path $fx 'regular'), '-ExtraDir', $fx,
      '-CommoditiesFile', $com, '-BandsFile', $bands, '-OutName', 'clock', '-NoProvenanceContract')
    if ($judge) { $argv += @('-JudgeDate', $judge) }
    # No stderr redirection: this file runs under EAP=Stop (ops-and-gates og-04). Everything asserted on is read back
    # out of the written board.
    $null = & powershell @argv
    $rc = $LASTEXITCODE
    $bf = Join-Path $od 'clock-2026-09-23.json'
    $doc = if (Test-Path -LiteralPath $bf) { Read-JsonFile $bf } else { $null }
    $row = if ($doc) { @($doc.comparison | Where-Object { [string]$_.id -eq 'fixture-widget' }) | Select-Object -First 1 } else { $null }
    $cells = if ($row) { @($row.stores) } else { @() }
    return [pscustomobject]@{ rc = $rc; doc = $doc; row = $row; cells = $cells }
  }
  function Cell($b, [string]$store) { return (@($b.cells | Where-Object { [string]$_.store -eq $store }) | Select-Object -First 1) }
  function Show($b) { if (-not $b.doc) { return ('rc=' + $b.rc + ' no board') }; return ('rc=' + $b.rc + ' cheapest=' + [string]$b.row.cheapest_store + ' cells=' + ((@($b.cells) | ForEach-Object { [string]$_.store + ':' + [string]$_.type + ':' + [string]$_.per_unit }) -join ',')) }

  # ---- judged INSIDE both windows ----
  $live = Invoke-Board 'live' '2026-09-24'
  Case 'CLEAN TWIN  judged 09-24, inside both windows: Aldi''s $2.00 sale is priced and holds the crown' ($live.rc -eq 0 -and [string]$live.row.cheapest_store -eq 'Aldi' -and (Cell $live 'Aldi')) (Show $live)
  $sLive = Cell $live "Sam's Club"
  Case 'CLEAN TWIN  judged 09-24, Sam''s markdown is priced as a SALE at $3.00 (0.3/oz) with its window' ($sLive -and [string]$sLive.type -eq 'sale' -and [math]::Abs([double]$sLive.per_unit - 0.3) -lt 0.0001 -and [string]$sLive.ad_to -eq '2026-09-25') (Show $live)
  Case 'CLEAN TWIN  the board is named for the ad set and records the judge date beside it' ($live.doc -and [string]$live.doc.week_of -eq '2026-09-23' -and [string]$live.doc.judged_on -eq '2026-09-24') ('week_of=' + [string]$live.doc.week_of + ' judged_on=' + [string]$live.doc.judged_on)

  # ---- judged AFTER both windows: the founding day ----
  $ended = Invoke-Board 'ended' '2026-09-26'
  Case 'MUST FIRE  judged 09-26, Aldi''s sale that ended 09-25 is not on the board (the ad date 09-23 kept it before the fix)' ($ended.rc -eq 0 -and $ended.row -and -not (Cell $ended 'Aldi')) (Show $ended)
  $sEnd = Cell $ended "Sam's Club"
  Case 'MUST FIRE  judged 09-26, Sam''s markdown whose window ended 09-25 reverts to the store''s own was-price $5.00 (0.5/oz), priced everyday' ($sEnd -and [string]$sEnd.type -eq 'everyday' -and [math]::Abs([double]$sEnd.per_unit - 0.5) -lt 0.0001) (Show $ended)
  Case 'MUST FIRE  ...and with Aldi''s sale gone the crown moves to that reverted Sam''s price' ([string]$ended.row.cheapest_store -eq "Sam's Club") (Show $ended)
  Case 'MUST FIRE  the health record counts the dropped sale and the rollback split, and names the judge date' ($ended.doc -and [int]$ended.doc.health.expired_sale_rows_dropped -ge 1 -and [int]$ended.doc.health.rollbacks_with_revert -eq 1 -and [string]$ended.doc.health.judged_on -eq '2026-09-26') ('health=' + ($ended.doc.health | ConvertTo-Json -Compress))

  # ---- no -JudgeDate: a live build judges at the real date ----
  $dflt = Invoke-Board 'default' ''
  $realToday = (Get-Date).ToString('yyyy-MM-dd')
  Case ('CLEAN TWIN  with no -JudgeDate the board is judged at the real date of the run (' + $realToday + '), never the ad set''s 2026-09-23') ($dflt.rc -eq 0 -and $dflt.doc -and [string]$dflt.doc.judged_on -eq $realToday) ('judged_on=' + [string]$dflt.doc.judged_on)
} catch {
  Case 'the suite ran to its end with no unexpected error' $false ($_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber)
} finally {
  Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
$want = 8
if ($script:bcRan -ne $want) { Write-Output ('  FAIL  the suite ran ' + $script:bcRan + ' case(s), not the ' + $want + ' it lists'); $script:bcFail++ }
if ($script:bcFail) {
  Write-Output ('test-board-clock SELF-TEST FAIL (' + $script:bcFail + ' of ' + $want + ')')
  Exit-Guard -Name 'board-clock' -Summary ('FAIL ' + $script:bcFail + ' of ' + $want) -Code 1
}
Write-Output ('test-board-clock SELF-TEST PASS (' + $want + ' of ' + $want + ')')
Exit-Guard -Name 'board-clock' -Summary ('PASS ' + $want + ' of ' + $want) -Code 0
