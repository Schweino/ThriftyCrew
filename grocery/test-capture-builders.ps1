<#
  test-capture-builders.ps1 - the browser-store builder block in capture-run.ps1, proven against
  fake captures and fake builders in a sandbox.

  WHY IT EXISTS. On 2026-08-23 that block stopped being one loop (check the capture, build it, run
  the second stage, judge it - per store, one store after another) and became three passes: a
  serial pass that decides what exists, a FAN-OUT that runs the first-stage builders side by side,
  and a serial pass that reads the verdicts and runs the second stage. The behaviour is supposed to
  be identical and only the timing different, which is exactly the claim that needs a fixture -
  "identical" is easy to say and the block is the last mile of every capture the estate takes.

  IT READS THE SHIPPED BLOCK, NEVER A COPY. The block is extracted out of capture-run.ps1 by marker
  and executed. A transcribed copy would pass forever while production drifted away from it - the
  same reason test-cadence.ps1 pulls its three helpers out of check-ad-cycles rather than restating
  them. If the markers stop matching, that is a FAIL, not a skip: a fixture that cannot find its
  subject has proven nothing.

  FOUR CASES, one per way the restructure could have broken something the single loop got right:
    A  a store with a capture and a builder that succeeds  -> built, with an ABSOLUTE -In path
    B  a store with NO capture                             -> outstanding, builder never launched
    C  a store whose builder FAILS                         -> failed BY NAME, second stage skipped
    D  fareway: stage 1 ok -> stage 2 runs, and stage 2's failure is judged on EVIDENCE (does
       today's file already hold rows captured today?) rather than on its exit code

  Run:  powershell -NoProfile -File grocery	est-capture-builders.ps1
  Exit: 0 pass, 1 a case failed, 3 could not find the block (BLIND - nothing was proven).
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$src = Get-Content (Join-Path $root 'capture-run.ps1') -Raw
$i = $src.IndexOf('      $bLanes = @(); $bMeta = @{}')
if ($i -lt 0) { Write-Output 'BLIND: could not find the builder block start marker in capture-run.ps1 - the fixture proved NOTHING'; exit 3 }
$endMark = "`r`n      }`r`n    }`r`n  }`r`n}"
$j = $src.IndexOf($endMark, $i)
if ($j -lt 0) { Write-Output 'BLIND: could not find the builder block end marker in capture-run.ps1 - the fixture proved NOTHING'; exit 3 }
# through the pass-3 loop's OWN closing brace: CRLF + six spaces + '}' = 9 chars.
$block = $src.Substring($i, ($j - $i) + 9)

$sandbox = Join-Path $env:TEMP ('p4-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory (Join-Path $sandbox 'out\captures') -Force | Out-Null
New-Item -ItemType Directory (Join-Path $sandbox 'out\fareway')  -Force | Out-Null
New-Item -ItemType Directory (Join-Path $sandbox 'out\regular')  -Force | Out-Null
. 'C:\Codex\ThriftyCrew\grocery\fanout-lib.ps1'

$todayS = '2026-08-23'
$MaxParallel = 8
$Sequential = $false

# fake builders: each records that it ran, with the args it got
Set-Content (Join-Path $sandbox 'build-walmart-deals.ps1') -Value @'
param([string]$In,[string]$Date)
Start-Sleep -Milliseconds 400
Write-Output ("walmart built from " + $In + " for " + $Date)
exit 0
'@
Set-Content (Join-Path $sandbox 'build-sams-deals.ps1') -Value @'
param([string]$In,[string]$Date)
Start-Sleep -Milliseconds 400
Write-Output "sams builder is broken today"
exit 1
'@
Set-Content (Join-Path $sandbox 'select-fareway-shop.ps1') -Value @'
param([string]$In,[string]$Today)
Start-Sleep -Milliseconds 400
Write-Output ("fareway selected from " + $In + " for " + $Today)
exit 0
'@
Set-Content (Join-Path $sandbox 'build-fareway-regular.ps1') -Value @'
param([string]$Today,[string]$ModeVerified)
Write-Output "declining to shrink today's file"
exit 1
'@

# captures on disk: walmart, sams, fareway have one; aldi does not
Set-Content (Join-Path $sandbox "out\captures\walmart-capture-$todayS.csv") -Value 'x'
Set-Content (Join-Path $sandbox "out\captures\samsclub-capture-$todayS.csv") -Value 'x'
Set-Content (Join-Path $sandbox "out\fareway\fareway-shop-$todayS.jsonl")    -Value 'x'
# and fareway's out\regular file already holds rows captured today - the EVIDENCE path
(@{ deals = @(@{ as_of = "$todayS`T08:14:00" }, @{ as_of = "$todayS`T08:14:01" }) } | ConvertTo-Json -Depth 5) |
  Set-Content (Join-Path $sandbox "out\regular\fareway-regular-$todayS.json") -Encoding UTF8

$BROWSER_DRIVER_KEYS = @{ 'Walmart' = 'walmart'; "Sam's Club" = 'samsclub'; 'Fareway' = 'fareway'; 'Aldi' = 'aldi' }
$BROWSER_BUILDERS = @{
  'walmart'  = @{ Script = 'build-walmart-deals.ps1'; In = 'out\captures\walmart-capture-{0}.csv' }
  'samsclub' = @{ Script = 'build-sams-deals.ps1';    In = 'out\captures\samsclub-capture-{0}.csv' }
  'fareway'  = @{ Script = 'select-fareway-shop.ps1'; In = 'out\fareway\fareway-shop-{0}.jsonl'
                  Then = 'build-fareway-regular.ps1' }
}
$drivable = @('Walmart', "Sam's Club", 'Fareway', 'Aldi')
$browserUndone = @()
$failed = @()

# DOT-SOURCED, NOT CALLED. In production this block sits inline inside an if/else, and an
# if/else in PowerShell is NOT a new scope - so `$browserUndone += $s` and `$failed += ...`
# land on the script's own arrays. Invoking it with & would hand it a child scope, both
# appends would vanish into it, and the harness would report a bug production does not have.
# The extracted block resolves every path against $root, so $root IS the sandbox for the
# duration of the run. Saved and restored so the fixture cannot leave a stale value behind.
$scriptDir = $root
$root = $sandbox
$out = . ([scriptblock]::Create($block)) 3>&1 4>&1 | ForEach-Object { [string]$_ }

$root = $scriptDir
$n = 0; $bad = 0
function T([string]$w, [bool]$c, [string]$d = '') {
  $script:n++
  if ($c) { Write-Output ("  ok    " + $w) } else { $script:bad++; Write-Output ("  FAIL  " + $w + $(if ($d) { ' -> ' + $d } else { '' })) }
}
$joined = ($out -join ' | ')

T 'A  a store with a capture and a working builder actually built' ($joined -match 'walmart built from .*walmart-capture-2026-08-23\.csv for 2026-08-23')
T 'A  the builder was handed an ABSOLUTE -In path, not a relative one' ($joined -match ([regex]::Escape($sandbox)))
T 'B  a store with NO capture is outstanding and its builder never launched' (($browserUndone -contains 'Aldi') -and ($joined -notmatch 'aldi built'))
T 'B  a drivable store with no builder wired is NOT marked failed' (($failed -join ',') -notmatch 'aldi')
T 'C  a builder that exits non-zero is marked failed BY NAME' (($failed -contains 'build-samsclub'))
T 'C  a failed stage 1 does not run a stage 2' ($joined -notmatch 'samsclub.*second')
T 'D  fareway stage 2 ran after a clean stage 1' ($joined -match "declining to shrink today's file")
T 'D  stage 2 failure is judged on EVIDENCE, not the exit code' (($joined -match 'declined to rebuild .*already holds 2 row') -and ($failed -notcontains 'build2-fareway'))
T 'the successful stores are NOT in $failed' (($failed -notcontains 'build-walmart') -and ($failed -notcontains 'build-fareway'))
T 'output is emitted in LAUNCH order (walmart before samsclub before fareway)' `
  ($joined.IndexOf('walmart built') -lt $joined.IndexOf('sams builder is broken') -and $joined.IndexOf('sams builder is broken') -lt $joined.IndexOf('fareway selected'))

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output ("failed lanes: " + ($failed -join ', '))
Write-Output ("outstanding:  " + ($browserUndone -join ', '))
Write-Output ("SELFTEST: {0}/{1} pass" -f ($n - $bad), $n)
Write-Output ("CAPTURE-BUILDERS-COMPLETE cases={0} failed={1}" -f $n, $bad)
if ($bad -gt 0) { exit 1 }
exit 0
