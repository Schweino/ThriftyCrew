<#
  ingest-ledger.ps1 - a row dropped at ingest must leave a record and a reason.

  WHY THIS EXISTS (2026-09-06, backlog E5). The course's four-layer stack is format -> business rules
  -> semantic -> human review, and its load-bearing clause is the LAST one: low confidence is ROUTED
  TO REVIEW rather than rejected. This estate already had most of the layers. What it did not have,
  in every reader, was the record.

  MEASURED BEFORE BUILDING, because E9 and E4 both inverted their own premise the moment they were
  measured and E5's premise deserved the same treatment:

    capture-lib.ps1          placeholder drops COUNTED, and a shape change already routes to REVIEW
    import-walmart-batch.ps1 3P / test / quarantine / reject each go to a NAMED list with a reason,
                             and the rejects reach out\walmart-batch-rejects-<date>.json for a human
    ...but its PARSE loop      drops a line with no tab, a field group under 3 fields, and a row with
                             no name, all with NO count and NO record

  So the gap is narrower than the item describes and it is the worst-shaped one: the FORMAT layer,
  where a reducer that changed its output silently yields nothing and the importer says so in no way
  at all. A business-rule rejection is loud by construction because someone wrote the rule. A format
  drop is silent by construction because it happens before anyone's rule runs.

  WHAT THIS DOES NOT DO. It does not judge a row. It counts and it routes. A caller decides what is a
  drop; this decides whether the SHAPE of the drops is worth a human's attention, using the same
  argument capture-lib already uses: a few bad rows are normal noise and a sudden share of them is a
  changed upstream.

  Dot-source:  . (Join-Path $repoRoot 'lib\ingest-ledger.ps1')
  Self-test:   powershell -File lib\ingest-ledger.ps1 -SelfTest

  THIS FILE DECLARES NO param() BLOCK, DELIBERATELY - the same trap guard-contract.ps1 documents. In
  PS 5.1, dot-sourcing a script runs its param() block in the CALLER's scope, so a param([switch]
  $SelfTest) here would reset every caller's own -SelfTest to $false on the line after it bound.
#>
$__ilSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function New-IngestLedger {
  <# One ledger per ingest run. Returns the object every other function here takes. #>
  param([Parameter(Mandatory=$true)][string]$Stage)
  return [pscustomobject]@{
    Stage    = $Stage
    Read     = 0
    Kept     = 0
    Reasons  = @{}
    Examples = @{}
  }
}

function Add-IngestRead {
  <# Call once per row the reader LOOKED AT, before any decision. The denominator is the whole point:
     "12 dropped" is a clean run and a catastrophe depending on whether 4,000 rows were read or 13
     (backlog E20 and E22). #>
  param([Parameter(Mandatory=$true)]$Ledger, [int]$Count = 1)
  $Ledger.Read += $Count
}

function Add-IngestDrop {
  <# A row that will not reach the board, and WHY. The reason string is a short stable key, not a
     sentence - it is grouped on. Up to three examples per reason are kept, because a count tells you
     something changed and an example tells you what. #>
  param(
    [Parameter(Mandatory=$true)]$Ledger,
    [Parameter(Mandatory=$true)][string]$Reason,
    [string]$Example = ''
  )
  if (-not $Ledger.Reasons.ContainsKey($Reason)) {
    $Ledger.Reasons[$Reason] = 0
    $Ledger.Examples[$Reason] = New-Object System.Collections.ArrayList
  }
  $Ledger.Reasons[$Reason] = [int]$Ledger.Reasons[$Reason] + 1
  if ($Example -and $Ledger.Examples[$Reason].Count -lt 3) {
    [void]$Ledger.Examples[$Reason].Add([string]$Example)
  }
}

function Add-IngestKept {
  param([Parameter(Mandatory=$true)]$Ledger, [int]$Count = 1)
  $Ledger.Kept += $Count
}

function Get-IngestReview {
  <# The routing decision. Returns '' when nothing needs a human, or a REVIEW line when it does.

     TWO TRIGGERS, and the second is the one a percentage alone would miss:
       * a single reason accounts for more than -SharePct of everything read - a changed upstream
       * NOTHING WAS KEPT while rows were read - the total-failure case, where every percentage is
         either 0 or 100 and a share threshold set for normal noise will not fire on it

     The default share is deliberately loose. This is a REVIEW prompt, not a gate: it must fire on a
     shape change and stay quiet through ordinary noise, because a warning that cries daily is one
     nobody reads - the estate already learned that from a link-drift alert that fired on unfixable
     cells until it was switched off. #>
  param([Parameter(Mandatory=$true)]$Ledger, [double]$SharePct = 20.0)
  if ($Ledger.Read -le 0) { return '' }
  $dropped = 0
  foreach ($k in $Ledger.Reasons.Keys) { $dropped += [int]$Ledger.Reasons[$k] }

  if ($Ledger.Kept -le 0 -and $dropped -gt 0) {
    return ("REVIEW [{0}]: {1} row(s) read and NOT ONE was kept. Every row was dropped: {2}. This is a format or upstream failure, not selective filtering - do not build anything from what is left." -f
            $Ledger.Stage, $Ledger.Read, (Format-IngestReasons $Ledger))
  }
  $worst = ''
  $worstPct = 0.0
  foreach ($k in $Ledger.Reasons.Keys) {
    $pct = 100.0 * ([int]$Ledger.Reasons[$k]) / $Ledger.Read
    if ($pct -gt $worstPct) { $worstPct = $pct; $worst = $k }
  }
  if ($worstPct -gt $SharePct) {
    $ex = ''
    if ($Ledger.Examples.ContainsKey($worst) -and $Ledger.Examples[$worst].Count) {
      $ex = ' e.g. ' + (($Ledger.Examples[$worst]) -join ' | ')
    }
    return ("REVIEW [{0}]: '{1}' dropped {2} of {3} row(s) read ({4}%), over the {5}% share that reads as a shape change rather than noise. Check the pull before trusting what is left.{6}" -f
            $Ledger.Stage, $worst, [int]$Ledger.Reasons[$worst], $Ledger.Read, [math]::Round($worstPct, 1), $SharePct, $ex)
  }
  return ''
}

function Format-IngestReasons {
  param([Parameter(Mandatory=$true)]$Ledger)
  $parts = @()
  foreach ($k in ($Ledger.Reasons.Keys | Sort-Object)) { $parts += ("{0}={1}" -f $k, [int]$Ledger.Reasons[$k]) }
  if (-not $parts.Count) { return 'none' }
  return ($parts -join ', ')
}

function Write-IngestLedger {
  <# Persist it. Guarded and swallowing its own failure, for the same reason run-log-lib states: a run
     with no ledger is a degraded run, and a run KILLED BY its ledger is a lost one. These callers set
     $ErrorActionPreference = 'Stop'. #>
  param([Parameter(Mandatory=$true)]$Ledger, [Parameter(Mandatory=$true)][string]$Path)
  try {
    $dir = Split-Path $Path -Parent
    # -ErrorAction Stop so a bad path THROWS into the catch below instead of emitting a
    # non-terminating error that PowerShell prints in red on an otherwise passing run. A gate
    # that shows a red block when it passes is a gate people learn to skim.
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $ex = @{}
    foreach ($k in $Ledger.Examples.Keys) { $ex[$k] = @($Ledger.Examples[$k]) }
    $doc = [ordered]@{
      stage = $Ledger.Stage
      generated = (Get-Date).ToString('s')
      rows_read = $Ledger.Read
      rows_kept = $Ledger.Kept
      dropped_by_reason = $Ledger.Reasons
      examples = $ex
      review = (Get-IngestReview $Ledger)
      note = 'Rows READ is the denominator. A drop count without it cannot be read: 12 dropped is clean out of 4,000 and a catastrophe out of 13.'
    }
    ($doc | ConvertTo-Json -Depth 6) | Set-Content $Path -Encoding UTF8
    return $true
  } catch {
    return $false
  }
}

if ($__ilSelfTest) {
  $fail = 0
  function T($name, $cond, $got = '') {
    if ($cond) { Write-Output ("ok    " + $name) }
    else { Write-Output ("FAIL  " + $name + "   got: " + $got); $script:fail++ }
  }

  $l = New-IngestLedger -Stage 'probe'
  Add-IngestRead $l 100
  Add-IngestKept $l 98
  Add-IngestDrop $l 'no-name' 'row 7'
  Add-IngestDrop $l 'no-name' 'row 9'
  T 'a ledger counts reads, keeps and drops by reason' ($l.Read -eq 100 -and $l.Kept -eq 98 -and $l.Reasons['no-name'] -eq 2) ("{0}/{1}/{2}" -f $l.Read, $l.Kept, $l.Reasons['no-name'])
  T 'CLEAN TWIN 2% of rows dropped is noise and asks for no review' ((Get-IngestReview $l) -eq '') (Get-IngestReview $l)

  # MUST FIRE: the shape change. A reducer whose output format moved drops a large SHARE for one
  # reason, and that is the signal - not the raw count.
  $l2 = New-IngestLedger -Stage 'probe'
  Add-IngestRead $l2 100
  Add-IngestKept $l2 70
  for ($i = 0; $i -lt 30; $i++) { Add-IngestDrop $l2 'malformed-line' ("line " + $i) }
  $r2 = Get-IngestReview $l2
  T 'MUST FIRE  one reason taking 30% of rows read asks for review' ($r2 -like '*REVIEW*' -and $r2 -like '*malformed-line*') $r2
  T 'the review line carries examples, because a count says something changed and an example says what' ($r2 -like '*line 0*') $r2

  # MUST FIRE: the total failure. Every share is 0 or 100 here, so a threshold tuned for normal noise
  # is exactly the wrong instrument - this is why there are two triggers and not one.
  $l3 = New-IngestLedger -Stage 'probe'
  Add-IngestRead $l3 40
  for ($i = 0; $i -lt 40; $i++) { Add-IngestDrop $l3 'no-tab' 'x' }
  $r3 = Get-IngestReview $l3
  T 'MUST FIRE  rows read and NOTHING kept is a review even though no rule was violated' ($r3 -like '*NOT ONE was kept*') $r3

  # CLEAN TWIN for that: nothing read at all is not a failure, it is an empty run.
  $l4 = New-IngestLedger -Stage 'probe'
  T 'CLEAN TWIN a reader that read nothing reports nothing rather than a false alarm' ((Get-IngestReview $l4) -eq '') (Get-IngestReview $l4)

  # A ledger that cannot be written must not kill the run.
  $l5 = New-IngestLedger -Stage 'probe'
  Add-IngestRead $l5 1
  $okWrite = Write-IngestLedger $l5 'Z:\definitely\not\a\path\x.json'
  T 'MUST FIRE  an unwritable ledger returns false rather than throwing under EAP=Stop' ($okWrite -eq $false) $okWrite

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('il-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $l6 = New-IngestLedger -Stage 'walmart-batch'
    Add-IngestRead $l6 10; Add-IngestKept $l6 9; Add-IngestDrop $l6 'no-name' 'blank'
    T 'a ledger writes' ((Write-IngestLedger $l6 $tmp) -eq $true)
    $back = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
    T 'the written ledger keeps the DENOMINATOR, not just the drops' ($back.rows_read -eq 10 -and $back.rows_kept -eq 9) ("{0}/{1}" -f $back.rows_read, $back.rows_kept)
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }

  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail); exit 1 }
  Write-Output 'SELF-TEST PASS: counting with its denominator, the shape-change review, the everything-dropped case a share threshold cannot see, and a ledger that cannot kill its run'
  exit 0
}
