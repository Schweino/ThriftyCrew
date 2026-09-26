<#
  HOLD SCOPE: cell - names each store-contradicted cell (QUARANTINE-CELL ... value)
  audit-flag-verification.ps1 - a cell whose price the STORE contradicted quarantines itself.

  A delegated guards audit (guards.ps1 runs it with the others). It reads out\flag-verification.json, which
  verify-price-flags.ps1 keeps (grocery/triage-plans/plan-2026-09-21-8.json), and names every OPEN disagreement -
  wrong-price or wrong-product - whose contradicted claim (product and published per-unit) is still what this board
  publishes for that cell, in the protocol cell-quarantine-lib.ps1 Get-TcChildQuarantineScope reads:
      QUARANTINE-CELL <commodity-id>|<store>|value
      QUARANTINE-SCOPE complete cells=<N> stores=0
  guards then scopes the failure to those cells, apply-cell-quarantine.ps1 holds each at its last verified published
  price or withholds it, and guards runs again. On that second run the held cell publishes its last verified value, not
  the contradicted claim, so it is not named again; a withheld cell is gone from the board and is not named either.
  Both verdicts condemn the NUMBER ('value'): a price the store does not charge, or a price for a product the
  commodity's own rule refuses, is not a number the board may show for that cell.

  IT RE-JUDGES BEFORE IT NAMES (2026-09-26, queue 2026-09-26-f73dc7). verify-price-flags.ps1 runs AFTER the board ships (it
  needs sanity-check's flags), so the ledger guards reads was judged one chain earlier, by whatever verifier code ran then:
  on 2026-09-26 guards read yellow-bell-pepper / Family Fare at 08:13 and the 17c0da verifier fix re-judged it a match at
  08:26. So every OPEN entry is re-judged here, with this code, over the captures on disk (Invoke-TcFlagRejudge ->
  Resolve-TcFlagEntry, the lane's own resolver), before any cell is named, and nothing is written. A disagreement the
  fresh judge calls a match is not named; a pending entry the fresh judge condemns IS named, this run. A re-judge that
  cannot look (could-not-look) never downgrades a stored disagreement, and a re-judge that cannot RUN at all (a throw)
  falls back to the stored verdicts and says so: missing evidence holds, it never passes.
  -NoRejudge reads the stored verdicts only (the pre-2026-09-26 behaviour), for a replay. Fixtures: test-flag-verification-rejudge.ps1.

  SCOPE OF A CLEAN REPORT: complete over the ledger it reads - every open disagreement still on the board is named, by
  construction - and unsound about the board as a whole: it can only name cells the verifier has put to a store, which
  are cells a sanity flag named. A clean run says no flagged price is contradicted by its store; it says nothing about
  a price nobody flagged.

  Exit 0 = no contradicted claim is on this board. 2 = cells named (the scope line follows). 3 = could not evaluate
  (no board, or no readable ledger): guards reports that as a WARN naming what went unproven, never as a pass.
#>
[CmdletBinding()]
param([string]$OutDir = '', [string]$BoardFile = '', [string]$LedgerFile = '', [string]$Today = '', [switch]$NoRejudge)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $root -Parent
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $root 'pu-lib.ps1')
. (Join-Path $root 'match-lib.ps1')
. (Join-Path $root 'global-exclude-lib.ps1')
. (Join-Path $root 'flag-verify-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $Today) { $Today = (Get-Date).ToString('yyyy-MM-dd') }
if (-not $BoardFile) {
  $bf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if ($bf) { $BoardFile = $bf.FullName }
}
if (-not $BoardFile -or -not (Test-Path -LiteralPath $BoardFile)) { Write-Output 'BLIND: no comparison board to audit'; Exit-Guard -Name 'audit-flag-verification' -Summary 'no board' -Code 3 }
if (-not $LedgerFile) { $LedgerFile = Join-Path $OutDir $script:TcFlagLedgerName }
if (-not (Test-Path -LiteralPath $LedgerFile)) { Write-Output ('BLIND: no ' + (Split-Path $LedgerFile -Leaf) + ' yet - verify-price-flags.ps1 has not run here, so no flagged price has been put to a store'); Exit-Guard -Name 'audit-flag-verification' -Summary 'no ledger' -Code 3 }
$ledger = $null
try { $ledger = Read-JsonFile $LedgerFile } catch { $ledger = $null }
if ($null -eq $ledger) { Write-Output ('BLIND: ' + (Split-Path $LedgerFile -Leaf) + ' is unreadable'); Exit-Guard -Name 'audit-flag-verification' -Summary 'ledger unreadable' -Code 3 }
$board = Read-JsonFile $BoardFile
$judged = $ledger
$openN = @((ConvertTo-TcLedgerEntries $ledger).Keys).Count
if ($NoRejudge) { Write-Output ('flag verification: -NoRejudge - naming cells from the STORED verdicts of ' + $openN + ' open entr(ies), judged ' + [string]$ledger.generated) }
elseif ($openN -gt 0) {
  try {
    $upTo = ConvertTo-TcFvDay $Today
    if ($null -eq $upTo) { throw ('-Today ' + $Today + ' is not a yyyy-MM-dd date') }
    $rjStores = @(@((ConvertTo-TcLedgerEntries $ledger).Values) | ForEach-Object { [string]$_.store } | Sort-Object -Unique)
    $rjAns = Read-TcStoreAnswerRows -OutDir $OutDir -GroceryRoot $root -Stores $rjStores -UpTo $upTo
    foreach ($nl in @($rjAns.notes)) { Write-Output $nl }
    $script:afvCtx = New-TcRereadContext -GroceryRoot $root -RowsByStore $rjAns.rows
    $rj = Invoke-TcFlagRejudge -Ledger $ledger -Board $board -Today $Today -Resolve { param($e) Resolve-TcFlagEntry -Entry $e -Context $script:afvCtx }
    $judged = $rj.ledger
    $moved = @(@($rj.changes) | Where-Object { @('match', 'wrong-price', 'wrong-product') -contains [string]$_.change })
    foreach ($c in $moved) { Write-Output ('  RE-JUDGED NOW: ' + $c.key + ' -> ' + $c.change + ' (the stored verdict was judged ' + [string]$ledger.generated + ')') }
    Write-Output ('flag verification: re-judged ' + $openN + ' open entr(ies) with this code over captures up to ' + $Today + ' (stored ledger judged ' + [string]$ledger.generated + '); ' + $moved.Count + ' verdict(s) moved')
  } catch {
    $judged = $ledger
    Write-Output ('flag verification: RE-JUDGE COULD NOT RUN (' + $_.Exception.Message + ') - naming cells from the STORED verdicts, which fails closed')
  }
}
$cells = Get-TcFlagQuarantineCells -Ledger $judged -Board $board
$n = @($cells).Count
if ($n -eq 0) {
  Write-Output ('flag verification: no store-contradicted claim is on ' + (Split-Path $BoardFile -Leaf))
  Exit-Guard -Name 'audit-flag-verification' -Summary 'cells=0' -Code 0
}
foreach ($c in @($cells)) { Write-Output ('  CONTRADICTED BY ITS STORE: ' + $c.id + ' / ' + $c.store + ' [' + $c.status + '] ' + $c.reason) }
foreach ($c in @($cells)) { Write-Output ('QUARANTINE-CELL ' + $c.id + '|' + $c.store + '|' + $c.kind) }
Write-Output ('QUARANTINE-SCOPE complete cells=' + $n + ' stores=0')
Exit-Guard -Name 'audit-flag-verification' -Summary ('cells=' + $n) -Code 2
