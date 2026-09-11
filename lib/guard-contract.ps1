# guard-contract.ps1 - THE rule that makes "this watcher ran to the end" provable instead of assumed.
#
# WHY THIS EXISTS (2026-08-08). test-auditors.ps1 exited 1 having thrown 242 checks BEFORE the end, after
# printing 176 lines of cheerful PASS output and NOT ONE line saying FAIL. Nothing could tell that from a
# normal findings-exit: the code was 1 either way, and the output was long, so the estate's existing
# "zero output means it did not run" rule could not see it. It only surfaced because that night's work
# happened to contain the pathological string that crashed it.
#
# Every other detector in the chain has the same hole. A puller that dies is loud - the data downstream is
# missing. A DETECTOR that dies is silent, because "no findings" and "never ran" look identical from the
# outside, and the estate has now been bitten by that shape at least five separate times (ff-carry threw on
# its report line for weeks; the cloud gate stood down 13 days reporting SUCCESS; reanchor-all could crash
# between halves; store-integrity and batch-ledger crashes were indistinguishable from clean).
#
# THE CONTRACT: a detector's LAST line of stdout is
#     <NAME>-COMPLETE <free-form summary>
# emitted only after the work is finished. The caller requires that line before believing anything the
# guard said - regardless of exit code, and regardless of how much output came before it. Exit codes still
# carry the VERDICT (0 clean / 1 findings / 2 hard / 3 could-not-evaluate); the marker carries COMPLETION.
# They are different questions and the estate kept conflating them.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\guard-contract.ps1')
# Self-test:   powershell -File lib\guard-contract.ps1 -SelfTest
#
# THIS FILE DECLARES NO param() BLOCK, DELIBERATELY. It shipped with param([switch]$SelfTest), and in PS 5.1
# dot-sourcing a script runs its param() block in the CALLER's scope - so every guard that dot-sourced this
# had its OWN -SelfTest switch reset to $false on the line after it bound. The retrofit that exists to make
# guards provable was silently disarming their self-tests instead: aisle-test -SelfTest fell straight past
# its 14-case branch to "nothing to judge" and exited 0, which reads as a pass. Measured, not theorised
# (True before the dot-source, False after). Read it off $args and only when RUN, never when dot-sourced.
$__gcSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Write-GuardComplete {
  <# Call ONCE, as the last thing a guard does on its normal path. Never inside a -SelfTest branch (those
     have their own PASS/FAIL line) and never before the work is done - a marker printed early is exactly
     the checkpoint-before-durable lie this contract exists to prevent.

     THE SUMMARY CARRIES THE DENOMINATOR, NOT JUST THE FINDING COUNT (2026-09-06, backlog E22).
     Write `scanned=3164 findings=3`, never `findings=3`. Two reasons, and the second is the one that
     is easy to miss:

       * A count with no population cannot be read at all. "3 findings" is a clean board and a broken
         one depending on whether 3,164 rows were examined or 4 were.
       * PRECISION IS NOT A PROPERTY OF A DETECTOR. It is a property of a detector AND the rate at
         which the thing it detects actually occurs. A rule with 80% recall and a 13% false-alarm rate
         is right 18% of the times it fires on a population where the target sits in 3% of rows - with
         nothing mis-scored and no rows dropped. Every -SelfTest in this estate drives one must-fire
         fixture and its clean twin, which is a 50% base rate BY CONSTRUCTION: it measures recall
         honestly and overstates precision enormously. So a detector moved to a rarer corpus loses
         precision with NO code change and no movement in its fixture verdict, and the only number
         that would have shown it is the live denominator.

     A guard that genuinely has no denominator - one that answers a single yes/no about one file -
     should say what it looked at instead, e.g. `file=comparison-2026-09-06.json`. #>
  param([Parameter(Mandatory=$true)][string]$Name, [string]$Summary = '')
  Write-Output ("{0}-COMPLETE {1}" -f $Name.ToUpper(), $Summary).TrimEnd()
}

$script:TcGuardMarkerWritten = $false

function Exit-Guard {
  <# The ONLY way a wrapped guard should leave: write the marker, then exit with the code.

     WHY THIS EXISTS (2026-09-09, backlog I86, ruled by Brad: sweep it). `Write-GuardComplete` is a
     convention honoured independently at 793 call sites across 119 files, and its own header records
     FIVE separate incidents of a guard dying without one - which is indistinguishable from a clean
     run. The Chain-of-Responsibility fix is a template method a link structurally cannot skip.

     MEASURED 2026-09-09, and it is the fact the whole design turns on: `exit` inside a scriptblock
     DOES run an enclosing `finally`, but it does NOT run the statements after the call. So a wrapper
     that wrote the marker after invoking the body would silently drop it for every guard that exits
     with a finding - which is most of them. The marker therefore travels WITH the exit. #>
  param([Parameter(Mandatory=$true)][string]$Name, [int]$Code = 0, [string]$Summary = '')
  Write-GuardComplete -Name $Name -Summary $Summary
  $script:TcGuardMarkerWritten = $true
  exit $Code
}

function Invoke-Guard {
  <# Run a guard body so the completion marker cannot be forgotten.

     THREE PATHS, AND THE THIRD IS THE POINT:
       * the body returns normally  -> the marker is written here, from its return value
       * the body calls Exit-Guard  -> the marker was already written, and this does not double it
       * the body THROWS            -> NO marker, deliberately. A crash must never look complete;
                                       that is the entire failure this contract exists to catch.

     A raw `exit N` inside the body writes no marker and that is left LOUD on purpose: the guard-
     contract audit then reports the guard as unfinished, which is a visible failure rather than a
     silent one. The wrapper moves the obligation from 793 sites to 119; it does not remove the audit,
     because forgetting to USE the wrapper is the same hole one level up. #>
  param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][scriptblock]$Body)
  $script:TcGuardMarkerWritten = $false
  $ok = $false
  $summary = ''
  try {
    $summary = & $Body
    $ok = $true
  } finally {
    if ($ok -and -not $script:TcGuardMarkerWritten) {
      Write-GuardComplete -Name $Name -Summary ([string]$summary)
      $script:TcGuardMarkerWritten = $true
    }
  }
}

function Test-GuardComplete {
  <# Caller side: did this child finish? $Output is everything the child wrote to stdout. #>
  param($Output, [Parameter(Mandatory=$true)][string]$Name)
  $lines = @($Output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -ne '' })
  if (-not $lines.Count) { return $false }
  # the marker must be the LAST non-empty line: a guard that printed it and then kept going (and died) has
  # not finished either, and accepting a mid-output marker would let exactly that through.
  return ($lines[-1].Trim() -match ('^' + [regex]::Escape($Name.ToUpper()) + '-COMPLETE(\s|$)'))
}

if ($__gcSelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  T 'a guard that finished is recognised' `
    (Test-GuardComplete @('working...', 'ROW-AGE-COMPLETE stores=7 findings=0') 'row-age') 'not recognised'

  # THE FOUNDING CASE, frozen: lots of healthy-looking output, then death. 176 lines of PASS and no marker.
  $crashed = @('PASS  check one', 'PASS  check two', 'Exception calling "GetFileNameWithoutExtension"')
  T 'MUST FIRE  a guard that died mid-run is NOT complete, however much it printed' `
    (-not (Test-GuardComplete $crashed 'test-auditors')) 'accepted a crashed run'

  T 'MUST FIRE  a guard that printed nothing is not complete' (-not (Test-GuardComplete @() 'x')) 'accepted silence'

  # a marker that is not LAST means the guard kept working and then stopped
  T 'MUST FIRE  a marker followed by more output is not complete' `
    (-not (Test-GuardComplete @('X-COMPLETE ok', 'then it crashed') 'x')) 'accepted a mid-output marker'

  T 'trailing blank lines do not defeat the check' `
    (Test-GuardComplete @('GUARDS-COMPLETE ok', '', '   ') 'guards') 'blank lines broke it'

  T 'the name must MATCH - one guard cannot vouch for another' `
    (-not (Test-GuardComplete @('OTHER-COMPLETE ok') 'guards')) 'accepted the wrong name'

  # emission shape
  $out = & { Write-GuardComplete -Name 'row-age' -Summary 'stores=7' }
  T 'Write-GuardComplete emits NAME-COMPLETE <summary>, upper-cased' ($out -eq 'ROW-AGE-COMPLETE stores=7') $out
  $bare = & { Write-GuardComplete -Name 'x' }
  T 'a summary is optional and leaves no trailing space' ($bare -eq 'X-COMPLETE') "[$bare]"

  # EVERY PROBE FILE LIVES IN A DIRECTORY THIS RUN OWNS (2026-09-11). These probes were fixed names in the
  # shared %TEMP% - gc-clobber-probe.ps1, gc-invoke-probe.ps1, gc-probe-out-<mode>.txt - and this estate runs
  # run-gates from several sessions and worktrees at once. A sibling run that rewrote or deleted
  # gc-invoke-probe.ps1 mid-suite (this suite deletes it at the end) turned three cases red inside a pre-push
  # hook: exitguard came back code=0 with no output, rawexit code=1, while the file passed solo. The
  # directory is removed in the finally, so a throw cannot leak it either.
  $gcTmp = Join-Path $env:TEMP ('gc-selftest-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $gcTmp -Force | Out-Null
  try {
    # MUST FIRE, frozen from the 2026-08-08 regression above. A caller declaring its own [switch]$SelfTest
    # dot-sources this file; if this file ever regrows a colliding param() block, the caller's switch comes
    # back $false and this case goes red. It has to run out-of-process because the bug IS scope behaviour.
    $probe = Join-Path $gcTmp 'gc-clobber-probe.ps1'
    ("param([switch]`$SelfTest)`r`n. '" + $PSCommandPath + "'`r`nWrite-Output ('SelfTest=' + `$SelfTest)") |
      Set-Content $probe -Encoding UTF8
    $probeOut = ((& powershell -NoProfile -ExecutionPolicy Bypass -File $probe -SelfTest 2>&1 |
                   ForEach-Object { [string]$_ }) -join ' ').Trim()
    T 'MUST FIRE  dot-sourcing this must not clobber a caller''s own -SelfTest switch' `
      ($probeOut -match 'SelfTest=True') $probeOut

    # ---- Invoke-Guard / Exit-Guard (2026-09-09, backlog I86) -------------------------------------
    # These run OUT OF PROCESS because the behaviour under test IS process exit: `exit` inside a
    # scriptblock cannot be observed from inside the same runspace without ending this suite.
    $gp = Join-Path $gcTmp 'gc-invoke-probe.ps1'
    $body = @(
      'param([string]$Mode)',
      (". '" + $PSCommandPath + "'"),
      'Invoke-Guard -Name ''probe'' -Body {',
      '  if ($Mode -eq ''normal'') { ''scanned=10 findings=0'' }',
      '  elseif ($Mode -eq ''exitguard'') { Exit-Guard -Name ''probe'' -Code 2 -Summary ''scanned=10 findings=3'' }',
      '  elseif ($Mode -eq ''throws'') { throw ''boom'' }',
      '  elseif ($Mode -eq ''rawexit'') { Write-Output ''did work''; exit 3 }',
      '}'
    ) -join "`r`n"
    Set-Content -LiteralPath $gp -Value $body -Encoding UTF8

    function RunProbe([string]$mode) {
      $o = Join-Path $gcTmp ("gc-probe-out-" + $mode + ".txt")
      & powershell -NoProfile -ExecutionPolicy Bypass -File $gp $mode > $o 2>$null
      $code = $LASTEXITCODE
      $lines = @(Get-Content $o -ErrorAction SilentlyContinue)
      return @{ Code = $code; Lines = $lines }
    }

    $r1 = RunProbe 'normal'
    T 'Invoke-Guard writes the marker when the body returns normally' `
      (Test-GuardComplete $r1.Lines 'probe') (($r1.Lines -join '|'))
    T 'and the body''s return value becomes the summary' `
      (($r1.Lines -join ' ') -match 'PROBE-COMPLETE scanned=10 findings=0') (($r1.Lines -join '|'))

    $r2 = RunProbe 'exitguard'
    T 'MUST FIRE  Exit-Guard writes the marker AND preserves the exit code - `exit` skips the statements after the body, so the marker has to travel with it' `
      ((Test-GuardComplete $r2.Lines 'probe') -and $r2.Code -eq 2) ("code=" + $r2.Code + " " + ($r2.Lines -join '|'))
    T 'MUST NOT FIRE  the marker is not written twice' `
      (@($r2.Lines | Where-Object { $_ -match 'PROBE-COMPLETE' }).Count -eq 1) (($r2.Lines -join '|'))

    $r3 = RunProbe 'throws'
    T 'MUST FIRE  a body that THROWS writes NO marker - a crash must never look complete' `
      (-not (Test-GuardComplete $r3.Lines 'probe')) (($r3.Lines -join '|'))

    $r4 = RunProbe 'rawexit'
    T 'MUST FIRE  a raw `exit` inside the body writes no marker, so the audit sees an unfinished guard rather than a silent pass' `
      ((-not (Test-GuardComplete $r4.Lines 'probe')) -and $r4.Code -eq 3) ("code=" + $r4.Code + " " + ($r4.Lines -join '|'))
  } finally { Remove-Item -LiteralPath $gcTmp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}
