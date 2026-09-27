<#
  golden-board-run.ps1 - build the board once, from one commit, over one frozen snapshot, in a scratch clone.

  WHY IT EXISTS (Brad's ruling, 2026-09-27, design\PLAN-split-giant-files-2026-09-27.md Decisions, "golden bar").
  A split of grocery\compare-deals.ps1 must not move one board cell, and compare-deals is not standalone
  (rules:grocery.md gr-04): a rebuild needs identity emission AND link repair. So one run here is:
    1. clone this repo into <Work>\g-<Tag> and check out -Commit (never the checkout you land from, og-47);
    2. mirror the frozen -Snapshot folder into its grocery\out (make it once with robocopy from a seeded grocery\out;
       the boards are gitignored, so an unseeded run prices nothing and proves nothing, gr-14);
    3. run compare-deals.ps1 with the daily chain's own arguments (-MinStores 1 -IdentityNamespace staple, plus the
       newest Baker's and Fareway files, as grocery\check-ad-cycles.ps1 passes them), then
       derive-links-from-prices.ps1 -Apply;
    4. write <Work>\hash-<Tag>.tsv: every file under the clone written since step 3 began, with its SHA-256.
  Compare two runs with ops\golden-board-compare.ps1. Two runs judged on the same day share the board DATE, which a
  board hash comparison needs ([[board-hash-acceptance-needs-the-same-board-date]]); run the two arms the same day.

  Usage: powershell -NoProfile -File ops\golden-board-run.ps1 -Commit <sha> -Tag <name> -Snapshot <dir> -Work <dir>
  Exit 0: both steps exited 0 and the run wrote files. 1: a step failed. 3: could not run (no snapshot, clone or
  checkout failed, or the run wrote nothing), never a pass. Last line GOLDEN-BOARD-RUN-COMPLETE.
  A run takes about 7 minutes and copies the snapshot (about 2.5 GB without browser-profiles and archive).

  Self-test: powershell -NoProfile -File ops\golden-board-run.ps1 -SelfTest (the written-file listing only).
#>
[CmdletBinding()]
param(
  [string]$Commit = '',
  [string]$Tag = '',
  [string]$Snapshot = '',
  [string]$Work = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Get-GoldenWrittenRows {
  <# "<path below Root>`t<SHA-256>" for every file under $Root last written at or after $Since, sorted, .git excluded. #>
  param([string]$Root, [datetime]$Since)
  $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
  $gitDir = $rootFull + '\.git\'
  $rows = foreach ($f in Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force) {
    if ($f.FullName.StartsWith($gitDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($f.LastWriteTime -lt $Since) { continue }
    $f.FullName.Substring($rootFull.Length + 1) + "`t" + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
  }
  return @($rows | Sort-Object)
}

if ($SelfTest) {
  $fail = 0; $n = 0
  function GbrCase([string]$label, [bool]$cond) {
    $script:n++
    if ($cond) { Write-Output ('  PASS  ' + $label) } else { Write-Output ('  FAIL  ' + $label); $script:fail++ }
  }
  $scratch = Join-Path ([IO.Path]::GetTempPath()) ('gbr-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'out'), (Join-Path $scratch '.git') -ErrorAction Stop | Out-Null
    $old = Join-Path $scratch 'out\old.json'; [IO.File]::WriteAllText($old, 'old')
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddHours(-1)
    $t0 = (Get-Date).AddMinutes(-1)
    [IO.File]::WriteAllText((Join-Path $scratch 'out\board.json'), 'new')
    [IO.File]::WriteAllText((Join-Path $scratch '.git\index'), 'git')
    $rows = Get-GoldenWrittenRows -Root $scratch -Since $t0
    GbrCase 'MUST FIRE  a file written after the run began is listed, with its path below the root' (@($rows | Where-Object { $_ -like "out\board.json`t*" }).Count -eq 1)
    GbrCase 'MUST NOT FIRE  a file last written before the run began is not listed' (@($rows | Where-Object { $_ -like 'out\old.json*' }).Count -eq 0)
    GbrCase 'MUST NOT FIRE  nothing under .git is listed' (@($rows | Where-Object { $_ -like '.git*' }).Count -eq 0)
    $expect = (Get-FileHash -LiteralPath (Join-Path $scratch 'out\board.json') -Algorithm SHA256).Hash
    GbrCase 'CLEAN TWIN  the listed hash is the file''s SHA-256' ((@($rows)[0]).Split("`t")[1] -eq $expect)
  } catch {
    $fail++; Write-Output ('  FAIL  unexpected error: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($n -ne 4) { $fail++; Write-Output ('  FAIL  expected 4 cases, ran ' + $n) }
  if ($fail) { Write-Output ("golden-board-run: self-test FAIL ($fail of $n)"); exit 1 }
  Write-Output ("golden-board-run: self-test pass ($n cases)")
  exit 0
}

function Stop-GoldenRun([int]$Code, [string]$Why) {
  Write-Output ('golden-board-run: ' + $Why)
  Write-Output ('GOLDEN-BOARD-RUN-COMPLETE tag=' + $Tag + ' exit=' + $Code)
  exit $Code
}
if (-not $Commit -or -not $Tag -or -not $Snapshot -or -not $Work) { Stop-GoldenRun 3 'COULD NOT RUN - usage: -Commit <sha> -Tag <name> -Snapshot <dir> -Work <dir>. Not a pass.' }
if (-not (Test-Path -LiteralPath $Snapshot -PathType Container)) { Stop-GoldenRun 3 ('COULD NOT RUN - no snapshot folder at ' + $Snapshot) }
$repo = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path $Work -ErrorAction Stop | Out-Null
$base = Join-Path $Work ('g-' + $Tag)
if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
git clone -q --no-checkout $repo $base
if ($LASTEXITCODE -ne 0) { Stop-GoldenRun 3 'COULD NOT RUN - git clone failed' }
git -C $base -c core.autocrlf=false checkout -q $Commit
if ($LASTEXITCODE -ne 0) { Stop-GoldenRun 3 ('COULD NOT RUN - checkout of ' + $Commit + ' failed') }
robocopy $Snapshot (Join-Path $base 'grocery\out') /MIR /NFL /NDL /NJH /NJS /R:1 /W:1 > (Join-Path $Work ('robo-' + $Tag + '.txt'))
if ($LASTEXITCODE -ge 8) { Stop-GoldenRun 3 ('COULD NOT RUN - robocopy of the snapshot exited ' + $LASTEXITCODE) }
Start-Sleep -Seconds 2   # the snapshot's own mtimes must fall strictly before t0
$t0 = Get-Date
$g = Join-Path $base 'grocery'
$od = Join-Path $g 'out'
$bakers = Get-ChildItem (Join-Path $od 'bakers\bakers-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$fareway = Get-ChildItem (Join-Path $od 'fareway\fareway-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$cmpArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $g 'compare-deals.ps1'), '-MinStores', '1', '-IdentityNamespace', 'staple')
if ($bakers) { $cmpArgs += @('-BakersFile', $bakers.FullName) }
if ($fareway) { $cmpArgs += @('-FarewayFile', $fareway.FullName) }
& powershell @cmpArgs > (Join-Path $Work ('cmp-' + $Tag + '.txt'))
$rcCompare = $LASTEXITCODE
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $g 'derive-links-from-prices.ps1') -Apply > (Join-Path $Work ('dl-' + $Tag + '.txt'))
$rcLinks = $LASTEXITCODE
$rows = Get-GoldenWrittenRows -Root $base -Since $t0
[IO.File]::WriteAllLines((Join-Path $Work ('hash-' + $Tag + '.tsv')), [string[]]$rows)
Write-Output ('golden-board-run: compare-deals rc=' + $rcCompare + ' derive-links rc=' + $rcLinks + ' written=' + @($rows).Count)
if (-not @($rows).Count) { Stop-GoldenRun 3 'the run wrote nothing - an unseeded or empty snapshot prices nothing' }
if ($rcCompare -ne 0 -or $rcLinks -ne 0) { Stop-GoldenRun 1 'a step exited non-zero' }
Stop-GoldenRun 0 'ok'
