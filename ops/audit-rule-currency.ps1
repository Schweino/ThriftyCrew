<#
  audit-rule-currency.ps1 - a rules file that loads for nothing, and a dated claim nobody has re-read.

  WS 7e of design\PLAN-brain-v2-2026-09-09.md.

  TWO CHECKS, AND ONLY ONE OF THEM IS A VERDICT.

  1. GLOBS - HARD. Every `globs:` entry in a .claude\rules\*.md front matter must match at least one
     tracked file (git ls-files). A glob that matches nothing DISARMS its file: the rules load for no
     path, silently, and a session editing that area gets none of the traps written for it. That is the
     fail-open shape, and it is decided by source alone, so it belongs in run-gates. Exit 2.

  2. DATED CLAIMS - A REPORT, NOT THE PLANNED RATCHET. A line carrying a date older than $StaleDays is
     listed with the numbers it states, for a person to re-verify and re-date. The plan asked for a
     ratchet here and this deliberately is not one: the count RISES WITH THE CALENDAR while nothing in
     the tree changes, so in run-gates - which the pre-push hook runs - it would turn red on a morning
     nobody touched a rules file and block the ~07:00 bot's deploy push. A gate must be hermetic over
     source. The listing is carried by -Json to the brain report instead, where a person reads it.

  WHAT IS A CLAIM. A date written as a date in prose ("on the 2026-07-30 board", "(2026-09-08, backlog
  I72)"). A date inside a file name or path (`EVAL-hunter-wall-clock-2026-09-04.md`) is not a claim; the
  newest date on a line is the claim's date.

  SCOPE OF A CLEAN REPORT: UNSOUND. A claim written without a date is invisible here, and a re-dated
  line that nobody actually re-verified reads as fresh. The glob check is exact for what it checks: it
  says a glob matches tracked files, never that it matches the RIGHT ones.

  EXIT: 0 every glob matches (stale claims are content, not a verdict), 2 a glob matches nothing,
        3 could not evaluate (no rules directory, or no git).
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [int]$StaleDays = 90)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$script:DATE_RX = '(?<![\w-])(20\d{2}-[01]\d-[0-3]\d)(?![\w-]|\.(?:md|json|jsonl|txt|log|ps1|py))'

function Get-FrontMatterGlobs {
  <# The `globs:` entries of the front matter only - a globs: line in the body is prose. #>
  param([string]$Text)
  $lines = $Text -split "`r?`n"
  $out = New-Object System.Collections.Generic.List[string]
  if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') { $a = $out.ToArray(); return ,$a }
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '---') { break }
    $m = [regex]::Match($lines[$i], '^\s*globs:\s*(.*)$')
    if ($m.Success) {
      foreach ($g in ($m.Groups[1].Value.Trim().Trim('"', "'") -split ',')) {
        $t = $g.Trim().Trim('"', "'")
        if ($t) { [void]$out.Add($t) }
      }
    }
  }
  $a = $out.ToArray()
  return ,$a
}

function Get-DatedClaims {
  <# One object per line carrying a claim date: Line, Date, AgeDays, Stale, Numbers, Text. #>
  param([string]$Text, [datetime]$Today, [int]$StaleDays)
  $out = New-Object System.Collections.Generic.List[object]
  $lines = $Text -split "`r?`n"
  $start = 0
  if ($lines.Count -gt 1 -and $lines[0].Trim() -eq '---') {
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $start = $i + 1; break } }
  }
  for ($i = $start; $i -lt $lines.Count; $i++) {
    $ms = [regex]::Matches($lines[$i], $script:DATE_RX)
    if ($ms.Count -eq 0) { continue }
    $newest = $null
    foreach ($m in $ms) {
      try { $d = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
      if ($null -eq $newest -or $d -gt $newest) { $newest = $d }
    }
    if ($null -eq $newest) { continue }
    $noDates = [regex]::Replace($lines[$i], '20\d{2}-[01]\d-[0-3]\d', ' ')
    $nums = @([regex]::Matches($noDates, '(?<![\w.-])\d[\d,]*(?:\.\d+)?%?(?![\w-])') | ForEach-Object { $_.Value } | Select-Object -First 6)
    $age = [int]($Today.Date - $newest.Date).TotalDays
    [void]$out.Add([pscustomobject]@{ Line = $i + 1; Date = $newest.ToString('yyyy-MM-dd'); AgeDays = $age
                                      Stale = ($age -gt $StaleDays); Numbers = $nums
                                      Text = $lines[$i].Trim().Substring(0, [math]::Min(110, $lines[$i].Trim().Length)) })
  }
  $a = $out.ToArray()
  return ,$a
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-66} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  $today = [datetime]'2026-12-01'

  $fm = "---`ndescription: x`nglobs: `"sidecar/**, **/*eval*.py, **/audit-*.ps1`"`nalwaysApply: false`n---`n# body`n"
  $gR = Get-FrontMatterGlobs -Text $fm
  $g = @($gR)
  Case 'MUST FIRE' 'the front matter globs parse into their three entries' ($g.Count -eq 3 -and $g[1] -eq '**/*eval*.py') ($g -join '|')
  $cR = Get-DatedClaims -Text "---`nglobs: `"a/**`"`n---`nMeasured 2026-08-01: 41 of 492 commodities (8%)." -Today $today -StaleDays 90
  $c = @($cR)
  Case 'MUST FIRE' 'a claim dated more than 90 days ago is stale, with the numbers it states' ($c.Count -eq 1 -and $c[0].Stale -and ($c[0].Numbers -join ' ') -eq '41 492 8%') ("{0} {1}" -f $c.Count, ($c[0].Numbers -join ' '))
  $deadCount = { param($glob) 0 }
  Case 'MUST FIRE' 'a glob matching no tracked file is dead' ((& $deadCount 'nowhere/**') -eq 0)

  $cR2 = Get-DatedClaims -Text 'See design\EVAL-hunter-wall-clock-2026-09-04.md and comparison-2026-07-30.json for the table.' -Today $today -StaleDays 90
  $c2 = @($cR2)
  Case 'MUST NOT FIRE' 'a date inside a file name is not a claim' ($c2.Count -eq 0) "$($c2.Count)"
  $cR3 = Get-DatedClaims -Text '(2026-09-03, backlog I72) twelve cases' -Today $today -StaleDays 90
  $c3 = @($cR3)
  Case 'MUST NOT FIRE' 'a claim 89 days old is not stale' ($c3.Count -eq 1 -and -not $c3[0].Stale) ("{0} {1}" -f $c3.Count, $c3[0].AgeDays)
  $cR4 = Get-DatedClaims -Text "no dates here at all`nnor here, 42 of them" -Today $today -StaleDays 90
  $c4 = @($cR4)
  Case 'MUST NOT FIRE' 'a line with no date is no claim' ($c4.Count -eq 0) "$($c4.Count)"
  $gR5 = Get-FrontMatterGlobs -Text "# Title`nglobs: `"grocery/**`"`n"
  $g5 = @($gR5)
  Case 'MUST NOT FIRE' 'a globs line outside a front matter is not a glob' ($g5.Count -eq 0) ($g5 -join '|')
  $cR6 = Get-DatedClaims -Text "---`nupdated: 2026-01-01`n---`nbody" -Today $today -StaleDays 90
  $c6 = @($cR6)
  Case 'MUST NOT FIRE' 'a date in the front matter is not a claim' ($c6.Count -eq 0) "$($c6.Count)"

  $cR7 = Get-DatedClaims -Text 'could not reach that on the 2026-07-30 board' -Today $today -StaleDays 90
  $c7 = @($cR7)
  Case 'CLEAN TWIN' 'a date written in prose IS a claim, with its date' ($c7.Count -eq 1 -and $c7[0].Date -eq '2026-07-30') "$($c7.Count)"
  $cR8 = Get-DatedClaims -Text 'ruled 2026-09-01, re-measured 2026-11-20: 7 of 9' -Today $today -StaleDays 90
  $c8 = @($cR8)
  Case 'CLEAN TWIN' 'the newest date on a line is the claim date, and the numbers exclude the dates' ($c8[0].Date -eq '2026-11-20' -and ($c8[0].Numbers -join ' ') -eq '7 9') ("{0} {1}" -f $c8[0].Date, ($c8[0].Numbers -join ' '))
  $liveCount = { param($glob) 3 }
  Case 'CLEAN TWIN' 'a glob with matches reports its count' ((& $liveCount 'ops/**') -eq 3)
  $rules = @(Get-ChildItem (Join-Path $repo '.claude\rules') -File -Filter '*.md' -ErrorAction SilentlyContinue)
  Case 'CLEAN TWIN' 'the population is .claude\rules\*.md, and it is not empty' ($rules.Count -gt 0) "$($rules.Count)"

  Write-Output ''
  if ($fails.Count) {
    Write-Output ("audit-rule-currency selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'RULE-CURRENCY-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("audit-rule-currency selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'RULE-CURRENCY-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
$rulesDir = Join-Path $repo '.claude\rules'
$files = @(Get-ChildItem $rulesDir -File -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($files.Count -eq 0) {
  Write-Output 'RULE CURRENCY BLIND: no .claude\rules\*.md - nothing was judged, which is not every rule loading.'
  if ($Json) { 'rule-currency-json: {"known": false}' }
  Exit-Guard -Name 'RULE-CURRENCY' -Code 3 -Summary 'files=0 blind=1'
}
$null = & git -C $repo rev-parse --verify --quiet HEAD
if ($LASTEXITCODE -ne 0) {
  Write-Output 'RULE CURRENCY BLIND: not a git checkout, so no glob can be matched against tracked files.'
  if ($Json) { 'rule-currency-json: {"known": false}' }
  Exit-Guard -Name 'RULE-CURRENCY' -Code 3 -Summary "files=$($files.Count) blind=1"
}

$today = Get-Date
$nGlobs = 0; $dead = New-Object System.Collections.Generic.List[string]
$claims = New-Object System.Collections.Generic.List[object]
Write-Output "RULE CURRENCY - does every rules file load for something, and which dated claims are older than $StaleDays days?"
Write-Output ''
foreach ($f in $files) {
  $text = [IO.File]::ReadAllText($f.FullName)
  $gR = Get-FrontMatterGlobs -Text $text
  $globs = @($gR)
  $parts = @()
  foreach ($g in $globs) {
    $nGlobs++
    $hits = @(& git -C $repo ls-files -- ":(glob)$g")
    $parts += ("{0}={1}" -f $g, $hits.Count)
    if ($hits.Count -eq 0) { [void]$dead.Add("$($f.Name): $g") }
  }
  Write-Output ("  {0,-22} {1}" -f $f.Name, $(if ($parts.Count) { $parts -join '  ' } else { 'NO GLOBS - loads only when named' }))
  $cR = Get-DatedClaims -Text $text -Today $today -StaleDays $StaleDays
  foreach ($c in @($cR)) { $c | Add-Member -NotePropertyName File -NotePropertyValue $f.Name; [void]$claims.Add($c) }
}
$stale = @($claims | Where-Object { $_.Stale } | Sort-Object Date)
$oldest = if ($claims.Count) { (@($claims | Sort-Object Date))[0].Date } else { $null }
Write-Output ''
Write-Output ("  dated claims: {0} across {1} file(s), {2} older than {3} days, oldest {4}" -f $claims.Count, $files.Count, $stale.Count, $StaleDays, $(if ($oldest) { $oldest } else { 'none' }))
foreach ($s in ($stale | Select-Object -First 20)) {
  Write-Output ("    STALE {0}:{1} dated {2} ({3}d) states [{4}] - {5}" -f $s.File, $s.Line, $s.Date, $s.AgeDays, ($s.Numbers -join ', '), $s.Text)
}
if ($Json) {
  'rule-currency-json: ' + (([ordered]@{ known = $true; files = $files.Count; globs = $nGlobs; dead_globs = $dead.Count
                                           dated_claims = $claims.Count; stale_claims = $stale.Count; oldest_claim = $oldest }) | ConvertTo-Json -Compress)
}
if ($dead.Count) {
  Write-Output ''
  Write-Output ("RULE CURRENCY FAILED: {0} glob(s) match no tracked file, so their rules load for nothing:" -f $dead.Count)
  $dead | ForEach-Object { Write-Output "    $_" }
  Exit-Guard -Name 'RULE-CURRENCY' -Code 2 -Summary "files=$($files.Count) globs=$nGlobs dead=$($dead.Count) dated=$($claims.Count) stale=$($stale.Count)"
}
Write-Output ("rule-currency: PASSED - all {0} glob(s) match tracked files. Stale claims above are for a person, not a verdict." -f $nGlobs)
Exit-Guard -Name 'RULE-CURRENCY' -Code 0 -Summary "files=$($files.Count) globs=$nGlobs dead=0 dated=$($claims.Count) stale=$($stale.Count)"
