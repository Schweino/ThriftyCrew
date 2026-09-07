<#
  triage-lib.ps1 - what a closed alert MEANT, so a detector's live precision becomes knowable.

  WHY THIS EXISTS (2026-09-07, backlog E22's open half). Precision is not a property of a detector; it
  is a property of a detector AND the rate at which the thing it detects actually occurs. A rule with
  80% recall and a 13% false-alarm rate, run where the target is present in 3% of rows, is right 18%
  of the time it fires - with nothing mis-scored and no rows dropped.

  Every `-SelfTest` in this estate drives a must-fire fixture and its twin: a 50% base rate BY
  CONSTRUCTION, which measures recall honestly and overstates precision enormously. E22's first half
  fixed the convention - `Write-GuardComplete` now carries a denominator. Its second half needed
  somewhere to record which of a detector's LIVE firings turned out to be true, and had no home.

  THIS IS THAT HOME, AND IT IS NOT A NEW LEDGER NOBODY FILLS IN. `grocery/triage-queue.json` already
  holds every alert this estate has raised since the 2026-08-22 reset, and triage already closes items
  with `status=resolved` and free-text notes. 124 of the 126 are closed that way. What the notes cannot
  do is be counted: "RESOLVED on re-measurement, the signal no longer holds" and "Rolling condition by
  design" are opposite outcomes in identical prose. One CLOSED-VOCABULARY field beside the notes turns
  the queue that already exists into the precision record that does not.

  THE VOCABULARY, and every word of it is a decision:

    confirmed    the alert was RIGHT. A real defect was found and fixed, or found and filed.
    false-alarm  the alert was WRONG. The condition it named was not there, or was legal.
                 THIS IS THE ONE THAT MATTERS - a detector nobody ever marks false-alarm has an
                 unmeasured precision, not a good one.
    superseded   real when raised, already fixed by something else before triage reached it. Neither
                 a hit nor a miss, and folding it into either is how a rate lies.
    by-design    the condition is real, recurring, and EXPECTED - a rolling worklist, an ad window
                 between cycles. The detector is working and the alert is noise, which is a different
                 problem from a false alarm and wants a different fix (usually a quieter threshold).
    wont-fix     real, understood, and deliberately not being fixed. Counts as a hit: the detector
                 was right.

  NO param() BLOCK HERE, DELIBERATELY. In PS 5.1 dot-sourcing runs a param() block in the CALLER's
  scope, so a param([switch]$SelfTest) in a library steals the caller's own switches. Same trap
  lib\ratchet.ps1 and lib\guard-contract.ps1 both document.

  Dot-source:  . (Join-Path $root 'triage-lib.ps1')
  Self-test:   powershell -File grocery\triage-close.ps1 -SelfTest   (this file's fixtures live there)
#>

# A hit is an alert that was RIGHT. wont-fix is a hit - the detector found a real thing and a human
# decided not to act. by-design is NOT: the condition is real but the alert should not have been sent,
# and counting it as a hit would reward a detector for crying wolf accurately.
$script:TC_DISPOSITIONS = @('confirmed', 'false-alarm', 'superseded', 'by-design', 'wont-fix')
$script:TC_HIT          = @('confirmed', 'wont-fix')
$script:TC_MISS         = @('false-alarm')
$script:TC_NEITHER      = @('superseded', 'by-design')

# ITEMS CLOSED BEFORE THIS DATE ARE NOT REQUIRED TO CARRY ONE. The 124 already-resolved items were
# closed before the field existed, and back-filling them would mean guessing a disposition from prose -
# which is exactly the judgement this file exists to stop being guessed. A gate that went red on day
# one for that backlog would teach everyone to ignore it (the standing rule in ops-and-gates.md).
$script:TC_DISPOSITION_FROM = '2026-09-07'

function Get-TcDispositions {
  <# The vocabulary, as data, so a caller can print it in an error rather than restating it. #>
  return ,@($script:TC_DISPOSITIONS)
}

function Get-TcDispositionCutoff {
  <# The date from which a close owes a disposition. READ, never restated by a caller: a second copy
     of this date is a gate and a message disagreeing about which closes are exempt. #>
  return $script:TC_DISPOSITION_FROM
}

function Test-TcDisposition {
  <# '' when the disposition is legal, else why it is not. #>
  param([string]$Disposition)
  if (-not $Disposition) { return 'no disposition given' }
  if (@($script:TC_DISPOSITIONS) -contains $Disposition) { return '' }
  return ("'" + $Disposition + "' is not one of: " + ($script:TC_DISPOSITIONS -join ', '))
}

function Close-TcQueueItem {
  <# Closes one item IN PLACE and returns '' or why it refused. Pure apart from the mutation, so the
     fixtures drive it with a synthetic item set instead of the live queue.

     AMENDING A CLOSED ITEM IS LEGAL. The live queue already carries "AMENDED 2026-08-30 (round 2)",
     where a round-1 bounce was reconsidered - refusing that would push the correction back into prose,
     which is where the countable answer goes to die. The first resolved_ts is kept.
  #>
  param(
    [Parameter(Mandatory=$true)]$Items,
    [Parameter(Mandatory=$true)][string]$Id,
    [Parameter(Mandatory=$true)][string]$Disposition,
    [Parameter(Mandatory=$true)][string]$Notes,
    [string]$Now = ''
  )
  $why = Test-TcDisposition $Disposition
  if ($why) { return $why }
  # NOTES ARE REQUIRED AND MUST SAY SOMETHING. A disposition with no evidence is a vote, not a finding,
  # and "ok" closing an alert is how a queue becomes a rubber stamp.
  if (([string]$Notes).Trim().Length -lt 20) {
    return 'notes are required and must say what was actually established (20 characters or more)'
  }
  $hit = @($Items | Where-Object { [string]$_.id -eq $Id })
  if (-not $hit.Count) { return ("no queue item with id '" + $Id + "'") }
  if ($hit.Count -gt 1) { return ("id '" + $Id + "' matches " + $hit.Count + " items, which the queue should never allow") }
  $it = $hit[0]
  if (-not $Now) { $Now = (Get-Date).ToString('s') }

  foreach ($pair in @(@{ n = 'disposition'; v = $Disposition }, @{ n = 'notes'; v = $Notes },
                      @{ n = 'status'; v = 'resolved' })) {
    if ($it.PSObject.Properties[$pair.n]) { $it.($pair.n) = $pair.v }
    else { $it | Add-Member -NotePropertyName $pair.n -NotePropertyValue $pair.v }
  }
  # KEEP THE FIRST CLOSE TIME. An amendment is a correction to a verdict, not a new incident, and
  # re-stamping it would make the queue's own history unreadable.
  if (-not $it.PSObject.Properties['resolved_ts'] ) { $it | Add-Member -NotePropertyName resolved_ts -NotePropertyValue $Now }
  elseif (-not [string]$it.resolved_ts) { $it.resolved_ts = $Now }
  return ''
}

function Get-TcPrecision {
  <# Per-type live precision, WITH ITS DENOMINATOR, from the closed items.

     REPORTS A RATE ONLY WHEN THERE ARE ENOUGH CASES TO HAVE ONE (backlog E21). Three closed alerts
     do not make a 33% precision; they make "not enough closed cases to say". A number that reads as
     a measurement and is one coin flush is worse than no number, because it gets quoted.

     `superseded` and `by-design` are counted and EXCLUDED from the rate rather than dropped: a
     detector that is right about a condition nobody wants alerted on has a different problem from one
     that is wrong, and folding them together hides both. #>
  param([Parameter(Mandatory=$true)]$Items, [int]$MinCases = 5)
  $out = @()
  foreach ($g in ($Items | Where-Object { $_.PSObject.Properties['disposition'] -and $_.disposition } |
                  Group-Object -Property type)) {
    $rows    = @($g.Group)
    $hits    = @($rows | Where-Object { @($script:TC_HIT) -contains [string]$_.disposition }).Count
    $misses  = @($rows | Where-Object { @($script:TC_MISS) -contains [string]$_.disposition }).Count
    $neither = @($rows | Where-Object { @($script:TC_NEITHER) -contains [string]$_.disposition }).Count
    $judged  = $hits + $misses
    $rate = $null
    if ($judged -ge $MinCases) { $rate = [math]::Round(100.0 * $hits / $judged, 1) }
    $out += [pscustomobject]@{
      Type = $g.Name; Hits = $hits; Misses = $misses; Neither = $neither; Judged = $judged
      Rate = $rate
      Line = $(if ($null -eq $rate) {
                 ("{0}: {1} judged close(s) - too few to state a precision (need {2}). hits={3} false-alarms={4} neither={5}" -f $g.Name, $judged, $MinCases, $hits, $misses, $neither)
               } else {
                 ("{0}: {1}% precision over {2} judged close(s) - hits={3} false-alarms={4}, plus {5} neither" -f $g.Name, $rate, $judged, $hits, $misses, $neither)
               })
    }
  }
  return ,@($out | Sort-Object -Property @{ E = 'Judged'; Descending = $true }, Type)
}

function Get-TcUndispositioned {
  <# Items resolved on or after the cutoff that carry no disposition. `,@()` so one finding does not
     unroll to a bare object - assign before wrapping. [[ps-json-array-collapse]] #>
  param([Parameter(Mandatory=$true)]$Items, [string]$From = '')
  if (-not $From) { $From = $script:TC_DISPOSITION_FROM }
  $bad = @()
  foreach ($i in @($Items)) {
    if ([string]$i.status -ne 'resolved') { continue }
    $ts = [string]$i.resolved_ts
    if (-not $ts) { continue }                      # closed before close times were stamped
    if ($ts.Substring(0, [math]::Min(10, $ts.Length)) -lt $From) { continue }
    if ($i.PSObject.Properties['disposition'] -and [string]$i.disposition) { continue }
    $bad += $i
  }
  return ,@($bad)
}
