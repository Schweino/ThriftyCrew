<#
  golden-board-compare.ps1 - are two golden board runs the SAME board under Brad's accepted bar?

  WHY IT EXISTS (Brad's ruling, 2026-09-27, design\PLAN-split-giant-files-2026-09-27.md Decisions, "golden bar").
  A split of grocery\compare-deals.ps1 owes a golden proof: the board before and after, over one frozen snapshot of
  grocery\out, must be the same board. Strict byte identity is impossible even for two runs of ONE unchanged commit:
  measured 2026-09-27, 4 of the 11 files a run writes differ, and only in a "built_at" or "updated" clock stamp and
  in the scratch clone's own path. The accepted bar is therefore:
      byte-identical, except a "built_at"/"updated" ISO timestamp value and the run's own root path.
  Nothing else is masked. A one-cent price change at the same file length is a FAIL (the self-test's MUST FIRE).

  Usage (after two ops\golden-board-run.ps1 runs into the same -Work folder):
    powershell -NoProfile -File ops\golden-board-compare.ps1 -Work <folder> -A <tag> -B <tag>
  Reads <Work>\hash-<tag>.tsv and the files under <Work>\g-<tag>\.

  Exit 0: every written file is byte-identical or equal under the bar. 1: a difference, each printed.
  3: could not evaluate (a hash list missing or empty), never a pass. Last line GOLDEN-BOARD-COMPARE-COMPLETE.

  SCOPE OF A CLEAN REPORT: SOUND for the files the runs wrote (every byte outside the two masks is compared), UNSOUND
  for anything a run did not write. A reported difference is COMPLETE: the bytes differ outside the masks.

  Self-test: powershell -NoProfile -File ops\golden-board-compare.ps1 -SelfTest
#>
# gate-inputs: ops\golden-board-compare.ps1
[CmdletBinding()]
param(
  [string]$Work = '',
  [string]$A = '',
  [string]$B = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function ConvertTo-GoldenNormalText {
  <# The text with exactly the two accepted masks applied: the run's root path (as written in JSON, backslashes
     doubled, and plain), and the value of a "built_at" or "updated" key that is an ISO timestamp. #>
  param([string]$Text, [string]$RunRoot)
  $t = $Text
  if ($RunRoot) {
    $t = $t.Replace($RunRoot.Replace('\', '\\'), '<ROOT>').Replace($RunRoot, '<ROOT>')
  }
  return [regex]::Replace($t, '"(built_at|updated)":(\s*)"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[^"]*"', '"$1":$2"<T>"')
}

function Test-GoldenTextEqual {
  <# $true when two file texts are equal under the bar. #>
  param([string]$TextA, [string]$RootA, [string]$TextB, [string]$RootB)
  return [string]::Equals((ConvertTo-GoldenNormalText $TextA $RootA), (ConvertTo-GoldenNormalText $TextB $RootB), [StringComparison]::Ordinal)
}

function Read-GoldenHashList {
  param([string]$Path)
  $h = @{}
  foreach ($l in [IO.File]::ReadAllLines($Path)) {
    if (-not $l) { continue }
    $p = $l.Split("`t")
    $h[$p[0]] = $p[1]
  }
  return $h
}

function Compare-GoldenRuns {
  <# One row per file either run wrote: SAME (bytes), NORM (equal under the bar) or FAIL. #>
  param([string]$Work, [string]$A, [string]$B)
  $ha = Read-GoldenHashList (Join-Path $Work ("hash-" + $A + ".tsv"))
  $hb = Read-GoldenHashList (Join-Path $Work ("hash-" + $B + ".tsv"))
  $rootA = Join-Path $Work ("g-" + $A); $rootB = Join-Path $Work ("g-" + $B)
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($f in @(@($ha.Keys) + @($hb.Keys) | Sort-Object -Unique)) {
    if (-not $ha.ContainsKey($f) -or -not $hb.ContainsKey($f)) { $rows.Add([pscustomobject]@{ v = 'FAIL'; f = $f; why = 'written by one run only' }); continue }
    if ($ha[$f] -eq $hb[$f]) { $rows.Add([pscustomobject]@{ v = 'SAME'; f = $f; why = $ha[$f].Substring(0, 16) }); continue }
    $eq = Test-GoldenTextEqual ([IO.File]::ReadAllText((Join-Path $rootA $f))) $rootA ([IO.File]::ReadAllText((Join-Path $rootB $f))) $rootB
    if ($eq) { $rows.Add([pscustomobject]@{ v = 'NORM'; f = $f; why = 'equal after the clock stamps and run root' }) }
    else { $rows.Add([pscustomobject]@{ v = 'FAIL'; f = $f; why = 'content differs outside the masks' }) }
  }
  return $rows.ToArray()
}

if ($SelfTest) {
  $fail = 0; $n = 0
  function GbcCase([string]$label, [bool]$cond) {
    $script:n++
    if ($cond) { Write-Output ('  PASS  ' + $label) } else { Write-Output ('  FAIL  ' + $label); $script:fail++ }
  }
  $scratch = Join-Path ([IO.Path]::GetTempPath()) ('gbc-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    $rootA = 'C:\t\g-a'; $rootB = 'C:\t\g-b'
    $boardA = '{ "built_at":  "2026-09-27T15:02:23", "source":  "C:\\t\\g-a\\grocery\\out\\ads.json", "cells": [ { "id": "milk", "cheapest_price": 0.1435 } ] }'
    $stampOnly = '{ "built_at":  "2026-09-27T15:02:18", "source":  "C:\\t\\g-b\\grocery\\out\\ads.json", "cells": [ { "id": "milk", "cheapest_price": 0.1435 } ] }'
    $oneCent = '{ "built_at":  "2026-09-27T15:02:18", "source":  "C:\\t\\g-b\\grocery\\out\\ads.json", "cells": [ { "id": "milk", "cheapest_price": 0.1535 } ] }'
    GbcCase 'MUST FIRE  a one-cent price change at the same length is NOT equal (0.1435 vs 0.1535)' (($oneCent.Length -eq $boardA.Length) -and -not (Test-GoldenTextEqual $boardA $rootA $oneCent $rootB))
    GbcCase 'MUST NOT FIRE  a difference only in the built_at stamp and the run root is equal' (Test-GoldenTextEqual $boardA $rootA $stampOnly $rootB)
    GbcCase 'MUST NOT FIRE  an "updated" stamp alone is masked too' (Test-GoldenTextEqual '{"updated": "2026-09-27T15:03:12"}' '' '{"updated": "2026-09-27T15:03:09"}' '')
    GbcCase 'MUST FIRE  a timestamp under any OTHER key is not masked (as_of is data)' (-not (Test-GoldenTextEqual '{"as_of": "2026-09-27T15:03:12"}' '' '{"as_of": "2026-09-27T15:03:09"}' ''))
    GbcCase 'MUST FIRE  the same root text inside another arm is not masked by this arm''s root' (-not (Test-GoldenTextEqual '"C:\\t\\g-a\\x"' $rootA '"C:\\t\\g-a\\x"' $rootB))
    GbcCase 'CLEAN TWIN  identical text is equal' (Test-GoldenTextEqual $boardA $rootA $boardA $rootA)
    # the file-level comparer, over a real pair of run folders
    New-Item -ItemType Directory -Path (Join-Path $scratch 'g-a\out'), (Join-Path $scratch 'g-b\out') -ErrorAction Stop | Out-Null
    $ra = Join-Path $scratch 'g-a'; $rb = Join-Path $scratch 'g-b'
    [IO.File]::WriteAllText((Join-Path $ra 'out\board.json'), $boardA.Replace('C:\\t\\g-a', $ra.Replace('\', '\\')))
    [IO.File]::WriteAllText((Join-Path $rb 'out\board.json'), $stampOnly.Replace('C:\\t\\g-b', $rb.Replace('\', '\\')))
    [IO.File]::WriteAllText((Join-Path $ra 'out\same.txt'), 'x'); [IO.File]::WriteAllText((Join-Path $rb 'out\same.txt'), 'x')
    [IO.File]::WriteAllLines((Join-Path $scratch 'hash-a.tsv'), [string[]]@("out\board.json`tAAAAAAAAAAAAAAAA1", "out\same.txt`tBBBBBBBBBBBBBBBB1"))
    [IO.File]::WriteAllLines((Join-Path $scratch 'hash-b.tsv'), [string[]]@("out\board.json`tCCCCCCCCCCCCCCCC1", "out\same.txt`tBBBBBBBBBBBBBBBB1"))
    $rows = Compare-GoldenRuns -Work $scratch -A 'a' -B 'b'
    GbcCase 'MUST NOT FIRE  file level: a stamp-only board reads NORM and an identical file SAME' ((@($rows | Where-Object { $_.v -eq 'NORM' }).Count -eq 1) -and (@($rows | Where-Object { $_.v -eq 'SAME' }).Count -eq 1) -and (@($rows | Where-Object { $_.v -eq 'FAIL' }).Count -eq 0))
    [IO.File]::WriteAllText((Join-Path $rb 'out\board.json'), $oneCent.Replace('C:\\t\\g-b', $rb.Replace('\', '\\')))
    $rows = Compare-GoldenRuns -Work $scratch -A 'a' -B 'b'
    GbcCase 'MUST FIRE  file level: the one-cent board reads FAIL' (@($rows | Where-Object { $_.v -eq 'FAIL' -and $_.f -eq 'out\board.json' }).Count -eq 1)
    [IO.File]::WriteAllLines((Join-Path $scratch 'hash-b.tsv'), [string[]]@("out\board.json`tCCCCCCCCCCCCCCCC1"))
    $rows = Compare-GoldenRuns -Work $scratch -A 'a' -B 'b'
    GbcCase 'MUST FIRE  file level: a file one run wrote and the other did not reads FAIL' (@($rows | Where-Object { $_.v -eq 'FAIL' -and $_.f -eq 'out\same.txt' }).Count -eq 1)
  } catch {
    $fail++; Write-Output ('  FAIL  unexpected error: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($n -ne 9) { $fail++; Write-Output ('  FAIL  expected 9 cases, ran ' + $n) }
  if ($fail) { Write-Output ("golden-board-compare: self-test FAIL ($fail of $n)"); exit 1 }
  Write-Output ("golden-board-compare: self-test pass ($n cases)")
  exit 0
}

if (-not $Work -or -not $A -or -not $B -or -not (Test-Path -LiteralPath (Join-Path $Work ("hash-" + $A + ".tsv"))) -or -not (Test-Path -LiteralPath (Join-Path $Work ("hash-" + $B + ".tsv")))) {
  Write-Output 'golden-board-compare: COULD NOT EVALUATE - usage: -Work <folder> -A <tag> -B <tag>, both hash lists present. Not a pass.'
  Write-Output 'GOLDEN-BOARD-COMPARE-COMPLETE could-not-evaluate'
  exit 3
}
$rows = @(Compare-GoldenRuns -Work $Work -A $A -B $B)
if (-not $rows.Count) {
  Write-Output 'golden-board-compare: COULD NOT EVALUATE - neither run wrote a file. Not a pass.'
  Write-Output 'GOLDEN-BOARD-COMPARE-COMPLETE could-not-evaluate'
  exit 3
}
foreach ($r in $rows) { Write-Output ('{0}  {1}  ({2})' -f $r.v, $r.f, $r.why) }
$nf = @($rows | Where-Object { $_.v -eq 'FAIL' }).Count
Write-Output ('GOLDEN-BOARD-COMPARE-COMPLETE {0} vs {1}: files={2} same={3} equal-under-bar={4} fail={5}' -f $A, $B, $rows.Count, @($rows | Where-Object { $_.v -eq 'SAME' }).Count, @($rows | Where-Object { $_.v -eq 'NORM' }).Count, $nf)
if ($nf) { exit 1 } else { exit 0 }
