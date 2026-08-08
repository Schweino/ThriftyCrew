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
param([switch]$SelfTest)

function Write-GuardComplete {
  <# Call ONCE, as the last thing a guard does on its normal path. Never inside a -SelfTest branch (those
     have their own PASS/FAIL line) and never before the work is done - a marker printed early is exactly
     the checkpoint-before-durable lie this contract exists to prevent. #>
  param([Parameter(Mandatory=$true)][string]$Name, [string]$Summary = '')
  Write-Output ("{0}-COMPLETE {1}" -f $Name.ToUpper(), $Summary).TrimEnd()
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

if ($SelfTest) {
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

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}
