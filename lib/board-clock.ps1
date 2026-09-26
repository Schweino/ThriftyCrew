# board-clock.ps1 - THE BOARD HAS THREE DATES, AND "NOW" IS NEVER THE FIRST ONE (2026-09-26).
#
#   week_of    WHICH AD SET the board is for. compare-deals takes it from the newest out\ads-<D>.json, and it is
#              also the D in comparison-<D>.json. ads-<D>.json is written only on a day a weekly ad is pulled, so
#              week_of LAGS the real date whenever no ad is due: 3 days on 2026-09-26 (nothing due 09-24..09-26).
#   judged_on  THE DATE THE BOARD JUDGED VALIDITY AT: which sales had ended, the 90-day publish window, the union
#              ages. The real date of the build (compare-deals -JudgeDate). Absent on a board built before it.
#   as_of      PER CELL, the date that price was actually READ from the store. The evidence.
#
# WHAT WENT WRONG WHEN ONE DATE DID TWO JOBS. compare-deals used week_of as "today", so on 2026-09-26 it priced 9
# cells from sale and rollback windows that had ended 09-23..09-25 (5 of them crowned "Cheapest"), the chain
# rehearsal refused every chain push as "stale data" over a board whose prices were read that morning at 6 of 7
# stores, and audit-board-freshness measured a stopped store against week_of, which reads it FRESHER than it is.
# design\PLAN-board-clock-2026-09-26.md has the survey of every consumer and the measured harm.
#
# THE RULE THIS FILE IS FOR: an AGE is measured from as_of (the evidence) to the REAL date, or to judged_on when
# the question is "what did this board judge against". week_of and the file-name date answer only "which ad set"
# and "which file is newest"; they are never subtracted from anything. ops\audit-board-clock.ps1 holds that line.
# And never built_at for data age: it is a BUILD date, so a board rebuilt today from week-old captures would read
# fresh - the dates-written-not-measured laundering the provenance contract exists to stop.
#
# NO param() BLOCK, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and would
# reset the caller's own -SelfTest. Same rule as lib\append-line.ps1.
# Self-test:   powershell -File lib\board-clock.ps1 -SelfTest
# WHAT THE SELF-TEST READS: in-memory fixture boards, and one it writes to a per-run temp directory.
# gate-inputs: lib\board-clock.ps1, lib\json-io.ps1

. (Join-Path $PSScriptRoot 'json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$__bcSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

$script:TcIsoDate = '^\d{4}-\d{2}-\d{2}$'

# The newest READ per store, from the board's own cells and (when given) the provenance-withheld record, whose rows
# are reads too: a store whose every row was withheld still has a newest read. ONE copy of this walk; it moved here
# from audit-board-freshness.ps1 unchanged.
# Returns @{ by_store = @{store = 'yyyy-MM-dd'}; published = @{store = dated cells}; newest = overall or '' }.
function Get-TcBoardNewestReads($Board, $Withheld) {
  $newest = @{}; $published = @{}
  if ($Board) {
    foreach ($r in @($Board.comparison)) {
      if ($null -eq $r) { continue }
      foreach ($s in @($r.stores)) {
        if ($null -eq $s) { continue }
        $st = [string]$s.store
        if (-not $published.ContainsKey($st)) { $published[$st] = 0 }
        if ([string]$s.as_of -match $script:TcIsoDate) {
          $published[$st]++
          if (-not $newest.ContainsKey($st) -or [string]$s.as_of -gt $newest[$st]) { $newest[$st] = [string]$s.as_of }
        }
      }
    }
  }
  if ($Withheld) {
    foreach ($w in @($Withheld.withheld)) {
      if ($null -eq $w) { continue }
      $st = [string]$w.store
      if ([string]$w.as_of -match $script:TcIsoDate -and (-not $newest.ContainsKey($st) -or [string]$w.as_of -gt $newest[$st])) { $newest[$st] = [string]$w.as_of }
    }
  }
  $all = ''
  foreach ($v in $newest.Values) { if ([string]$v -gt $all) { $all = [string]$v } }
  return @{ by_store = $newest; published = $published; newest = $all }
}

# The board's three dates and its evidence, in one object. Every field is '' when the board does not carry it:
# an absent date is UNKNOWN, never a default, so no caller can mistake a missing judged_on for a fresh one.
function Get-TcBoardClock($Board, $Withheld = $null) {
  $reads = Get-TcBoardNewestReads $Board $Withheld
  $wk = ''; $jd = ''; $ba = ''
  if ($Board) {
    if ([string]$Board.week_of -match $script:TcIsoDate) { $wk = [string]$Board.week_of }
    if ($Board.PSObject.Properties['judged_on'] -and [string]$Board.judged_on -match $script:TcIsoDate) { $jd = [string]$Board.judged_on }
    if ($Board.PSObject.Properties['built_at']) { $ba = [string]$Board.built_at }
  }
  return [pscustomobject]@{ week_of = $wk; judged_on = $jd; built_at = $ba; newest_read = $reads.newest; by_store = $reads.by_store; published = $reads.published }
}

# The same, read from a board FILE. Returns $null when the file is missing or is not JSON, so a caller can say
# BLIND rather than guess. Timed on the 3.9 MB board of 2026-09-26: 178 ms to parse, 21 ms to walk 2,653 cells.
function Get-TcBoardClockFromFile([string]$Path) {
  if (-not $Path -or -not [IO.File]::Exists($Path)) { return $null }
  $b = $null
  try { $b = Read-JsonFile $Path } catch { return $null }
  if ($null -eq $b) { return $null }
  return (Get-TcBoardClock $b $null)
}

# Whole days from an ISO date to $Now. $null when the date is not an ISO date - an unknown age is never 0.
function Get-TcDaysSince([string]$Date, [datetime]$Now) {
  if ($Date -notmatch $script:TcIsoDate) { return $null }
  $d = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  return [int]($Now.Date - $d.Date).TotalDays
}

if ($__bcSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:bcCases = 0; $script:bcFailed = 0
  function Test-BcCase([string]$Label, [string]$Text, [bool]$Ok, [string]$Got) {
    $script:bcCases++
    if ($Ok) { Write-Output ('  ok    ' + $Label + '  ' + $Text) } else { $script:bcFailed++; Write-Output ('  FAIL  ' + $Label + '  ' + $Text + '   got: ' + $Got) }
  }
  function New-BcBoard([string]$Week, [object[]]$Cells, [string]$Judged = '', [string]$Built = '') {
    $rows = @(foreach ($c in $Cells) { [pscustomobject]@{ id = $c[0]; stores = @([pscustomobject]@{ store = $c[1]; as_of = $c[2] }) } })
    $o = [ordered]@{ week_of = $Week; built_at = $Built; comparison = $rows }
    if ($Judged) { $o['judged_on'] = $Judged }
    return [pscustomobject]$o
  }
  $dir = Join-Path $env:TEMP ('bc-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
    # THE FOUNDING SHAPE, from 2026-09-26: the board named for the 09-23 ad set, rebuilt at 08:06 from reads of that
    # morning at most stores and the day before at Hy-Vee.
    $found = New-BcBoard '2026-09-23' @(@('milk', 'Aldi', '2026-09-26'), @('eggs', 'Hy-Vee', '2026-09-25'), @('bread', 'Walmart', '2026-09-26')) '' '2026-09-26T08:06:07'
    $c = Get-TcBoardClock $found
    $now = [datetime]'2026-09-26'
    Test-BcCase 'MUST FIRE' 'the founding board: newest read is 2026-09-26 (the evidence), not the 2026-09-23 it is named for' ($c.newest_read -eq '2026-09-26' -and $c.week_of -eq '2026-09-23') ("newest=$($c.newest_read) week=$($c.week_of)")
    Test-BcCase 'MUST FIRE' '...so its data age on 2026-09-26 is 0 days, where the name reads 3' ((Get-TcDaysSince $c.newest_read $now) -eq 0 -and (Get-TcDaysSince $c.week_of $now) -eq 3) ('age=' + (Get-TcDaysSince $c.newest_read $now))
    Test-BcCase 'MUST FIRE' 'per store: Hy-Vee newest read 2026-09-25, Aldi 2026-09-26' ($c.by_store['Hy-Vee'] -eq '2026-09-25' -and $c.by_store['Aldi'] -eq '2026-09-26') (($c.by_store.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ',')
    # THE OTHER DIRECTION: a board named today whose prices are old must read OLD. built_at must not launder it.
    $old = New-BcBoard '2026-09-26' @(,@('milk', 'Aldi', '2026-09-20')) '' '2026-09-26T08:06:07'
    $co = Get-TcBoardClock $old
    Test-BcCase 'MUST FIRE' 'a board named and built today from reads of 09-20 is 6 days old by its evidence' ((Get-TcDaysSince $co.newest_read $now) -eq 6) ('newest=' + $co.newest_read)
    # WITHHELD ROWS ARE READS TOO.
    $wh = [pscustomobject]@{ withheld = @([pscustomobject]@{ store = "Sam's Club"; why = 'STALE'; as_of = '2026-09-24' }) }
    $cw = Get-TcBoardClock (New-BcBoard '2026-09-23' @(,@('milk', 'Aldi', '2026-09-22'))) $wh
    Test-BcCase 'CLEAN TWIN' 'a store whose only reads were withheld still has a newest read, and it raises the overall one' ($cw.by_store["Sam's Club"] -eq '2026-09-24' -and $cw.newest_read -eq '2026-09-24') ('sams=' + $cw.by_store["Sam's Club"] + ' all=' + $cw.newest_read)
    # UNKNOWN IS NEVER A DEFAULT.
    $nd = Get-TcBoardClock (New-BcBoard '2026-09-23' @(,@('milk', 'Aldi', '')))
    Test-BcCase 'MUST NOT FIRE' 'a board with no dated cell has no newest read and no age - never 0, never its name' ($nd.newest_read -eq '' -and $null -eq (Get-TcDaysSince $nd.newest_read $now) -and $nd.judged_on -eq '') ("newest='$($nd.newest_read)' judged='$($nd.judged_on)'")
    $cj = Get-TcBoardClock (New-BcBoard '2026-09-23' @(,@('milk', 'Aldi', '2026-09-26')) '2026-09-26')
    Test-BcCase 'CLEAN TWIN' 'judged_on is read back when the board carries it' ($cj.judged_on -eq '2026-09-26') ('judged=' + $cj.judged_on)
    # FROM A FILE, through the real reader.
    $p = Join-Path $dir 'comparison-2026-09-23.json'
    [IO.File]::WriteAllText($p, ($found | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $cf = Get-TcBoardClockFromFile $p
    Test-BcCase 'CLEAN TWIN' 'read from a file, the same board gives the same newest read' ($cf -and $cf.newest_read -eq '2026-09-26') ('file=' + $(if ($cf) { $cf.newest_read } else { 'null' }))
    Test-BcCase 'MUST NOT FIRE' 'a missing file is $null (BLIND to the caller), never an empty clock that reads as a date' ($null -eq (Get-TcBoardClockFromFile (Join-Path $dir 'nope.json'))) 'not null'
    [IO.File]::WriteAllText((Join-Path $dir 'bad.json'), '{not json', (New-Object Text.UTF8Encoding($false)))
    Test-BcCase 'MUST NOT FIRE' 'a file that is not JSON is $null too' ($null -eq (Get-TcBoardClockFromFile (Join-Path $dir 'bad.json'))) 'not null'
  } catch {
    Test-BcCase 'FAIL' 'the self-test ran to its end with no unexpected error' $false ($_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber)
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $want = 10
  if ($script:bcCases -ne $want) { Write-Output ('  FAIL  the suite ran ' + $script:bcCases + ' case(s), not the ' + $want + ' it lists'); $script:bcFailed++ }
  if ($script:bcFailed) { Write-Output ('board-clock SELF-TEST FAIL (' + $script:bcFailed + ' of ' + $script:bcCases + ')'); exit 1 }
  Write-Output ('board-clock SELF-TEST PASS (' + $script:bcCases + ' cases)')
  exit 0
}
