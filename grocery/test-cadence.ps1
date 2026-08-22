<#
  test-cadence.ps1 - self-test for the CADENCE gate in check-ad-cycles.ps1.

  WHY IT EXISTS. On 2026-08-22 the daily chain took 27-42 minutes on a 32-thread machine idling at 14%
  CPU, and most of the tail was checks re-answering a question whose inputs had not moved (test-auditors
  877 s over frozen fixtures, the embedding sweep 136-900 s, commodity-dupes 110 s over a registry only a
  human edits). Test-CadenceDue skips those unless the clock OR their own inputs say otherwise.

  TWO PROPERTIES THIS MUST HOLD, and the first version broke the second:
    1. A SKIP IS NOT A PASS. An unreadable or missing stamp must run the check, never skip it.
    2. AN INPUT EDIT IS DUE TODAY. A commit that blinds a guard has to be caught the same day, not up to
       seven days later - otherwise the cadence trades minutes for exactly the blindness the estate's
       whole guard culture exists to prevent.
  The founding bug: Set-CadenceRan stamped with ToString('s'), which truncates to the second, so an input
  written in the SAME second read as newer than the stamp and every check was due forever - the cadence
  would have cost its full runtime while looking like it worked. Round-trip 'o' fixes it, and case 2
  below is what caught it.

  Extracts the real functions out of check-ad-cycles.ps1 (it cannot be dot-sourced - that runs the whole
  daily chain) and drives them against a sandbox, so this tests the shipped code, not a copy of it.
#>
$src = Get-Content 'C:\Codex\ThriftyCrew\grocery\check-ad-cycles.ps1' -Raw
$m = [regex]::Match($src, '(?s)function Test-CadenceDue \{.*?\n\}\r?\nfunction Set-CadenceRan.*?\n\}\r?\nfunction Get-CadenceLast.*?\n\}')
if (-not $m.Success) { 'FAIL: could not extract the helpers'; exit 1 }
$sandbox = Join-Path $env:TEMP ('cad-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$script:CadenceRoot = $sandbox
$script:CadenceDir  = Join-Path $sandbox 'cadence'
New-Item -ItemType Directory -Path $script:CadenceDir -Force | Out-Null
Invoke-Expression $m.Value
$fail = 0
function T($ok,$m){ if($ok){"  ok    $m"}else{"  FAIL  $m"; $script:fail++} }

$inp = Join-Path $sandbox 'thing.ps1'
Set-Content $inp -Value 'x'

T (Test-CadenceDue -Name 'x' -EveryDays 7 -InputGlobs @('thing.ps1')) 'never run before -> DUE'
Set-CadenceRan 'x'
T (-not (Test-CadenceDue -Name 'x' -EveryDays 7 -InputGlobs @('thing.ps1'))) 'just ran, input unchanged -> SKIP'
Start-Sleep -Seconds 1
Set-Content $inp -Value 'y'          # the input moves
T (Test-CadenceDue -Name 'x' -EveryDays 7 -InputGlobs @('thing.ps1')) 'INPUT CHANGED -> DUE the same day (a commit that blinds a guard is still caught)'
Set-CadenceRan 'x'
T (-not (Test-CadenceDue -Name 'x' -EveryDays 7 -InputGlobs @('thing.ps1'))) 're-ran after the edit -> SKIP again'
# clock path
Set-Content (Join-Path $script:CadenceDir 'cadence-old.txt') -Value ((Get-Date).AddDays(-8).ToString('s'))
T (Test-CadenceDue -Name 'old' -EveryDays 7 -InputGlobs @()) '8 days since last run -> DUE on the clock alone'
# fail-open
Set-Content (Join-Path $script:CadenceDir 'cadence-bad.txt') -Value 'not-a-date'
T (Test-CadenceDue -Name 'bad' -EveryDays 7 -InputGlobs @()) 'unreadable stamp -> DUE (fails OPEN, never silently skips)'
T ((Get-CadenceLast 'nope') -eq 'never') 'a never-run check reports "never", not a fake date'
Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { "CADENCE SELF-TEST FAILED ($fail)"; exit 1 } else { 'CADENCE SELF-TEST PASS'; exit 0 }
