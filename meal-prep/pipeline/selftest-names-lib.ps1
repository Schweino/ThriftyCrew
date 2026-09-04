<#
  selftest-names-lib.ps1 - THE PINNED-REFERENCE GATE, PowerShell side (2026-09-04, PLAN-after-review P5).

  WHAT IT IS FOR. Pin the case NAMES a self-test executed, then diff a later run against them. A
  REMOVED name exits 2 even when every case that ran passed, because deleting a case leaves a suite
  green at exit 0 - measured on 2026-09-04, and the reason a tally settles nothing: delete one case
  and add one and the count is identical.

  WHY THERE ARE TWO IMPLEMENTATIONS. The Python side is hunt_lib.names_report; PowerShell cannot
  import it, and shelling out to Python from inside a self-test would make a suite's own gate depend
  on an interpreter that suite otherwise does not need. So this is a second implementation of one
  rule - and two implementations drift. They are held in step by `selftest-names-vectors.json`: both
  sides read that file in their own self-test and must answer every case with the stated exit. Add a
  case there first, then make both sides answer it.

  NO param() BLOCK IN THIS FILE, ON PURPOSE. A dot-sourced script runs its own param() block in the
  DOT-SOURCING scope, so a lib that declared switches would silently reset the caller's - the PS 5.1
  trap recorded at the top of hunt-run.ps1, which once made a self-test run the LIVE path. This file
  declares functions and nothing else. It also never writes the name of that switch parameter in
  full, because ops\run-gates.ps1 discovers self-tests by grepping for exactly that literal, and a
  library that answered discovery would be run as a suite it is not.

  Dot-source it, then:
    $script:SeenNames = @()                 # and append in the suite's own T
    Invoke-NamesFixtures -TBlock ${function:T} -Seen $script:SeenNames -VectorFile <vectors.json>
    $nf = Get-NamesFinish -Seen $script:SeenNames -NamesOut $o -NamesDiff $d
    foreach ($ln in $nf.Lines) { Write-Output $ln }      # the LINES are returned, never printed
    ... fold [int]$nf.Rc into the suite's own exit code
#>

function Get-NamesFromFile {
  <# The reference, read as UTF-8 explicitly. Get-Content's ANSI default corrupts non-ASCII on this
     box, and a case name that reads differently on the two sides of a diff is a phantom removal. #>
  param([string]$Path)
  $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace "^﻿", ''
  return @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Get-NamesReport {
  <# The VERDICT, so the exit code and the fixtures read one function. Returns a PSCustomObject with
     Rc (0 clean / 2 could-not-look-or-removal) and Lines. Mirrors hunt_lib.names_report exactly. #>
  param([string[]]$Seen, [string]$RefPath)
  if (-not (Test-Path -LiteralPath $RefPath)) {
    return [pscustomobject]@{ Rc = 2; Lines = @("  CANNOT DIFF - no reference at $RefPath") }
  }
  $ref = @(Get-NamesFromFile $RefPath)
  if ($ref.Count -eq 0) {
    return [pscustomobject]@{ Rc = 2; Lines = @("  CANNOT DIFF - the reference at $RefPath names no cases, and an empty reference cannot see a removal - re-pin it from HEAD") }
  }
  # STRIPPED ON BOTH SIDES. Indentation is layout, not identity: comparing it made 31 unchanged
  # cases read as 31 removals at once on the Python side, and a diff that cries wolf is unread.
  $seenSet = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($s in @($Seen)) { if ($null -ne $s) { [void]$seenSet.Add(([string]$s).Trim()) } }
  $refSet = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($s in $ref) { [void]$refSet.Add(([string]$s).Trim()) }
  $removed = @($refSet | Where-Object { -not $seenSet.Contains($_) } | Sort-Object)
  $added = @($seenSet | Where-Object { -not $refSet.Contains($_) } | Sort-Object)
  $lines = @("  vs {0}: {1} removed, {2} added" -f $RefPath, $removed.Count, $added.Count)
  foreach ($n in $added) { $lines += ("    +  " + $n) }
  foreach ($n in $removed) { $lines += ("    -  " + $n) }
  if ($removed.Count -gt 0) {
    $lines += ''
    $lines += ("  A CASE THAT VANISHED IS NOT A PASS. {0} case name(s) in the reference did not run. Either the commit says which and why, or this is coverage lost silently." -f $removed.Count)
    return [pscustomobject]@{ Rc = 2; Lines = $lines }
  }
  return [pscustomobject]@{ Rc = 0; Lines = $lines }
}

function Get-NamesFinish {
  <# Pin, diff, and hand back BOTH the rc and the lines for the suite to print. ONE call site per
     suite.

     IT RETURNS THE LINES RATHER THAN PRINTING THEM, and that is not a style choice. A PowerShell
     function's return value is EVERYTHING it wrote to the output stream, so the first shape of this
     - Write-Output for the report, `return $rc` for the verdict - handed the caller an ARRAY of
     [lines..., rc]. `$namesRc -ne 0` on an array is a FILTER, not a comparison, so it was truthy
     whatever the verdict, `exit $namesRc` coerced the array to 0, and the diff lines were never
     printed at all: the gate announced a removal it had not found and exited clean. Measured on the
     first run of this file, 2026-09-04. Nothing here may write to the output stream. #>
  param([string[]]$Seen, [string]$NamesOut = '', [string]$NamesDiff = '')
  $lines = @()
  if ($NamesOut) {
    # No BOM and LF endings, matching the Python side byte for byte: a reference whose line endings
    # depend on which language emitted it is a diff that lies.
    $text = ((@($Seen) | ForEach-Object { ([string]$_).Trim() }) -join "`n") + "`n"
    [IO.File]::WriteAllText($NamesOut, $text, (New-Object Text.UTF8Encoding($false)))
    $lines += ("  case NAMES pinned to {0} ({1}) - diff a later run against it with -NamesDiff" -f $NamesOut, @($Seen).Count)
  }
  if (-not $NamesDiff) { return [pscustomobject]@{ Rc = 0; Lines = $lines } }
  $r = Get-NamesReport -Seen $Seen -RefPath $NamesDiff
  return [pscustomobject]@{ Rc = [int]$r.Rc; Lines = @($lines + $r.Lines) }
}

function Invoke-NamesFixtures {
  <# The fixtures for the RULE, run inside every suite that owns a copy of the gate. $TBlock is the
     caller's own T, so the case names land in the caller's own pinned list.

     Case 1 is behavioural on purpose: it reads the caller's LIVE seen-list and asserts that names
     recorded earlier in this very run are in it. A fixture that grepped the suite's source for the
     append would match its own text and could never fail. #>
  param([scriptblock]$TBlock, [string[]]$Seen, [string]$VectorFile)
  & $TBlock 'MUST FIRE  this suite RECORDS the case names it prints - the pinned reference is built from the list, so a suite that prints without recording would pin a lie' `
    (@($Seen).Count -gt 3 -and -not (@($Seen) | Where-Object { [string]::IsNullOrWhiteSpace($_) })) `
    ("seen=" + @($Seen).Count)

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('names-gate-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    $ref = Join-Path $tmp 'ref.txt'
    [IO.File]::WriteAllText($ref, "case one`ncase two`ncase three`n", (New-Object Text.UTF8Encoding($false)))
    $r = Get-NamesReport -Seen @('case one', 'case two') -RefPath $ref
    & $TBlock 'MUST FIRE  a case name that VANISHED exits 2 even though every case that ran passed' `
      ($r.Rc -eq 2 -and (@($r.Lines) -join '|') -match '-  case three') (($r.Lines -join ' | '))
    $r = Get-NamesReport -Seen @('case one', 'case two', 'case three', 'case four') -RefPath $ref
    & $TBlock 'CLEAN TWIN an ADDED case is a new fixture, not a regression - exit 0, and it is named' `
      ($r.Rc -eq 0 -and (@($r.Lines) -join '|') -match '\+  case four') (($r.Lines -join ' | '))
    $r = Get-NamesReport -Seen @('  case one', 'case two', '   case three') -RefPath $ref
    & $TBlock 'CLEAN TWIN indentation is layout, not identity - an indented continuation name is the same case' `
      ($r.Rc -eq 0 -and $r.Lines[0] -match '0 removed, 0 added') (($r.Lines -join ' | '))
    $r = Get-NamesReport -Seen @('case one') -RefPath (Join-Path $tmp 'nope.txt')
    & $TBlock 'MUST FIRE  a MISSING reference is a could-not-look, never a clean diff' `
      ($r.Rc -eq 2 -and (@($r.Lines) -join '|') -match 'CANNOT DIFF') (($r.Lines -join ' | '))
    $empty = Join-Path $tmp 'empty.txt'
    [IO.File]::WriteAllText($empty, '', (New-Object Text.UTF8Encoding($false)))
    $r = Get-NamesReport -Seen @('case one') -RefPath $empty
    & $TBlock 'MUST FIRE  ...and so is an EMPTY reference - it can never see a removal, so it may not report one' `
      ($r.Rc -eq 2) ("rc=" + $r.Rc)

    # THE CROSS-LANGUAGE VECTORS. This is the only thing holding this file and hunt_lib's copy of the
    # same rule in step, so a failure here is the two implementations having drifted, not a typo.
    $bad = @()
    $n = 0
    if (Test-Path -LiteralPath $VectorFile) {
      $doc = [IO.File]::ReadAllText($VectorFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
      foreach ($row in @($doc.cases)) {
        $n++
        $rp = Join-Path $tmp ('v-' + $row.name + '.txt')
        # $null CHECKED BEFORE COUNTING. @($null).Count is 1 in PS 5.1, so a `ref: null` vector -
        # the one that means "the file does not exist" - would otherwise write a one-line reference
        # and quietly test the wrong thing.
        if ($null -ne $row.ref) {
          $body = ''
          foreach ($x in @($row.ref)) { $body += ([string]$x + "`n") }
          [IO.File]::WriteAllText($rp, $body, (New-Object Text.UTF8Encoding($false)))
        }
        $got = (Get-NamesReport -Seen @($row.seen) -RefPath $rp).Rc
        if ([int]$got -ne [int]$row.exit) { $bad += ("{0}: got {1} want {2}" -f $row.name, $got, $row.exit) }
      }
    } else {
      $bad += "no vector file at $VectorFile"
    }
    & $TBlock 'MUST FIRE  PowerShell answers every cross-language vector exactly as the file states - the Python twin answers the same file, and that is what keeps the two in step' `
      ($n -gt 0 -and $bad.Count -eq 0) ("{0} vector(s): {1}" -f $n, (($bad -join '; ')))
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
