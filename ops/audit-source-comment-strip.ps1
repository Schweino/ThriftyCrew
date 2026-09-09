<#
  audit-source-comment-strip.ps1 - a check that reads SOURCE must not be able to read PROSE as code.

  WHY THIS EXISTS (2026-09-07). ops\run-gates.ps1 decides which scripts have a -SelfTest by matching
  the declaration against the file's text. On 2026-09-01 it learned to strip comments first, after a
  comment DISCUSSING the switch enrolled run-gates in its own discovery and spawned 18 copies of
  itself over 39 minutes. That fix stripped LINE comments only:

      ($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

  A block header is not a line comment. Measured the day this shipped: EIGHT shared libraries were
  enrolled as self-tests by their own headers - every one of them a header explaining why a library
  must NOT declare that switch, because a dot-sourced param block runs in the caller's scope. None of
  the eight accepts the switch. run-gates ran all eight with -SelfTest, the flag fell into $args
  (they have no param block at all), each exited 0 doing nothing, and the gate counted eight passing
  self-tests that do not exist. Discovery went 209 -> 201 when the block strip was added, and no file
  was added, which is what says the eight were phantom rather than lost.

  THE CLASS, and why it has two failure directions that look identical from outside:
    * TOO LITTLE stripping enrols prose as code. A check fires on its own documentation, or - worse,
      as here - counts a file it should never have run and reports the result as green.
    * TOO MUCH stripping deletes code. A `#` inside a quoted string is not a comment, and cutting to
      end-of-line there takes the rest of the statement with it and unbalances every brace count
      after it. audit-write-only-reports carries a fixture for that exact shape.
  Both produce a quiet pass, which is why the reduction belongs in one fixtured place -
  lib\ps-source.ps1 - rather than in each caller.

  WHAT IT CHECKS. Any .ps1 under ops\, grocery\, lib\ or meal-prep\ that reduces PowerShell source by
  dropping whole-line comments, and then MATCHES a declaration or call against the result, must also
  remove block comments - either by calling Get-PsCodeOnly or by stripping them itself.

  A RATCHET. The known call sites are recorded as a high-water mark that may only go DOWN, so an
  existing one can be worked off but a NEW scanner cannot appear with the gap.

  Usage:
    .\audit-source-comment-strip.ps1            scan and ratchet
    .\audit-source-comment-strip.ps1 -Accept    record the CURRENT count as the new high-water mark
    .\audit-source-comment-strip.ps1 -SelfTest  frozen fixtures

  Exit: 0 = at or under the baseline. 2 = a NEW line-comment-only scanner. 3 = could not evaluate.
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Accept, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\ps-source.ps1')

# NEEDLES BY CONCATENATION. This file scans source for a comment-stripping idiom, so spelling the
# idiom out as a literal would make this file match itself - and a detector that finds itself cannot
# fail ([[selftest-greps-its-own-source]]). run-gates and audit-write-seam both carry the same rule.
$script:SCS_LINE_STRIP = '(?i)-notmatch\s+[''"]\^' + '\\s\*#'
$script:SCS_BLOCK_STRIP = '(?i)<' + '#\.\*\?#' + '>|Get-PsCodeOnly|Get-PsCodeLines'

function Test-StripsLineCommentsOnly {
  <# Pure over one file's text. True when the file reduces source by dropping whole-line comments and
     never removes block comments - so a block header reaches whatever it matches next. #>
  param([string]$Text)
  if ($null -eq $Text) { return $false }
  if ($Text -notmatch $script:SCS_LINE_STRIP) { return $false }
  if ($Text -match $script:SCS_BLOCK_STRIP) { return $false }
  return $true
}

if ($SelfTest) {
  $script:bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  # THE FOUNDING LINE, as a single-quoted literal with doubled inner quotes. Built with + it would be
  # three positional arguments and the case would run on a fragment ([[ps-concat-in-argument-is-three-args]]).
  $founding = '$code = ($t -split "`r?`n" | Where-Object { $_ -notmatch ''^\s*#'' }) -join "`n"'
  T 'MUST FIRE  run-gates'' own reduction line, line comments only (it enrolled 8 libraries as self-tests)' `
    (Test-StripsLineCommentsOnly $founding) 'not reported'
  $viaLib = '$code = Get-PsCodeOnly -Text $t'
  T 'MUST NOT FIRE  a caller routed through the shared reduction is silent' `
    (-not (Test-StripsLineCommentsOnly $viaLib)) 'reported'
  $ownBlock = '$s = [regex]::Replace($t, ''(?s)<#.*?#>'', '''')' + "`n" + '$c = @($s -split "`n" | Where-Object { $_ -notmatch ''^\s*#'' })'
  T 'MUST NOT FIRE  a file that strips block comments ITSELF before the line strip is correct' `
    (-not (Test-StripsLineCommentsOnly $ownBlock)) 'reported'
  $noStrip = '$rows = @($lines | Where-Object { $_ -match ''price'' })'
  T 'MUST NOT FIRE  a file that never reduces source is not in this class at all' `
    (-not (Test-StripsLineCommentsOnly $noStrip)) 'reported'
  # CLEAN TWIN: THIS FILE. It names the idiom in its own header and builds its needles by
  # concatenation precisely so it cannot match itself. If that ever stops being true the detector
  # reports itself, someone adds an exclusion, and the exclusion is the next blind spot.
  $selfSrc = ''
  try { $selfSrc = [IO.File]::ReadAllText($PSCommandPath) } catch { }
  T 'CLEAN TWIN  the detector does not match its OWN source (needles are built, never written out)' `
    ($selfSrc -and (-not (Test-StripsLineCommentsOnly $selfSrc))) 'the detector found itself'
  # PS 5.1: @($null).Count is 1 ([[ps-null-count-is-one]]).
  T 'an empty finding set counts 0, not the PS 5.1 @($null) 1' ((@(@())).Count -eq 0) ([string](@(@())).Count)
  if ($bad -eq 0) { Write-Output 'SOURCE-COMMENT-STRIP SELF-TEST PASS'; Write-GuardComplete -Name 'source-comment-strip' -Summary 'selftest ok'; exit 0 }
  Write-Output ("SOURCE-COMMENT-STRIP SELF-TEST FAILED ($bad)"); Write-GuardComplete -Name 'source-comment-strip' -Summary "selftest failed=$bad"; exit 2
}

# ---- live scan ----
if (-not $Root) { $Root = $repo }
$skipDirs = @('\archive\', '\out\', '\.claude\', '\node_modules\', '\.git\', '\worktrees\',
              '\.venv\', '\venv\', '\site-packages\', '\dist-info\')
$scanned = 0
$findings = New-Object System.Collections.Generic.List[string]
foreach ($sub in @('ops', 'grocery', 'lib', 'meal-prep')) {
  $d = Join-Path $Root $sub
  if (-not (Test-Path $d)) { continue }
  foreach ($f in @(Get-ChildItem $d -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)) {
    $p = $f.FullName
    $skip = $false
    foreach ($sd in $skipDirs) { if ($p -like ('*' + $sd + '*')) { $skip = $true; break } }
    if ($skip) { continue }
    $scanned++
    $txt = ''
    try { $txt = [IO.File]::ReadAllText($p) } catch { continue }
    if (Test-StripsLineCommentsOnly $txt) { [void]$findings.Add($p.Replace($Root, '').TrimStart('\', '/')) }
  }
}
if ($scanned -eq 0) {
  Write-Output 'source-comment-strip: BLIND - zero .ps1 files reached the scan, so a clean result would prove nothing'
  Exit-Guard -Name 'source-comment-strip' -Summary 'blind=nothing-scanned' -Code 3
}
$n = @($findings).Count
Write-Output ("source-comment-strip: examined {0} .ps1 file(s); {1} reduce source by dropping LINE comments only, so a block header still reaches whatever they match" -f $scanned, $n)
foreach ($w in $findings) { Write-Output ('  LINE-ONLY  ' + $w) }

$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'out\source-comment-strip-baseline.json' }
$blDir = Split-Path $blF -Parent
if (-not (Test-Path $blDir)) { New-Item -ItemType Directory -Force $blDir | Out-Null }
$base = $null
if (Test-Path $blF) { try { $base = [int]((Get-Content $blF -Raw | ConvertFrom-Json).line_only) } catch { $base = $null } }
function Write-ScsBaseline([int]$Count) {
  @{ generated = (Get-Date).ToString('s'); line_only = $Count; examined = $scanned; names = @($findings)
     note = 'High-water mark for the comment-strip ratchet (2026-09-07, the 8 libraries run-gates enrolled from their own headers). This number may only go DOWN.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
}
if ($Accept -or $null -eq $base) {
  Write-ScsBaseline $n
  Write-Output ("  baseline written: $n of $scanned examined. From here the number may only go DOWN.")
  Exit-Guard -Name 'source-comment-strip' -Summary "line_only=$n examined=$scanned baseline=$n" -Code 0
}
$move = Test-RatchetMove -Name 'source-comment-strip' -Count $n -Baseline $base
if ($move.Verdict -eq 'rose') {
  Write-Output ("source-comment-strip: RATCHET BROKEN - $n of $scanned examined, baseline $base. A new source scanner reduces PowerShell by line comments only, so a block header can be matched as code.")
  Exit-Guard -Name 'source-comment-strip' -Summary "line_only=$n examined=$scanned baseline=$base" -Code 2
}
if ($move.Verdict -eq 'tightened') {
  Write-ScsBaseline $n
  Write-Output ("  ratchet tightened: $n, was $base. New baseline written.")
} elseif ($move.Verdict -eq 'implausible') {
  Write-Output ('  ' + $move.Message + ' - baseline kept at ' + $base)
}
Write-Output ("source-comment-strip: $n of $scanned examined, against a baseline of $base.")
Exit-Guard -Name 'source-comment-strip' -Summary "line_only=$n examined=$scanned baseline=$base" -Code 0
