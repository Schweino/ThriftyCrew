<#
  adjudicate-blind-findings.ps1 - turns BLIND store findings into verdicts for the weekly accuracy sample.

  WHY THIS EXISTS. The worklist asks the verifier for a verdict, but the verdict vocabulary
  ("ok = the board names the CHEAPEST qualifying product and its price is right") cannot be judged by
  someone who is blind to the board - and the blindness is the whole point of the exercise. Shown our
  answer first, a verifier confirms the price and never asks whether the row is the right product at all.
  That is exactly how a bag of cat food held the salmon crown for 22 days.

  So the run is split in two, and the ORDER is the safeguard:
    1. Store agents answer "what is the cheapest product at this store that IS this commodity, and what
       does it cost per unit" with no access to our answer, and their findings are FROZEN to disk.
    2. Only then does this script open the sealed key and compare. Because the findings are already
       written, our answer cannot have steered the search - which is the property blindness was
       protecting. Opening the key BEFORE step 1 completes destroys it and nothing here can recover it.

  It does NOT try to decide product identity by string similarity. A name comparison can say "these two
  strings look unrelated"; it cannot say "cat food is not salmon" reliably in either direction. So rows
  fall into three buckets:
      auto-ok        same product, price inside tolerance         -> verdict written automatically
      review-price   same product, price outside tolerance        -> a human picks wrong-price vs wrong-size
      review-product names do not obviously match                 -> a human picks ok vs wrong-product
  Review rows are the only place board answers are printed, and by then the finding is already frozen.

  Usage:
    adjudicate-blind-findings.ps1 -Findings <merged.csv> -Date 2026-08-08              (report + review sheet)
    adjudicate-blind-findings.ps1 -Findings <merged.csv> -Date 2026-08-08 -Decisions <decisions.csv> -Write
        -Write fills the verdict column of out\verification-worklist-<Date>.csv

  Findings CSV columns: ticket,found_product,found_price,found_pack,availability,reachable,note
  Decisions CSV columns: ticket,verdict            (only for rows this script routed to review)

  Exit 0 = adjudicated. Exit 1 = bad input.
#>
param(
  [Parameter(Mandatory = $true)][string]$Findings,
  [Parameter(Mandatory = $true)][string]$Date,
  [string]$Decisions = '',
  [double]$RelTol = 0.03,
  [double]$AbsTol = 0.0015,
  [switch]$Write
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'
$keyPath = Join-Path $outDir ('verification-sample-' + $Date + '.json')
$wlPath = Join-Path $outDir ('verification-worklist-' + $Date + '.csv')
$reviewPath = Join-Path $outDir ('verification-review-' + $Date + '.csv')
$enc = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $Findings)) { Write-Output ('adjudicate: findings file not found: ' + $Findings); exit 1 }
if (-not (Test-Path $keyPath))  { Write-Output ('adjudicate: sealed key not found: ' + $keyPath); exit 1 }
if (-not (Test-Path $wlPath))   { Write-Output ('adjudicate: worklist not found: ' + $wlPath); exit 1 }

# ---- read the frozen findings ---------------------------------------------------------------------------
$ftxt = ((Get-Content $Findings -Raw -Encoding UTF8) + '')
$flines = @($ftxt -split "`r?`n" | Where-Object { -not ($_ -match '^\s*#') -and $_.Trim().Length -gt 0 })
$frows = @($flines | ConvertFrom-Csv)
if ($frows.Count -eq 0) { Write-Output 'adjudicate: findings parsed to zero rows.'; exit 1 }
$find = @{}
foreach ($r in $frows) {
  $t = ([string]$r.ticket).Trim()
  if ($t -eq '') { continue }
  $find[$t] = $r
}

$key = ((Get-Content $keyPath -Raw -Encoding UTF8) + '') | ConvertFrom-Json
$cells = @($key.cells)

$decided = @{}
if ($Decisions -and (Test-Path $Decisions)) {
  $dtxt = ((Get-Content $Decisions -Raw -Encoding UTF8) + '')
  $dlines = @($dtxt -split "`r?`n" | Where-Object { -not ($_ -match '^\s*#') -and $_.Trim().Length -gt 0 })
  foreach ($d in @($dlines | ConvertFrom-Csv)) {
    $t = ([string]$d.ticket).Trim()
    $v = ([string]$d.verdict).Trim().ToLower()
    if ($t -ne '' -and $v -ne '') { $decided[$t] = $v }
  }
}

# ---- name comparison ------------------------------------------------------------------------------------
# Deliberately crude and deliberately BIASED TOWARD REVIEW: this decides who gets looked at, never who
# passes. A false "these match" would auto-ok a cat-food-for-salmon row, so the bar for auto-matching is
# high and everything else goes to a human.
$STOP = @('the','a','an','of','and','or','with','in','for','pack','ct','count','oz','lb','lbs','fl','floz','each',
          'ea','size','value','great','members','mark','our','family','kroger','simple','truth','thats','smart',
          'full','circle','brand','organic','all','natural','net','wt','inch','in.','case','bag','box','jar','can',
          'bottle','bulk','club')
function NormTokens([string]$s) {
  $s = ([string]$s).ToLower()
  $s = $s -replace "[^a-z0-9 ]", ' '
  $t = @($s -split '\s+' | Where-Object { $_.Length -gt 2 -and $STOP -notcontains $_ -and $_ -notmatch '^\d+$' })
  return , @($t | Sort-Object -Unique)
}
function NameOverlap([string]$a, [string]$b) {
  $ta = NormTokens $a; $tb = NormTokens $b
  if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0.0 }
  $hit = 0
  foreach ($x in $ta) { if ($tb -contains $x) { $hit++ } }
  $den = [Math]::Min($ta.Count, $tb.Count)
  if ($den -le 0) { return 0.0 }
  return [double]$hit / [double]$den
}

# ---- adjudicate -----------------------------------------------------------------------------------------
$verdicts = @{}
$review = New-Object System.Collections.ArrayList
$auto = 0; $unv = 0; $miss = 0; $noFinding = 0

foreach ($c in $cells) {
  $t = [string]$c.ticket
  $f = $find[$t]
  if ($null -eq $f) { $noFinding++; continue }

  $reach = ([string]$f.reachable).Trim().ToLower()
  $avail = ([string]$f.availability).Trim().ToLower()
  $fpTxt = ([string]$f.found_price).Trim() -replace '[\$,]', ''
  $fprod = ([string]$f.found_product).Trim()

  if ($decided.ContainsKey($t)) { $verdicts[$t] = $decided[$t]; continue }

  if ($reach -eq 'no') { $verdicts[$t] = 'unverifiable'; $unv++; continue }
  if ($avail -eq 'not-sold') { $verdicts[$t] = 'missing'; $miss++; continue }
  if ($fpTxt -eq '' -or -not ($fpTxt -as [double])) { $verdicts[$t] = 'unverifiable'; $unv++; continue }

  $found = [double]$fpTxt
  $board = [double]$c.board_per_unit
  $bItem = [string]$c.board_item
  if ($board -le 0) {
    [void]$review.Add([pscustomobject]@{ ticket = $t; why = 'review-price'; commodity = [string]$c.label; store = [string]$c.store
      board_item = $bItem; board_per_unit = $board; found_product = $fprod; found_price = $found
      found_pack = ([string]$f.found_pack); ratio = ''; note = ([string]$f.note); verdict = '' })
    continue
  }
  $rel = [Math]::Abs($found - $board) / $board
  $tol = [Math]::Max($RelTol * $board, $AbsTol)
  $priceOk = ([Math]::Abs($found - $board) -le $tol)
  $ov = NameOverlap $fprod $bItem

  if ($ov -ge 0.6 -and $priceOk) { $verdicts[$t] = 'ok'; $auto++; continue }

  $why = if ($ov -ge 0.6) { 'review-price' } else { 'review-product' }
  [void]$review.Add([pscustomobject]@{
    ticket = $t; why = $why; commodity = [string]$c.label; store = [string]$c.store
    board_item = $bItem; board_per_unit = ('{0:N4}' -f $board)
    found_product = $fprod; found_price = ('{0:N4}' -f $found)
    found_pack = ([string]$f.found_pack)
    ratio = ('{0:N3}' -f ($found / $board))
    note = ([string]$f.note)
    verdict = ''
  })
}

Write-Output ('adjudicate-blind-findings: ' + $cells.Count + ' sampled cells, ' + $find.Count + ' blind findings on file')
Write-Output ('  auto-ok        : ' + $auto + '   (name matched AND price within ' + ('{0:N0}' -f (100 * $RelTol)) + '% / $' + $AbsTol + ')')
Write-Output ('  unverifiable   : ' + $unv)
Write-Output ('  missing        : ' + $miss + '   (store does not sell it - a DEFECT, the board prices it)')
Write-Output ('  needs review   : ' + $review.Count)
if ($noFinding -gt 0) { Write-Output ('  NO FINDING AT ALL: ' + $noFinding + ' - these stay blank in the worklist and are recorded as NOT VERIFIED, never as ok.') }
if ($decided.Count -gt 0) { Write-Output ('  decisions applied: ' + $decided.Count) }

if ($review.Count -gt 0) {
  $review | Sort-Object why, store | Export-Csv -Path $reviewPath -NoTypeInformation -Encoding UTF8
  Write-Output ('  review sheet -> ' + $reviewPath)
  Write-Output '  Fill its verdict column, then re-run with -Decisions <that file> -Write.'
}

if ($Write) {
  $lines = @(Get-Content $wlPath -Encoding UTF8)
  $outLines = New-Object System.Collections.ArrayList
  $hdrSeen = $false
  $filled = 0
  foreach ($ln in $lines) {
    if ($ln -match '^\s*#' -or $ln.Trim().Length -eq 0) { [void]$outLines.Add($ln); continue }
    if (-not $hdrSeen) { $hdrSeen = $true; [void]$outLines.Add($ln); continue }
    $row = @($ln | ConvertFrom-Csv -Header @('ticket','seq','commodity','unit','store','verdict','found_product','found_price','note'))[0]
    $t = ([string]$row.ticket).Trim()
    if (-not $verdicts.ContainsKey($t)) { [void]$outLines.Add($ln); continue }
    $f = $find[$t]
    function Q([string]$s) { return '"' + (([string]$s) -replace '"', '""') + '"' }
    $noteParts = @()
    if ($f) {
      if (([string]$f.found_pack).Trim() -ne '') { $noteParts += ([string]$f.found_pack).Trim() }
      if (([string]$f.note).Trim() -ne '') { $noteParts += ([string]$f.note).Trim() }
    }
    $new = (Q $t) + ',' + $row.seq + ',' + (Q $row.commodity) + ',' + (Q $row.unit) + ',' + (Q $row.store) + ',' +
           $verdicts[$t] + ',' + (Q $(if ($f) { [string]$f.found_product } else { '' })) + ',' +
           (Q $(if ($f) { [string]$f.found_price } else { '' })) + ',' + (Q ($noteParts -join ' | '))
    [void]$outLines.Add($new)
    $filled++
  }
  [IO.File]::WriteAllText($wlPath, (($outLines -join "`r`n") + "`r`n"), $enc)
  Write-Output ('  WROTE ' + $filled + ' verdict(s) into ' + $wlPath)
}
exit 0
