<#
verify-gate-declaration.ps1 - prove a gate's `# gate-inputs:` declaration is COMPLETE before it is trusted to skip.

G1 of design\PLAN-faster-pushes-no-accuracy-loss-2026-09-25.md. Brad ruled 2026-09-26: no shadow period, live now. A
declaration lets run-gates reuse a pass whenever the declared bytes are unchanged, so an input the author forgot is a
stale pass waiting to happen. lib\gate-input-key.ps1 -VerifyDeclared proves each declared file MOVES the key; nothing
proved the list COMPLETE. This does, in place of the shadow period:

  1. KEYED: the gate is keyable with its declaration (Get-TcGateInputKey Ok), and every declared input moves the key
     (Test-TcGateDeclarationMoves Ok).
  2. SANDBOX: the key's own file list (the gate, what it loads, everything declared) is copied into an empty temp tree
     with nothing else of the repo, and the gate runs there. It runs again in the real checkout.
  3. SAME ANSWER: both arms exit the same, print the same verdict line, and print the same MULTISET of case lines
     (lines starting ok, pass, fail, skip, blind, digits folded to N, temp paths folded). A read of an undeclared file
     finds nothing in the sandbox, so it changes a case, fails the suite, or turns a case into a skip or blind line.
     A sandbox arm that prints any BLIND or SKIP line the real arm does not, or any 'blind=' above 0, is refused.

SCOPE OF A CLEAN REPORT: unsound. A gate that treats a missing file exactly as it treats the real one prints the same
cases in both arms and passes here. That shape is what a self-test with a must-fire case over that file cannot have,
which is the estate's own fixture rule; a verdict here says the declaration covered every read the suite's own cases
could see. A refusal is complete: the arms really differed, or the key really did not move.

Usage: powershell -File ops\verify-gate-declaration.ps1 -Gate <repo-relative path>[,<path>...] [-Arg -SelfTest]
Exit 0 every named gate verified, 1 at least one refused, 3 could not run. One line per gate, then
VERIFY-GATE-DECLARATION-COMPLETE gates=N verified=V refused=R.
#>
param([string]$Gate = '', [string]$Arg = '', [int]$TimeoutSec = 900, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\gate-input-key.ps1')
. (Join-Path $repo 'lib\selftest-verdict.ps1')

function Get-VgdPython {
  foreach ($c in @('C:\Codex\Python312\python.exe')) { if ([IO.File]::Exists($c)) { return $c } }
  return ''
}

function Invoke-VgdArm([string]$Root, [string]$Rel, [string]$GateArg, [int]$TimeoutSec) {
  $full = Join-Path $Root $Rel
  $isPy = $Rel -match '(?i)\.py$'
  $exe = $(if ($isPy) { Get-VgdPython } else { 'powershell.exe' })
  $argv = $(if ($isPy) { @(('"' + $full + '"'), $GateArg) } else { @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $full + '"'), $GateArg) })
  $stem = Join-Path $env:TEMP ('vgd-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $env:TC_GATE_TIMES_ROOT = 'off'
  $p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $Root -NoNewWindow -PassThru -RedirectStandardOutput ($stem + '.out') -RedirectStandardError ($stem + '.err')
  $null = $p.Handle
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { & taskkill /T /F /PID $p.Id *> $null } catch { }; $rc = -2 } else { $rc = $p.ExitCode }
  $out = @(); foreach ($x in @(($stem + '.out'), ($stem + '.err'))) { if ([IO.File]::Exists($x)) { $out += @([IO.File]::ReadAllLines($x)); Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } }
  return [pscustomobject]@{ Rc = $rc; Lines = $out }
}

function Get-VgdNorm([string]$Line, [string[]]$Roots) {
  $t = $Line.Trim()
  foreach ($r in $Roots) { if ($r) { $t = $t.Replace($r, '<ROOT>') } }
  $t = [regex]::Replace($t, '(?i)[a-z]:\\[^\s''"]*\\(Temp|tmp)\\[^\s''"]*', '<TMP>')
  $t = [regex]::Replace($t, '[0-9a-f]{7,64}', '<H>')
  return [regex]::Replace($t, '\d+', 'N')
}

function Get-VgdCases($Lines, [string[]]$Roots) {
  $c = @($Lines | Where-Object { "$_" -match '(?i)^\s*(ok|pass|passed|fail|failed|skip|skipped|blind)\b' } | ForEach-Object { Get-VgdNorm "$_" $Roots } | Sort-Object)
  return ,$c
}

function Test-VgdGate([string]$Repo, [string]$Rel, [string]$GateArg, [int]$TimeoutSec) {
  $gateFull = Join-Path $Repo $Rel
  $res = [ordered]@{ Gate = $Rel; Ok = $false; Why = '' }
  if (-not [IO.File]::Exists($gateFull)) { $res.Why = 'no such file'; return [pscustomobject]$res }
  $src = [IO.File]::ReadAllText($gateFull)
  $dI = Get-TcGateDeclaredInputs -Text $src; $dT = Get-TcGateDeclaredTextInputs -Text $src
  $dN = @($dI | Where-Object { $_ }).Count + @($dT | Where-Object { $_ }).Count
  if (-not $dN) { $res.Why = 'declares nothing'; return [pscustomobject]$res }
  if (-not $GateArg) { $GateArg = $(if ($Rel -match '(?i)\.py$') { '--selftest' } else { '-SelfTest' }) }
  $k = Get-TcGateInputKey -Repo $Repo -GateFile $gateFull -GateArg $GateArg
  if (-not $k.Ok) { $res.Why = ('not keyable: ' + $k.Why); return [pscustomobject]$res }
  if ($Rel -match '(?i)\.ps1$') {
    $mv = Test-TcGateDeclarationMoves -Repo $Repo -GateFile $gateFull
    if (-not $mv.Ok) { $res.Why = ('declaration does not move the key: ' + $mv.Why); return [pscustomobject]$res }
  }
  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  $sb = Join-Path $env:TEMP ('vgd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    foreach ($f in @($k.Files)) {
      $ff = [IO.Path]::GetFullPath([string]$f)
      if (-not $ff.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
      $dst = Join-Path $sb $ff.Substring($repoFull.Length + 1)
      $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) -ErrorAction Stop
      [IO.File]::Copy($ff, $dst, $true)
    }
    $real = Invoke-VgdArm $Repo $Rel $GateArg $TimeoutSec
    $box = Invoke-VgdArm $sb $Rel $GateArg $TimeoutSec
    $roots = @($repoFull, $sb)
    $rv = Get-TcSelfTestVerdict -Lines $real.Lines; $bv = Get-TcSelfTestVerdict -Lines $box.Lines
    $rc = Get-VgdCases $real.Lines $roots; $bc = Get-VgdCases $box.Lines $roots
    if ($real.Rc -ne 0) { $res.Why = ('the real arm is not green (exit ' + $real.Rc + '); only a passing gate can be cached'); return [pscustomobject]$res }
    if ($box.Rc -ne $real.Rc) { $res.Why = ('sandbox exit ' + $box.Rc + ' vs real ' + $real.Rc + ': it reads something undeclared. Last sandbox lines: ' + ((@($box.Lines) | Select-Object -Last 3) -join ' | ')); return [pscustomobject]$res }
    if ((Get-VgdNorm ([string]$rv.Line) $roots) -cne (Get-VgdNorm ([string]$bv.Line) $roots)) { $res.Why = ('verdict differs: real "' + $rv.Line + '" sandbox "' + $bv.Line + '"'); return [pscustomobject]$res }
    if ($rc.Count -ne $bc.Count -or (@(Compare-Object $rc $bc -CaseSensitive).Count)) {
      $d = @(Compare-Object $rc $bc -CaseSensitive | Select-Object -First 3 | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject })
      $res.Why = ('case lines differ (' + $rc.Count + ' real, ' + $bc.Count + ' sandbox): ' + ($d -join ' || ')); return [pscustomobject]$res
    }
    if (-not $rc.Count -and -not $rv.Found) { $res.Why = 'no case lines and no verdict to compare, so the sandbox proves nothing'; return [pscustomobject]$res }
    $bl = @($box.Lines | Where-Object { "$_" -match '\bblind=[1-9]' })
    if ($bl.Count) { $res.Why = ('sandbox arm reports blind: ' + $bl[0]); return [pscustomobject]$res }
    $res.Ok = $true; $res.Why = ('same exit, verdict and ' + $rc.Count + ' case line(s) with only the ' + @($k.Files).Count + ' keyed file(s) present')
    return [pscustomobject]$res
  } finally {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($SelfTest) {
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  $script:vp = 0; $script:vf = 0
  function T([string]$m, [bool]$c, [string]$got) { if ($c) { $script:vp++; Write-Output ('ok    ' + $m) } else { $script:vf++; Write-Output ('FAIL  ' + $m + '   got: ' + $got) } }
  $fx = Join-Path $env:TEMP ('vgdst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $fx 'lib'), (Join-Path $fx 'data') -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $repo 'lib\gate-input-key.ps1'), (Join-Path $repo 'lib\selftest-verdict.ps1') -Destination (Join-Path $fx 'lib')
    [IO.File]::WriteAllText((Join-Path $fx 'data\rules.txt'), 'alpha')
    $rd = "`$r = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent `$PSScriptRoot) ('data\' + 'rules.txt')))`nif (`$r -eq 'alpha') { Write-Output 'ok    CLEAN TWIN reads alpha' } else { Write-Output 'FAIL  reads alpha' ; Write-Output 'fx self-test FAIL'; exit 1 }`nWrite-Output 'fx self-test PASS: 1 case'`nexit 0`n"
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $fx 'ops')
    [IO.File]::WriteAllText((Join-Path $fx 'ops\good.ps1'), ("# gate-inputs: data\rules.txt`n" + $rd))
    [IO.File]::WriteAllText((Join-Path $fx 'ops\forgot.ps1'), ("# gate-inputs: lib\selftest-verdict.ps1`n" + $rd))
    [IO.File]::WriteAllText((Join-Path $fx 'ops\none.ps1'), $rd)
    $g = Test-VgdGate -Repo $fx -Rel 'ops\good.ps1' -GateArg '-SelfTest' -TimeoutSec 120
    T ($kCT + '  a declaration naming the one file the gate reads verifies (same exit, verdict and cases in the sandbox)') ([bool]$g.Ok) ([string]$g.Why)
    $b = Test-VgdGate -Repo $fx -Rel 'ops\forgot.ps1' -GateArg '-SelfTest' -TimeoutSec 120
    T ($kMF + '  a declaration that FORGOT the file the gate reads is refused: the sandbox arm cannot find it and goes red') ((-not $b.Ok) -and ([string]$b.Why -match 'sandbox exit')) ([string]$b.Why)
    $n = Test-VgdGate -Repo $fx -Rel 'ops\none.ps1' -GateArg '-SelfTest' -TimeoutSec 120
    T ($kMNF + '  a gate with no declaration is not verified as if it had one') ((-not $n.Ok) -and ([string]$n.Why -ceq 'declares nothing')) ([string]$n.Why)
  } finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
  if (($script:vp + $script:vf) -ne 3) { $script:vf++; Write-Output ('FAIL  ran ' + ($script:vp + $script:vf) + ' case(s) where this file holds 3') }
  if ($script:vf) { Write-Output ('verify-gate-declaration self-test FAIL: ' + $script:vf + ' of ' + ($script:vp + $script:vf)); exit 1 }
  Write-Output ('verify-gate-declaration self-test PASS: ' + $script:vp + ' cases')
  exit 0
}

if (-not $Gate) { Write-Output 'verify-gate-declaration: -Gate <repo-relative path>[,...] is required'; Write-Output 'VERIFY-GATE-DECLARATION-COMPLETE gates=0 verified=0 refused=0 code=3'; exit 3 }
$list = @($Gate -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ver = 0; $ref = 0
foreach ($g in $list) {
  $r = Test-VgdGate -Repo $repo -Rel ($g -replace '/', '\') -GateArg $Arg -TimeoutSec $TimeoutSec
  if ($r.Ok) { $ver++; Write-Output ('VERIFIED  ' + $r.Gate + '  ' + $r.Why) } else { $ref++; Write-Output ('REFUSED   ' + $r.Gate + '  ' + $r.Why) }
}
Write-Output ('VERIFY-GATE-DECLARATION-COMPLETE gates={0} verified={1} refused={2}' -f $list.Count, $ver, $ref)
if ($ref) { exit 1 } else { exit 0 }
