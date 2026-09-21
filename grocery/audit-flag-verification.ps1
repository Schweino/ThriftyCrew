<#
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

  SCOPE OF A CLEAN REPORT: complete over the ledger it reads - every open disagreement still on the board is named, by
  construction - and unsound about the board as a whole: it can only name cells the verifier has put to a store, which
  are cells a sanity flag named. A clean run says no flagged price is contradicted by its store; it says nothing about
  a price nobody flagged.

  Exit 0 = no contradicted claim is on this board. 2 = cells named (the scope line follows). 3 = could not evaluate
  (no board, or no readable ledger): guards reports that as a WARN naming what went unproven, never as a pass.
#>
[CmdletBinding()]
param([string]$OutDir = '', [string]$BoardFile = '', [string]$LedgerFile = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $root -Parent
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $root 'flag-verify-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
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
$cells = Get-TcFlagQuarantineCells -Ledger $ledger -Board $board
$n = @($cells).Count
if ($n -eq 0) {
  Write-Output ('flag verification: no store-contradicted claim is on ' + (Split-Path $BoardFile -Leaf))
  Exit-Guard -Name 'audit-flag-verification' -Summary 'cells=0' -Code 0
}
foreach ($c in @($cells)) { Write-Output ('  CONTRADICTED BY ITS STORE: ' + $c.id + ' / ' + $c.store + ' [' + $c.status + '] ' + $c.reason) }
foreach ($c in @($cells)) { Write-Output ('QUARANTINE-CELL ' + $c.id + '|' + $c.store + '|' + $c.kind) }
Write-Output ('QUARANTINE-SCOPE complete cells=' + $n + ' stores=0')
Exit-Guard -Name 'audit-flag-verification' -Summary ('cells=' + $n) -Code 2
