<#
  audit-capture-ingest-reporting.ps1 - a row dropped at ingest must be REPORTED by whoever read it.

  WHY THIS EXISTS (2026-09-06, backlog E5). E5's rule is validate at source, with low confidence routed
  to REVIEW rather than rejection. Two of the three places it names already did that and the third did
  the hard half and dropped the easy one:

    grocery\ingredient-queue.ps1   already correct - an ingredient nobody has proven is PENDING, not
                                   rejected, and the file says that distinction is the whole point
    graph\lib\llm.py               already correct - should_escalate() treats an UNKNOWN confidence as
                                   escalate, so a could-not-judge goes to review rather than through
    grocery\capture-lib.ps1        validated at source correctly, recorded the evidence faithfully,
                                   AND NOBODY READ IT

  Import-CaptureCsv drops vendor TEST listings at the moment the capture is read - the right place - and
  set $script:CapturePlaceholderCount so the caller could report it. Measured across all four callers:
  three reported the mojibake repair count, ZERO reported the placeholder count, and one reported
  neither. So every placeholder dropped at ingest was invisible, and a feed that began returning 80%
  placeholders would have produced a small, confident board and a success line.

  That is this estate's own recorded scar in a new place: the dedup machinery also recorded its
  failures faithfully for twelve days while nothing read them, and a could-not-look that nobody reads
  is a clean bill.

  THE RULE: any script that calls Import-CaptureCsv must report BOTH counts and the review warning.
  Static, hermetic, source-only - it works on a bare checkout with no captures present.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-capture-ingest-reporting.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$READER = 'Import-CaptureCsv'
$MUST_REPORT = @('CapturePlaceholderCount', 'CaptureIngestWarning')

function Get-TcIngestReportingProblems {
  <# Pure. $Files is a list of @{ Name; Lines }. A file that CALLS the reader owes both reports; a file
     that does not call it owes nothing, and the library itself is exempt - it SETS the variables and
     must never print (a function that returns data emitting anything else put a progress line into the
     returned array once already). #>
  param([object[]]$Files, [string]$Reader, [string[]]$MustReport)
  $out = @()
  foreach ($f in @($Files)) {
    if ($f.Name -eq 'capture-lib.ps1') { continue }
    $code = @($f.Lines | Where-Object { $_ -notmatch '^\s*#' })
    $calls = $false
    foreach ($l in $code) { if ($l -match [regex]::Escape($Reader)) { $calls = $true; break } }
    if (-not $calls) { continue }
    foreach ($v in @($MustReport)) {
      $reports = $false
      foreach ($l in $code) { if ($l -match [regex]::Escape($v)) { $reports = $true; break } }
      if (-not $reports) {
        $out += [pscustomobject]@{ File = $f.Name; Missing = $v }
      }
    }
  }
  return ,@($out)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  $R = 'Import-CaptureCsv'; $M = @('CapturePlaceholderCount', 'CaptureIngestWarning')

  # MUST FIRE - the founding defect, verbatim: reads captures, reports the repair count, never the drop.
  $r1 = Get-TcIngestReportingProblems -Reader $R -MustReport $M -Files @(
    @{ Name = 'build-x.ps1'; Lines = @('$rows = Import-CaptureCsv $p', 'Write-Output $script:CaptureRepairCount') })
  T 'MUST FIRE  a caller that reports the repair count but NOT the drop count is a finding' `
    (@($r1).Count -eq 2) (($r1 | ForEach-Object { $_.Missing }) -join ',')

  $r2 = Get-TcIngestReportingProblems -Reader $R -MustReport $M -Files @(
    @{ Name = 'build-x.ps1'; Lines = @('$rows = Import-CaptureCsv $p',
                                       'Write-Output $script:CapturePlaceholderCount',
                                       'Write-Output $script:CaptureIngestWarning') })
  T 'CLEAN TWIN a caller that reports both raises nothing' (@($r2).Count -eq 0) (($r2 | ForEach-Object { $_.Missing }) -join ',')

  # CLEAN TWIN - a file that never reads captures owes nothing. Without this the gate would demand the
  # reporting from every script in the tree.
  $r3 = Get-TcIngestReportingProblems -Reader $R -MustReport $M -Files @(
    @{ Name = 'unrelated.ps1'; Lines = @('Write-Output "hello"') })
  T 'CLEAN TWIN a script that never reads captures owes no report' (@($r3).Count -eq 0) (($r3 | ForEach-Object { $_.File }) -join ',')

  # CLEAN TWIN - the library is exempt. It SETS the variables and must never print: a function that
  # returns data emitting anything else already put a progress line into the returned array once.
  $r4 = Get-TcIngestReportingProblems -Reader $R -MustReport $M -Files @(
    @{ Name = 'capture-lib.ps1'; Lines = @('function Import-CaptureCsv {', '$script:CapturePlaceholderCount = 0') })
  T 'CLEAN TWIN the library that DEFINES the reader is exempt - it must never print' `
    (@($r4).Count -eq 0) (($r4 | ForEach-Object { $_.File }) -join ',')

  # CLEAN TWIN - a comment mentioning the reader is not a call.
  $r5 = Get-TcIngestReportingProblems -Reader $R -MustReport $M -Files @(
    @{ Name = 'doc.ps1'; Lines = @('# the old code used Import-CaptureCsv before the lib existed') })
  T 'CLEAN TWIN prose naming the reader is not a call to it' (@($r5).Count -eq 0) (($r5 | ForEach-Object { $_.File }) -join ',')

  T 'MUST FIRE  a single problem comes back as an ARRAY, not unrolled' ($r1 -is [array]) ($r1.GetType().FullName)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: the founding under-reporting case, plus four clean twins (both reported, no call, the library itself, and prose)'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
$files = @(Get-ChildItem (Join-Path $repo 'grocery') -Filter *.ps1 -File -Recurse -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\archive\\|\\out\\' } |
  ForEach-Object { @{ Name = $_.Name; Lines = [IO.File]::ReadAllLines($_.FullName) } })
if (-not $files.Count) {
  Write-Output 'CAPTURE-INGEST-REPORTING AUDIT BLIND: found zero grocery scripts, which means the discovery is broken rather than the tree being clean.'
  Write-GuardComplete -Name 'capture-ingest-reporting' -Summary 'blind=no-files'
  exit 3
}
$problems = Get-TcIngestReportingProblems -Files $files -Reader $READER -MustReport $MUST_REPORT
$problems = @($problems)
$callers = @($files | Where-Object { $_.Name -ne 'capture-lib.ps1' -and (@($_.Lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match [regex]::Escape($READER) }).Count) }).Count

if ($problems.Count) {
  Write-Output ("CAPTURE-INGEST-REPORTING AUDIT FAILED: {0} caller(s) of {1} drop rows at ingest without reporting it. A drop that nobody reads is a clean bill - a feed returning mostly placeholders would produce a small, confident board and a success line." -f $problems.Count, $READER)
  foreach ($p in $problems) { Write-Output ("  {0,-34} never reports {1}" -f $p.File, $p.Missing) }
  Write-GuardComplete -Name 'capture-ingest-reporting' -Summary ("problems={0}" -f $problems.Count)
  exit 2
}
Write-Output ("capture-ingest-reporting: PASSED - all {0} caller(s) of {1} report both the placeholder drop count and the review warning." -f $callers, $READER)
Write-GuardComplete -Name 'capture-ingest-reporting' -Summary ("callers={0}" -f $callers)
exit 0
