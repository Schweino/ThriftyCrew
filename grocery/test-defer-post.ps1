<#
  test-defer-post.ps1 - fixtures for the -DeferPost road of check-ad-cycles (Invoke-DeferPostBuild, publish-outcome-lib.ps1).

  THE FOUNDING DEFECT (2026-09-28, design/PLAN-deferpost-builds-board-2026-09-28.md W4). Under -DeferPost the chain hashed
  whatever public\board.json was already on disk and built nothing, so capture-run committed and edge-verified yesterday's
  board and its deferred publish then held rc 2 on a ?v= the edge did not serve (2026-09-23 and 2026-09-28).

  Each case runs the LIVE function in a per-run temp tree whose publish-deals-page.ps1 is a stub builder: it writes
  public\board.json from the newest comparison and prints the BUILT line. The stub stands in for the builder, so these
  cases prove the WIRING the function owns (build first, then hash what was built); the builder's own determinism was
  measured separately (three builds over comparison-2026-09-28 in a seeded scratch clone, one SHA-256).
    CLEAN TWIN  the board is rebuilt from today's comparison and post-deferred.json names exactly that board and input
    MUST FIRE   with the build call removed from the live function, the check sees yesterday's board left in place
    WIRING      check-ad-cycles' -DeferPost branch calls the function
  SCOPE OF A CLEAN REPORT: unsound for the real builder (a stub stands in); sound for the order build-then-hash.
  Run: test-defer-post.ps1 -SelfTest     (exit 0 clean, 1 on any failure; the switch is declared so run-gates finds it)
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# gate-inputs: grocery\test-defer-post.ps1, grocery\publish-outcome-lib.ps1
# gate-inputs-text: grocery\check-ad-cycles.ps1
$libSrc = [IO.File]::ReadAllText((Join-Path $here 'publish-outcome-lib.ps1'))
$cacSrc = [IO.File]::ReadAllText((Join-Path $here 'check-ad-cycles.ps1'))
$script:pass = 0; $script:fail = 0
function Pass([string]$m) { Write-Output ('  PASS  ' + $m); $script:pass++ }
function Flunk([string]$m) { Write-Output ('  FAIL  ' + $m); $script:fail++ }
function Log($m) { }
function Send-Alert { param($Subject, $Body) }
function Get-DpSha([string]$f) { $h = [System.Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($h.ComputeHash([IO.File]::ReadAllBytes($f))) -replace '-', '') } finally { $h.Dispose() } }
function New-DpTree {
  $t = Join-Path ([System.IO.Path]::GetTempPath()) ('dpb-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path (Join-Path $t 'grocery\out') -Force -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $t 'public') -Force -ErrorAction Stop | Out-Null
  # yesterday's served board, and today's comparison that moved bacon at Fareway (3.95 -> 1.596, the 2026-09-28 row)
  [IO.File]::WriteAllText((Join-Path $t 'public\board.json'), '{"bacon":{"Fareway":3.95}}')
  [IO.File]::WriteAllText((Join-Path $t 'grocery\out\comparison-2026-09-28.json'), '{"bacon":{"Fareway":1.596}}')
  $stub = @(
    'param([switch]$BuildOnly)',
    '$c = Get-ChildItem (Join-Path $PSScriptRoot ''out\comparison-*.json'') | Sort-Object Name -Descending | Select-Object -First 1',
    '$b = Join-Path (Split-Path $PSScriptRoot -Parent) ''public\board.json''',
    '[IO.File]::WriteAllText($b, [IO.File]::ReadAllText($c.FullName))',
    '$h = [System.Security.Cryptography.SHA256]::Create(); $s = ([BitConverter]::ToString($h.ComputeHash([IO.File]::ReadAllBytes($b))) -replace ''-'', '''')',
    'Write-Output (''BUILT board.json sha256='' + $s + '' compare='' + $c.FullName)',
    'exit 0')
  [IO.File]::WriteAllText((Join-Path $t 'grocery\publish-deals-page.ps1'), ($stub -join "`n"))
  return $t
}
# The checker: is the served board today's comparison, and does the deferral name exactly that board and its input?
function Test-DeferBuiltBoard([string]$tree) {
  $f = New-Object System.Collections.Generic.List[string]
  $board = Join-Path $tree 'public\board.json'
  $cmp = Join-Path $tree 'grocery\out\comparison-2026-09-28.json'
  if (-not [string]::Equals([IO.File]::ReadAllText($board), [IO.File]::ReadAllText($cmp), [StringComparison]::Ordinal)) { $f.Add('public\board.json was not rebuilt from today''s comparison - the caller would commit yesterday''s board') }
  $pdF = Join-Path $tree 'grocery\out\post-deferred.json'
  if (-not (Test-Path -LiteralPath $pdF)) { $f.Add('no post-deferred.json was written') }
  else {
    $pd = [IO.File]::ReadAllText($pdF) | ConvertFrom-Json
    if (-not [string]::Equals([string]$pd.board_sha256, (Get-DpSha $board), [StringComparison]::OrdinalIgnoreCase)) { $f.Add('post-deferred.json board_sha256 does not name the board on disk') }
    if (-not [string]::Equals([string]$pd.compare_file, $cmp, [StringComparison]::OrdinalIgnoreCase)) { $f.Add('post-deferred.json compare_file is not the file the build used') }
  }
  return ,$f.ToArray()
}
function Invoke-DpCase([string]$src, [string]$tree) {
  . ([scriptblock]::Create($src))
  $root = Join-Path $tree 'grocery'
  return (Invoke-DeferPostBuild -Root $root -OutDir (Join-Path $root 'out') -AsOf '2026-09-28' -Sig 'SIG-0928' -SigFile (Join-Path $root 'out\published-board.sig') -GuardsRc 0 -NoAlert)
}

$trees = @()
try {
  # WIRING: the -DeferPost branch calls the function (needles concatenated so this file cannot match itself).
  $brAt = $cacSrc.IndexOf('elseif ($Defer' + 'Post -and -not $NoPublish) {')
  $callAt = if ($brAt -ge 0) { $cacSrc.IndexOf('Invoke-Defer' + 'PostBuild -Root', $brAt) } else { -1 }
  $nextAt = if ($brAt -ge 0) { $cacSrc.IndexOf('elseif (-not $No' + 'Publish) {', $brAt) } else { -1 }
  if ($brAt -ge 0 -and $callAt -gt $brAt -and ($nextAt -lt 0 -or $callAt -lt $nextAt)) { Pass 'WIRING  check-ad-cycles'' -DeferPost branch calls Invoke-DeferPostBuild' }
  else { Flunk 'WIRING  the -DeferPost branch of check-ad-cycles does not call Invoke-DeferPostBuild - the deferred road would hash yesterday''s board again' }

  # CLEAN TWIN: the live function builds first, so the board is today's and the deferral names that board and its input.
  $t1 = New-DpTree; $trees += $t1
  $r1 = Invoke-DpCase $libSrc $t1
  $f1 = Test-DeferBuiltBoard $t1
  if ($r1.Rc -eq 0 -and $f1.Count -eq 0 -and ((@($r1.Summary) -join ' ') -match 'board rebuilt')) {
    Pass 'CLEAN TWIN  under -DeferPost the board is rebuilt from today''s comparison and post-deferred.json board_sha256 names exactly that board and its compare_file'
  } else { Flunk ('CLEAN TWIN  the live function does not defer the board it built (rc=' + $r1.Rc + '): [' + ($f1 -join '; ') + ']') }

  # MUST FIRE: the 2026-09-28 defect, made by deleting the build call from the LIVE function (a literal .Replace).
  $needle = '& powershell -ExecutionPolicy Bypass -File (Join-Path $Root ''publish-deals-page.ps1'') -Build' + 'Only'
  $broke = $libSrc.Replace($needle, '''BUILT board.json sha256=0 compare=''; $global:LASTEXITCODE = 0')
  if ([string]::Equals($broke, $libSrc, [StringComparison]::Ordinal)) { Flunk 'MUST FIRE  the mutant could not be made: the build call in Invoke-DeferPostBuild no longer reads as the needle, so this case examined nothing' }
  else {
    $t2 = New-DpTree; $trees += $t2
    $null = Invoke-DpCase $broke $t2
    $f2 = Test-DeferBuiltBoard $t2
    if (($f2 -join ' ') -match 'was not rebuilt') { Pass 'MUST FIRE  with the build removed, a changed comparison under -DeferPost leaves public\board.json at yesterday''s board and the check names it (the 2026-09-28 defect)' }
    else { Flunk ('MUST FIRE  the checker did not fire on the build-less function: [' + ($f2 -join '; ') + ']') }
  }
} catch { Flunk ('the fixture threw - ' + $_.Exception.Message) }
finally { foreach ($d in $trees) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }

$ran = $script:pass + $script:fail
if ($ran -ne 3) { Flunk ('expected 3 cases, ran ' + $ran) }
if ($script:fail) { Write-Output ('test-defer-post SELF-TEST FAIL (' + $script:fail + ' of ' + $ran + ' case(s) failed)'); exit 1 }
Write-Output ('test-defer-post SELF-TEST PASS (' + $script:pass + ' of ' + $ran + ' case(s))')
exit 0
