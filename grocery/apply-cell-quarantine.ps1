<#
  apply-cell-quarantine.ps1 - apply the quarantine guards.ps1 asked for, to the board guards actually saw.

  Run by check-ad-cycles when guards.ps1 exits 2 with "GUARDS QUARANTINE-REQUIRED" and out\cell-quarantine.json says
  action=quarantine. For every cell named there it publishes the cell's LAST VERIFIED PUBLISHED price with that
  price's date (Brad's ruling Q1 = A, 2026-09-21), read from public\board.json as committed on origin/main, or
  WITHHOLDS the cell when no such value can be shown. For every store named there it withholds that store's
  EVERYDAY cells; its live ad cells stay. Then guards.ps1 runs again over the rewritten board and must exit 4.
  The rules are in cell-quarantine-lib.ps1; this file is only the I/O around them.

  Exit 0 = applied (the comparison board was rewritten with a `quarantine` block). Exit 2 = REFUSED, board untouched:
  the plan is not a quarantine, it was written for different board bytes, or applying it would empty a row. The
  caller then holds the board exactly as a guards failure always did. Exit 3 = could not evaluate (no plan, no board).

  -LastPublishedFile/-LastPublishedDate stand in for the git read, for a fixture or a hermetic copy with no history.
#>
[CmdletBinding()]
param([string]$OutDir = '', [string]$Repo = '', [string]$LastPublishedFile = '', [string]$LastPublishedDate = '', [string]$Today = '', [string]$ProductUrlsFile = '', [string]$PublishedUrlsFile = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
. (Join-Path $root 'cell-quarantine-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $Repo) { $Repo = Split-Path $root -Parent }
if (-not $Today) { $Today = (Get-Date).ToString('yyyy-MM-dd') }

$planF = Join-Path $OutDir 'cell-quarantine.json'
if (-not (Test-Path -LiteralPath $planF)) { Write-Output 'BLIND: no out\cell-quarantine.json - guards has not run over this board, so there is nothing to apply'; Exit-Guard -Name 'apply-cell-quarantine' -Summary 'no plan' -Code 3 }
$plan = Read-JsonFile $planF
if ([string]$plan.action -ne 'quarantine') {
  Write-Output ("REFUSED: the guards plan says action='" + [string]$plan.action + "', not 'quarantine' - only a quarantine guards asked for is applied")
  Exit-Guard -Name 'apply-cell-quarantine' -Summary ('action=' + [string]$plan.action) -Code 2
}
$boardF = Join-Path $OutDir ([string]$plan.board_file)
if (-not [string]$plan.board_file -or -not (Test-Path -LiteralPath $boardF)) { Write-Output ('BLIND: the plan names board ' + [string]$plan.board_file + ', which is not in ' + $OutDir); Exit-Guard -Name 'apply-cell-quarantine' -Summary 'no board' -Code 3 }
$shaNow = (Get-FileHash -LiteralPath $boardF -Algorithm SHA256).Hash.ToLower()
if ($shaNow -ne [string]$plan.board_sha256) {
  Write-Output ('REFUSED: ' + (Split-Path $boardF -Leaf) + ' has changed since guards wrote the plan (sha ' + $shaNow.Substring(0, 12) + ' vs ' + ([string]$plan.board_sha256).PadRight(12).Substring(0, 12) + ') - a quarantine is only applied to the board guards saw. Re-run guards.')
  Exit-Guard -Name 'apply-cell-quarantine' -Summary 'board moved' -Code 2
}
$doc = Read-JsonFile $boardF
if (Get-TcQuarantineBlock $doc) { Write-Output 'REFUSED: this board already carries an applied quarantine - it is applied once per build'; Exit-Guard -Name 'apply-cell-quarantine' -Summary 'already applied' -Code 2 }

if ($LastPublishedFile) {
  $lpDoc = Read-JsonFile $LastPublishedFile
  $lpDate = $LastPublishedDate; if (-not $lpDate) { $lpDate = (Get-Item -LiteralPath $LastPublishedFile).LastWriteTime.ToString('yyyy-MM-dd') }
  $lpc = Get-TcLastPublishedCells -BoardDoc $lpDoc -PublishedDate $lpDate
  $lp = [pscustomobject]@{ cells = $lpc.cells; n = $lpc.n; source = ('file:' + (Split-Path $LastPublishedFile -Leaf)); commit = ''; date = $lpDate }
} else { $lp = Read-TcLastPublishedBoard -Repo $Repo }
if ($null -eq $lp) { Write-Output 'last published board: NONE READABLE (neither origin/main nor HEAD carries a public/board.json that parses) - every quarantined cell will be WITHHELD, never invented' }
else { Write-Output ('last published board: ' + $lp.source + ' @ ' + $lp.commit + ' committed ' + $lp.date + ' (' + $lp.n + ' published cell value(s))') }

$maxAge = 0; if ($doc.PSObject.Properties['max_publish_age_days']) { $maxAge = [int]$doc.max_publish_age_days }
$r = Invoke-TcCellQuarantine -Board $doc -Plan $plan -LastPublished $lp -Today $Today -MaxAgeDays $maxAge
if (-not $r.ok) {
  Write-Output ('REFUSED: ' + $r.refusal + '. The board file is untouched.')
  Exit-Guard -Name 'apply-cell-quarantine' -Summary 'refused' -Code 2
}
foreach ($e in @($r.cells)) {
  if ($e.action -eq 'last-good') { Write-Output ("  held      {0} / {1}  at {2} (last verified published {3}); today's candidate was {4}" -f $e.id, $e.store, $e.per_unit, $e.since, $e.bad_per_unit) }
  else { Write-Output ("  withheld  {0} / {1}  ({2}); today's candidate was {3}" -f $e.id, $e.store, $e.why, $e.bad_per_unit) }
}
foreach ($s in @($r.stores)) { Write-Output ("  dropped   {0}  {1} everyday cell(s) withheld; its live ad cells stay" -f $s.store, $s.cells) }
($doc | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $boardF -Encoding UTF8
# THE LINK FOLLOWS THE HELD VALUE, IN THIS STEP (Update-TcQuarantineLinks has the rule and why). The board is written
# first and the links second: an interruption between them leaves a held cell with its old link, which tile-integrity
# refuses loudly, never a link pointing at a cell that is not there.
$puF = Join-Path $Repo 'grocery\product-urls.json'
if (-not $ProductUrlsFile) { $ProductUrlsFile = $puF }
if (Test-Path -LiteralPath $ProductUrlsFile) {
  $puDoc = Read-JsonFile $ProductUrlsFile
  $pubItems = $null
  if ($PublishedUrlsFile) { $pubItems = (Read-JsonFile $PublishedUrlsFile).items }
  elseif ($lp -and $lp.commit) {
    $pb = Invoke-TcGitBytes -Repo $Repo -GitArgs @('show', ($lp.commit + ':grocery/product-urls.json'))
    if ($pb.rc -eq 0 -and $pb.bytes.Length -gt 0) { $pt = [Text.Encoding]::UTF8.GetString($pb.bytes); if ($pt[0] -eq [char]0xFEFF) { $pt = $pt.Substring(1) }; try { $pubItems = ($pt | ConvertFrom-Json).items } catch { $pubItems = $null } }
  }
  $lc = Update-TcQuarantineLinks -Items $puDoc.items -Entries $r.cells -PublishedItems $pubItems
  foreach ($c in $lc) { Write-Output ("  link      {0} / {1}  {2}  {3}" -f $c.id, $c.store, $c.action, $c.url) }
  if (@($lc).Count -gt 0) { ($puDoc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $ProductUrlsFile -Encoding UTF8; Write-Output ('links: ' + @($lc).Count + ' quarantined cell link(s) moved to the held value; re-run audit-name-drift before guards (check-ad-cycles does)') }
} else { Write-Output ('links: BLIND - no ' + $ProductUrlsFile + ', so no quarantined cell''s link could be moved') }
$held = @(@($r.cells) | Where-Object { $_.action -eq 'last-good' }).Count
$wh = @(@($r.cells) | Where-Object { $_.action -eq 'withheld' }).Count
Write-Output ("applied to {0}: {1} cell(s) held at their last verified published price, {2} withheld, {3} store(s) dropped. Run guards.ps1 again: it must exit 4." -f (Split-Path $boardF -Leaf), $held, $wh, @($r.stores).Count)
Exit-Guard -Name 'apply-cell-quarantine' -Summary ("held=$held withheld=$wh stores=" + @($r.stores).Count) -Code 0
