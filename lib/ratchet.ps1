<#
  ratchet.ps1 - a high-water baseline may only go DOWN, and a drop to nothing is a broken detector.

  WHY THIS EXISTS (2026-09-07, backlog I15). Four audits here carry a high-water mark that "may only
  go DOWN", and every one of them lowered it UNCONDITIONALLY:

      if ($count -lt $base) { write the new, lower baseline }

  That is correct for a real migration and catastrophic for a broken detector. A regex that stops
  matching, a path that moved, a tree that is empty inside a worktree - any of these makes a detector
  find NOTHING, and the ratchet then records 0 as the new permanent ceiling, prints "PASSED and
  TIGHTENED", and can never rise again. The gate goes green forever on a detector that died, and the
  findings it used to catch become invisible rather than loud. audit-mustfire-census sits at 653; the
  same failure there would record "tightened" while every must-fire assertion in the estate had
  vanished.

  THE ASYMMETRY IS THE WHOLE POINT. A count that ROSE is a new finding and the detector is working. A
  count that FELL is either good news or the detector is broken, and those two look identical from
  outside - which is the same shape as guard-contract.ps1's "no findings" versus "died halfway", and
  the same shape backlog I15 describes when it says an audit that stops firing looks like one that
  passes. So a fall has to clear a plausibility bar before it is believed.

  TWO REFUSALS, and neither is a hard failure - the caller keeps its old baseline and says so:
    * COUNT ZERO while the baseline was not. Extraordinary claims. Migrating every last finding in one
      run happens; a detector breaking happens far more often, and only one of the two is reversible
      after the baseline is overwritten.
    * A DROP LARGER THAN -MaxDropPct in a single run. Same argument, weaker evidence.
  -AcceptDrop records it anyway, and exists so a genuine bulk migration is one flag rather than a
  hand-edited baseline file.

  IT ALSO KEEPS HISTORY, which is I15's actual ask. A single number cannot show a detection RATE, and
  a change in alert volume is one tripwire for several unrelated causes at once - real behaviour
  change, drift, a data-quality problem, a threshold edit, or the detector degrading. The history says
  something moved; it does not say which, and that is still worth having.

  Dot-source:  . (Join-Path $repoRoot 'lib\ratchet.ps1')
  Self-test:   powershell -File lib\ratchet.ps1 -SelfTest

  THIS FILE DECLARES NO param() BLOCK, DELIBERATELY - the trap guard-contract.ps1 documents. In PS 5.1
  dot-sourcing runs a param() block in the CALLER's scope, so a param([switch]$SelfTest) here would
  reset every caller's own -SelfTest to $false on the line after it bound.
#>
$__ratchetSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Test-RatchetMove {
  <# What this run's count means against the stored baseline.

     Returns @{ Verdict; Message; NewBaseline }. Verdict is one of:
       rose        - a NEW finding; the caller hard-fails
       held        - unchanged; pass
       tightened   - a believable fall; the caller lowers the baseline
       implausible - a fall too large or too complete to believe; the caller KEEPS the old baseline
                     and reports, because overwriting it is the irreversible half #>
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][int]$Count,
    [Parameter(Mandatory=$true)][int]$Baseline,
    [double]$MaxDropPct = 60.0,
    [switch]$AcceptDrop
  )
  if ($Count -gt $Baseline) {
    return [pscustomobject]@{ Verdict = 'rose'; NewBaseline = $Baseline
      Message = ("{0}: {1} finding(s), ABOVE the baseline of {2}. This is a NEW one." -f $Name, $Count, $Baseline) }
  }
  if ($Count -eq $Baseline) {
    return [pscustomobject]@{ Verdict = 'held'; NewBaseline = $Baseline
      Message = ("{0}: {1} known finding(s), unchanged from the baseline." -f $Name, $Count) }
  }

  # From here the count FELL, which is the direction that cannot be trusted on its own.
  if (-not $AcceptDrop) {
    if ($Baseline -gt 0 -and $Count -eq 0) {
      return [pscustomobject]@{ Verdict = 'implausible'; NewBaseline = $Baseline
        Message = ("{0}: found NOTHING where the baseline is {1}. A detector that suddenly finds nothing is broken until proven otherwise, so the baseline is KEPT rather than rewritten to 0 - lowering it would lock the blindness in permanently and print a pass forever. Check the detector actually ran and still matches, then re-run with -AcceptDrop if the migration is real." -f $Name, $Baseline) }
    }
    if ($Baseline -gt 0) {
      $dropPct = 100.0 * ($Baseline - $Count) / $Baseline
      if ($dropPct -gt $MaxDropPct) {
        return [pscustomobject]@{ Verdict = 'implausible'; NewBaseline = $Baseline
          Message = ("{0}: {1} finding(s) against a baseline of {2}, a {3}% fall in one run, over the {4}% that reads as a real migration rather than a detector that stopped seeing things. Baseline KEPT. Re-run with -AcceptDrop if the fall is genuine." -f $Name, $Count, $Baseline, [math]::Round($dropPct, 1), $MaxDropPct) }
      }
    }
  }
  return [pscustomobject]@{ Verdict = 'tightened'; NewBaseline = $Count
    Message = ("{0}: {1} finding(s), down from {2}. Baseline lowered; it can never rise again." -f $Name, $Count, $Baseline) }
}

function Add-RatchetHistory {
  <# Append this run's count to the baseline document's history, newest last, capped.

     THE COUNT IS RECORDED ON EVERY RUN, not only when the baseline moves - the point is the RATE. A
     history that only grows when the number changes cannot show that a detector has been quietly
     returning the same figure for six weeks because it stopped looking.

     Guarded and swallowing its own failure, for the same reason run-log-lib states: a run with no
     history is degraded, and a run KILLED BY its history is lost. #>
  param(
    [Parameter(Mandatory=$true)]$Doc,
    [Parameter(Mandatory=$true)][int]$Count,
    [int]$Keep = 120
  )
  try {
    $hist = @()
    if ($Doc.PSObject.Properties['history'] -and $Doc.history) { $hist = @($Doc.history) }
    $hist += [pscustomobject]@{ date = (Get-Date).ToString('s'); count = $Count }
    if ($hist.Count -gt $Keep) { $hist = @($hist[($hist.Count - $Keep)..($hist.Count - 1)]) }
    # THE COMMA IS LOAD-BEARING. PS 5.1 unrolls a one-element array on return, and the caller then
    # reads .Count off the single object - where it resolves to that object's own `count` PROPERTY
    # rather than a length. This file's own self-test reported 17 where it expected 1.
    return ,$hist
  } catch {
    return ,@()
  }
}

function Get-RatchetTrend {
  <# A one-line read of the history: is this detector still finding what it used to?

     Deliberately reports "not enough history" rather than inventing a trend from two points. #>
  param([Parameter(Mandatory=$true)]$History, [int]$Window = 10)
  $h = @($History)
  if ($h.Count -lt 3) { return 'trend: not enough history yet' }
  $recent = @($h[[math]::Max(0, $h.Count - $Window)..($h.Count - 1)])
  $counts = @($recent | ForEach-Object { [int]$_.count })
  $lo = ($counts | Measure-Object -Minimum).Minimum
  $hi = ($counts | Measure-Object -Maximum).Maximum
  if ($lo -eq $hi) { return ("trend: flat at {0} across the last {1} run(s)" -f $lo, $counts.Count) }
  return ("trend: {0} to {1} across the last {2} run(s)" -f $lo, $hi, $counts.Count)
}

if ($__ratchetSelfTest) {
  $fail = 0
  function T($n, $c, $g = '') { if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:fail++ } }

  $r = Test-RatchetMove -Name 'probe' -Count 18 -Baseline 17
  T 'a count above the baseline is a NEW finding' ($r.Verdict -eq 'rose' -and $r.NewBaseline -eq 17) $r.Verdict

  $r = Test-RatchetMove -Name 'probe' -Count 17 -Baseline 17
  T 'an unchanged count holds' ($r.Verdict -eq 'held') $r.Verdict

  $r = Test-RatchetMove -Name 'probe' -Count 15 -Baseline 17
  T 'CLEAN TWIN a believable fall tightens and lowers the baseline' ($r.Verdict -eq 'tightened' -and $r.NewBaseline -eq 15) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  # THE FOUNDING BUG. Before 2026-09-07 this recorded 0 and printed "PASSED and TIGHTENED".
  $r = Test-RatchetMove -Name 'probe' -Count 0 -Baseline 17
  T 'MUST FIRE  a fall to ZERO is refused and the baseline is KEPT' ($r.Verdict -eq 'implausible' -and $r.NewBaseline -eq 17) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)
  T 'the refusal says what to check rather than only that it refused' ($r.Message -like '*broken until proven otherwise*') $r.Message

  $r = Test-RatchetMove -Name 'probe' -Count 100 -Baseline 653
  T 'MUST FIRE  an 85% fall in one run is refused' ($r.Verdict -eq 'implausible' -and $r.NewBaseline -eq 653) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  # CLEAN TWIN for that: a fall just inside the bar is still a tightening, or the guard is a wall.
  $r = Test-RatchetMove -Name 'probe' -Count 45 -Baseline 100
  T 'CLEAN TWIN a 55% fall is inside the bar and still tightens' ($r.Verdict -eq 'tightened' -and $r.NewBaseline -eq 45) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  $r = Test-RatchetMove -Name 'probe' -Count 0 -Baseline 17 -AcceptDrop
  T '-AcceptDrop records a genuine bulk migration' ($r.Verdict -eq 'tightened' -and $r.NewBaseline -eq 0) ("{0}/{1}" -f $r.Verdict, $r.NewBaseline)

  # A ratchet legitimately AT zero must keep passing, or the guard punishes the success it wanted.
  $r = Test-RatchetMove -Name 'probe' -Count 0 -Baseline 0
  T 'CLEAN TWIN a ratchet already at zero holds rather than being refused' ($r.Verdict -eq 'held') $r.Verdict
  $r = Test-RatchetMove -Name 'probe' -Count 1 -Baseline 0
  T 'MUST FIRE  a finding appearing on a clean ratchet is a rise' ($r.Verdict -eq 'rose') $r.Verdict

  $doc = [pscustomobject]@{ sites = 17 }
  # ASSIGNED, NOT WRAPPED. Add-RatchetHistory returns ,$hist so the array survives the unroll; putting
  # @() around that makes a one-element array whose single element IS the array, which is the same
  # collapse from the other side. Both mistakes were made here before this comment existed.
  $h = Add-RatchetHistory -Doc $doc -Count 17
  T 'history starts from a document that has none' ($h.Count -eq 1 -and [int]$h[0].count -eq 17) $h.Count
  T 'MUST FIRE  a one-entry history reports length 1, not the entry it contains' ([int]$h.Count -eq 1) $h.Count
  $doc2 = [pscustomobject]@{ sites = 16; history = $h }
  $h2 = Add-RatchetHistory -Doc $doc2 -Count 16
  T 'history appends rather than replacing' ($h2.Count -eq 2 -and [int]$h2[-1].count -eq 16) $h2.Count

  $many = @()
  for ($i = 0; $i -lt 130; $i++) { $many += [pscustomobject]@{ date = 'x'; count = $i } }
  $capped = Add-RatchetHistory -Doc ([pscustomobject]@{ history = $many }) -Count 999 -Keep 120
  T 'history is capped and keeps the NEWEST entries' ($capped.Count -eq 120 -and [int]$capped[-1].count -eq 999) ("{0}/{1}" -f $capped.Count, $capped[-1].count)

  T 'a trend refuses to be read from two points' ((Get-RatchetTrend -History @(1, 2)) -like '*not enough*')
  $flat = @(); for ($i = 0; $i -lt 5; $i++) { $flat += [pscustomobject]@{ count = 7 } }
  T 'MUST FIRE  a flat detector reads as flat, which is the I15 signal' ((Get-RatchetTrend -History $flat) -like '*flat at 7*') (Get-RatchetTrend -History $flat)

  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail); exit 1 }
  Write-Output 'SELF-TEST PASS: the rise, the hold, a believable fall, and the two refusals - a fall to nothing and a fall too large - plus history and its cap'
  exit 0
}
