<#
  count-source-lifters.ps1 - how many files read another script's SOURCE, and how many execute it.

  WHY THIS EXISTS. On 2026-09-08 the same quantity - "how many things lift
  compare-deals.ps1's functions" - was counted SIX times and returned six answers:

      .claude/rules/grocery.md, before          3   (stood for months)
      a course agent, morning                  17 read / 12 execute
      .claude/rules/grocery.md, after that     17 read / 14 execute
      the command that file itself quoted      53 name it / 13 execute
      a tighter Get-Content test               18 read / 12 execute (15 outside out\)
      a second course agent, afternoon         54 name it / 17 read / 12 execute

  NOT ONE of those disagreements was about the code. Every one was about the TEST, and
  no two writers used the same one. The estate's own rule in that file says "count it,
  never quote it" - and then quoted a number the command beside it does not produce.

  So the count moves out of prose entirely. Cite this script, not a digit.

  THE FOUR TESTS, because the answer depends entirely on which you mean:

    NAMES     the file's text contains the target's filename anywhere. Widest. Includes
              comments and doc strings, so it is an upper bound on coupling, not a
              measure of it.
    READS     a Get-Content whose target, within 200 characters, names the target file.
              This is "reads its source", the thing the architectural claim is about.
    EXECUTES  READS and also calls Invoke-Expression or iex. This is the real lifting.
    Each is reported with and without one-off scratch scripts under grocery\out\, which
    is where several of the historical disagreements came from.

  Exit 0 = counted. Exit 3 = could not evaluate (no such target, or nothing scanned).

  Params: -Script <filename>, -Root, -SelfTest
#>
[CmdletBinding()]
param(
  [string]$Script = 'compare-deals.ps1',
  [string]$Root = '',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Root) { $Root = Split-Path -Parent $here }

function Get-Lifters {
  param([string]$RootDir, [string]$Target)
  <# @{Names=[];Reads=[];Executes=[];Scanned=n} - the four tests, one pass. #>
  $files = @(Get-ChildItem -LiteralPath $RootDir -Filter *.ps1 -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object {
               $_.Extension -eq '.ps1' -and
               $_.FullName -notmatch '\\\.git\\' -and
               $_.FullName -notmatch '\\archive\\' -and
               $_.FullName -notmatch '\\node_modules\\' -and
               $_.FullName -notmatch '\\worktrees\\' })
  $names = New-Object System.Collections.ArrayList
  $reads = New-Object System.Collections.ArrayList
  $execs = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    # The target never counts as its own caller.
    if ($f.Name -eq $Target) { continue }
    try { $t = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { continue }
    $t = $t + ''
    if ($t.IndexOf($Target, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    $rel = $f.FullName.Substring($RootDir.Length + 1)
    [void]$names.Add($rel)
    # READS: a Get-Content whose target within 200 chars names the file.
    $isRead = $false
    foreach ($m in [regex]::Matches($t, 'Get-Content')) {
      $tail = $t.Substring($m.Index + $m.Length, [Math]::Min(200, $t.Length - $m.Index - $m.Length))
      if ($tail.IndexOf($Target, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isRead = $true; break }
    }
    if (-not $isRead) { continue }
    [void]$reads.Add($rel)
    if ($t -match 'Invoke-Expression|\biex\b') { [void]$execs.Add($rel) }
  }
  return @{ Names = $names; Reads = $reads; Executes = $execs; Scanned = $files.Count }
}

function Split-Scratch([System.Collections.ArrayList]$rows) {
  $out = @($rows | Where-Object { $_ -match '^grocery\\out\\' })
  $main = @($rows | Where-Object { $_ -notmatch '^grocery\\out\\' })
  return @{ Main = $main; Scratch = $out }
}

if ($SelfTest) {
  $tmp = Join-Path $env:TEMP ('csl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmp 'grocery\out') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmp 'archive') -Force | Out-Null
  $pass = 0; $fails = New-Object System.Collections.ArrayList
  function _C($label, $name, $ok, $detail) {
    if ($ok) { $script:pass++ } else { [void]$script:fails.Add("$label $name") }
    Write-Output ("  {0,-14} {1,-60} {2}" -f $label, $name, $(if ($ok) { 'ok' } else { "FAIL $detail" }))
  }
  function _W($rel, $body) {
    $p = Join-Path $tmp $rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
    [IO.File]::WriteAllText($p, $body, (New-Object Text.UTF8Encoding($false)))
  }

  # Fixtures are single-quoted literals with doubled inner quotes, never built by
  # concatenation: a concatenated fixture passes THREE positional arguments and the case
  # then runs against a truncated line, which has passed for the wrong reason here before.
  _W 'grocery\target.ps1'      'function Get-Thing { 1 }'
  _W 'grocery\lifter.ps1'      '$src = Get-Content "$PSScriptRoot\target.ps1" -Raw; Invoke-Expression $src'
  _W 'grocery\reader.ps1'      '$src = Get-Content "$PSScriptRoot\target.ps1" -Raw; $src.Length'
  _W 'grocery\mentioner.ps1'   '# see target.ps1 for the shared helper, we do not read it'
  _W 'grocery\out\scratch.ps1' '$s = Get-Content "..\target.ps1" -Raw; Invoke-Expression $s'
  _W 'grocery\faraway.ps1'     ('$x = Get-Content "other.txt"' + ("`n# filler" * 40) + "`n# target.ps1 mentioned far below")
  _W 'archive\old.ps1'         '$src = Get-Content "target.ps1" -Raw; Invoke-Expression $src'

  $r = Get-Lifters -RootDir $tmp -Target 'target.ps1'
  $sN = Split-Scratch $r.Names; $sR = Split-Scratch $r.Reads; $sE = Split-Scratch $r.Executes

  _C 'MUST FIRE' 'a Get-Content plus Invoke-Expression is counted as EXECUTES' ($r.Executes -contains 'grocery\lifter.ps1') ($r.Executes -join ',')
  _C 'MUST FIRE' 'a Get-Content with no Invoke-Expression is READS but not EXECUTES' (($r.Reads -contains 'grocery\reader.ps1') -and ($r.Executes -notcontains 'grocery\reader.ps1')) 'reader misclassified'
  _C 'MUST NOT FIRE' 'a bare MENTION in a comment is NAMES but never READS' (($r.Names -contains 'grocery\mentioner.ps1') -and ($r.Reads -notcontains 'grocery\mentioner.ps1')) 'a comment counted as reading source'
  _C 'MUST NOT FIRE' 'a Get-Content of something ELSE, with the name far below, is not READS' ($r.Reads -notcontains 'grocery\faraway.ps1') 'the 200-char window is not bounding anything'
  _C 'MUST NOT FIRE' 'the target is never its own caller' (($r.Names -notcontains 'grocery\target.ps1')) 'target counted itself'
  _C 'MUST NOT FIRE' 'archive is excluded' (($r.Names -notcontains 'archive\old.ps1')) 'archive was scanned'
  _C 'MUST FIRE' 'scratch under grocery\out is counted but reported SEPARATELY' (($sE.Scratch -contains 'grocery\out\scratch.ps1') -and ($sE.Main -notcontains 'grocery\out\scratch.ps1')) 'scratch not split out'
  # CLEAN TWIN: the three tests nest. Every EXECUTES is a READS is a NAMES - the property
  # that makes the four numbers comparable rather than three unrelated counts.
  $nested = $true
  foreach ($e in $r.Executes) { if ($r.Reads -notcontains $e) { $nested = $false } }
  foreach ($rd in $r.Reads) { if ($r.Names -notcontains $rd) { $nested = $false } }
  _C 'CLEAN TWIN' 'EXECUTES is a subset of READS is a subset of NAMES' $nested 'the tests do not nest'
  # Two assertions, two labels. They used to share one, and the shared label fitted neither.
  $z = Get-Lifters -RootDir $tmp -Target 'no-such-file-anywhere.ps1'
  # MUST NOT FIRE: a target nobody references is a legal input and the counter stays silent.
  _C 'MUST NOT FIRE' 'a target nobody references returns zero' (@($z.Names).Count -eq 0) (@($z.Names).Count)
  # CLEAN TWIN: and it still reports what it examined. This is the load-bearing half -
  # "0 found" and "0 scanned" are the same output from a working detector and a blind one,
  # so the scanned count is what makes the zero mean anything.
  _C 'CLEAN TWIN' 'and it still reports the population it examined, so 0 found is not 0 scanned' ($z.Scanned -gt 0) ("scanned=" + $z.Scanned)

  Remove-Item $tmp -Recurse -Force
  Write-Output ''
  $total = $pass + $fails.Count
  if ($fails.Count) {
    Write-Output ("SELF-TEST FAIL: {0} case(s) of {1}" -f $fails.Count, $total)
    foreach ($f in $fails) { Write-Output ("  " + $f) }
    Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
    exit 1
  }
  Write-Output ("count-source-lifters self-test: {0} of {0} cases pass" -f $total)
  Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
  exit 0
}

if (-not (Test-Path -LiteralPath $Root)) {
  Write-Output ("count-source-lifters: BLIND - no such root " + $Root)
  Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
  exit 3
}
$r = Get-Lifters -RootDir $Root -Target $Script
if ($r.Scanned -eq 0) {
  Write-Output ("count-source-lifters: BLIND - 0 .ps1 files under " + $Root + ". Nothing was examined; this proves nothing.")
  Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
  exit 3
}

$sN = Split-Scratch $r.Names
$sR = Split-Scratch $r.Reads
$sE = Split-Scratch $r.Executes

Write-Output ("count-source-lifters: target " + $Script + ", scanned " + $r.Scanned +
              " .ps1 file(s) under " + $Root + " (.git, archive, node_modules, worktrees excluded)")
Write-Output ''
Write-Output ("  NAMES     {0,3}  ({1} outside grocery\out, {2} scratch)  - filename appears anywhere, comments included. An upper bound on coupling, not a measure of it." -f @($r.Names).Count, @($sN.Main).Count, @($sN.Scratch).Count)
Write-Output ("  READS     {0,3}  ({1} outside grocery\out, {2} scratch)  - a Get-Content whose target within 200 chars names it. THIS is 'reads its source'." -f @($r.Reads).Count, @($sR.Main).Count, @($sR.Scratch).Count)
Write-Output ("  EXECUTES  {0,3}  ({1} outside grocery\out, {2} scratch)  - READS and also calls Invoke-Expression. This is the actual lifting." -f @($r.Executes).Count, @($sE.Main).Count, @($sE.Scratch).Count)
Write-Output ''
Write-Output "  EXECUTES, named:"
foreach ($x in ($r.Executes | Sort-Object)) { Write-Output ("    " + $x) }
Write-Output ''
Write-Output "  Quote this script and the test you mean, never a bare digit. Six writers counted"
Write-Output "  this quantity on 2026-09-08 and produced six answers; every disagreement was the"
Write-Output "  test and none was the code."
Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
exit 0
