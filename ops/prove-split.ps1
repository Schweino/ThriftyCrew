<#
  prove-split.ps1 - prove that splitting a script into pieces MOVED code and changed nothing.

  WHY IT EXISTS (Brad's ruling D5, 2026-09-27, design\PLAN-split-giant-files-2026-09-27.md section 6). The four
  largest scripts are being cut into subfolders (grocery\test-auditors\ first), about twenty extractions in all, and
  every one owes the same two proofs. By hand they are a procedure; here they are one command with a self-test.

  Two proofs, each its own mode:
    -Snapshot -Paths <a.ps1,b.ps1,...> -Out <file.json>
        Parse each file with PowerShell's own parser and record every function definition, nested ones included, as
        (name, SHA-256 of the definition's exact text, file). Run it once before the cut over the host, and once after
        over the host plus every new piece.
    -CompareFunctions -Before <snap.json> -After <snap.json>
        The two MULTISETS of (name, hash) must be equal. The file column is ignored: that is the only thing a move may
        change. A body that changed by one byte, a function that vanished, or one that appeared, is a difference.
    -CompareGolden -Before <out.txt> -After <out.txt> [-Root <checkout>] [-Sorted]
        Two captured runs of the host must print the same lines once run-to-run noise is normalised: durations
        (12.3s, 450ms), ISO timestamps and clock times, temp paths under %TEMP%, and the checkout root. -Sorted compares
        the lines as a multiset, for a host whose parallel fan-outs interleave in a different order each run; without
        it the order must match too.

  Exit 0: identical. 1: a difference, each one printed. 3: could not evaluate (a file missing, unparseable or empty),
  never a pass. The last line is PROVE-SPLIT-COMPLETE with the verdict and the counts it compared.

  SCOPE OF A CLEAN REPORT: SOUND for what it compares (every function body is hashed whole, every normalised output
  line is compared), UNSOUND beyond it: code outside any function is not hashed (compare the logical text for that),
  and a normalisation rule can hide a real difference that happens to look like a duration, a time or a temp path.
  A reported difference is COMPLETE: the bytes differ.

  Self-test: powershell -File ops\prove-split.ps1 -SelfTest
#>
[CmdletBinding()]
param(
  [switch]$Snapshot,
  [string[]]$Paths = @(),
  [string]$Out = '',
  [switch]$CompareFunctions,
  [switch]$CompareGolden,
  [string]$Before = '',
  [string]$After = '',
  [string]$Root = '',
  [switch]$Sorted,
  [switch]$SelfTest
)

function Get-PsFunctionHashes {
  <# Every function definition in $Path, nested included: name, SHA-256 of its exact text, and the file.
     Throws on a missing or unparseable file, which the caller turns into exit 3. #>
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "no such file: $Path" }
  $errs = $null; $tok = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Path).ProviderPath, [ref]$tok, [ref]$errs)
  if ($errs -and $errs.Count) { throw ("does not parse: " + $Path + " (" + $errs[0].Message + ")") }
  $sha = [Security.Cryptography.SHA256]::Create()
  $rows = New-Object System.Collections.ArrayList
  foreach ($fd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($fd.Extent.Text -replace "`r`n", "`n"))
    $h = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    [void]$rows.Add([pscustomobject]@{ name = $fd.Name; hash = $h; file = $Path; line = $fd.Extent.StartLineNumber })
  }
  return ,($rows.ToArray())
}

function Compare-FunctionSets {
  <# Multiset difference of (name, hash). Returns the rows present on one side more often than on the other. #>
  param($BeforeRows, $AfterRows)
  $count = @{}
  foreach ($r in @($BeforeRows)) { $k = $r.name + "`t" + $r.hash; $count[$k] = [int]$count[$k] + 1 }
  foreach ($r in @($AfterRows)) { $k = $r.name + "`t" + $r.hash; $count[$k] = [int]$count[$k] - 1 }
  $diff = New-Object System.Collections.ArrayList
  foreach ($k in @($count.Keys | Sort-Object)) {
    $n = [int]$count[$k]
    if ($n -eq 0) { continue }
    $name = $k.Split("`t")[0]
    $side = if ($n -gt 0) { 'only-before' } else { 'only-after' }
    [void]$diff.Add([pscustomobject]@{ side = $side; name = $name; hash = $k.Split("`t")[1]; times = [Math]::Abs($n) })
  }
  return ,($diff.ToArray())
}

function ConvertTo-GoldenLine {
  <# One output line with run-to-run noise replaced by fixed tokens. Order matters: paths before numbers. #>
  param([string]$Line, [string]$RootFull = '')
  $l = $Line.TrimEnd()
  if ($RootFull) { $l = $l.Replace($RootFull, '<ROOT>').Replace($RootFull.Replace('\', '/'), '<ROOT>') }
  $tmp = [IO.Path]::GetTempPath().TrimEnd('\')
  $l = [regex]::Replace($l, [regex]::Escape($tmp) + '\\[^\s''"`,;)\]]*', '<TEMP>', 'IgnoreCase')
  $l = [regex]::Replace($l, '(?i)[A-Z]:\\Users\\[^\\\s]+\\AppData\\Local\\Temp\\[^\s''"`,;)\]]*', '<TEMP>')
  $l = [regex]::Replace($l, '\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?', '<TS>')
  $l = [regex]::Replace($l, '\b\d{1,2}:\d{2}:\d{2}(\.\d+)?\b', '<TIME>')
  $l = [regex]::Replace($l, '\b\d+(\.\d+)?\s?(ms|s|sec|secs|seconds)\b', '<DUR>')
  return $l
}

function Compare-GoldenText {
  <# Normalised line comparison. Returns the differing pairs (in order) or, with -Sorted, the multiset surplus. #>
  param([string[]]$BeforeLines, [string[]]$AfterLines, [string]$RootFull = '', [bool]$AsMultiset = $false)
  $b = @(@($BeforeLines) | ForEach-Object { ConvertTo-GoldenLine -Line ([string]$_) -RootFull $RootFull } | Where-Object { $_ -ne '' })
  $a = @(@($AfterLines) | ForEach-Object { ConvertTo-GoldenLine -Line ([string]$_) -RootFull $RootFull } | Where-Object { $_ -ne '' })
  $diff = New-Object System.Collections.ArrayList
  if ($AsMultiset) {
    $count = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    foreach ($x in $b) { if ($count.ContainsKey($x)) { $count[$x]++ } else { $count[$x] = 1 } }
    foreach ($x in $a) { if ($count.ContainsKey($x)) { $count[$x]-- } else { $count[$x] = -1 } }
    foreach ($k in $count.Keys) { if ($count[$k] -ne 0) { [void]$diff.Add([pscustomobject]@{ at = 0; before = $(if ($count[$k] -gt 0) { $k } else { '' }); after = $(if ($count[$k] -lt 0) { $k } else { '' }) }) } }
  } else {
    $n = [Math]::Max($b.Count, $a.Count)
    for ($i = 0; $i -lt $n; $i++) {
      $x = if ($i -lt $b.Count) { $b[$i] } else { '<missing>' }
      $y = if ($i -lt $a.Count) { $a[$i] } else { '<missing>' }
      if (-not [string]::Equals($x, $y, [StringComparison]::Ordinal)) { [void]$diff.Add([pscustomobject]@{ at = $i + 1; before = $x; after = $y }) }
    }
  }
  return [pscustomobject]@{ diff = $diff.ToArray(); before = $b.Count; after = $a.Count }
}

if ($SelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:psFail = 0; $script:psCases = 0
  function Assert-PsCase([string]$Label, [string]$What, [bool]$Ok, [string]$Got = '') {
    $script:psCases++
    if ($Ok) { Write-Output ('  PASS  ' + $Label + '  ' + $What) } else { Write-Output ('  FAIL  ' + $Label + '  ' + $What + '   got: ' + $Got); $script:psFail++ }
  }
  $psDir = Join-Path ([IO.Path]::GetTempPath()) ('tc-ps-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    try {
      [void](New-Item -ItemType Directory -Path (Join-Path $psDir 'host') -Force -ErrorAction Stop)
      $u8 = New-Object Text.UTF8Encoding($false)
      $fnA = "function Get-A {`n  param(`$x)`n  function Log(`$m) { `$m }`n  return `$x + 1`n}`n"
      $fnB = "function Get-B { 'b' }`n"
      $fnC = "function Get-C { 'c' }`n"
      [IO.File]::WriteAllText((Join-Path $psDir 'whole.ps1'), ($fnA + "`$top = 1`n" + $fnB + $fnC), $u8)
      [IO.File]::WriteAllText((Join-Path $psDir 'entry.ps1'), ($fnA + "`$top = 1`n. (Join-Path `$PSScriptRoot 'host\piece.ps1')`n"), $u8)
      [IO.File]::WriteAllText((Join-Path $psDir 'host\piece.ps1'), ($fnB + $fnC), $u8)
      [IO.File]::WriteAllText((Join-Path $psDir 'host\edited.ps1'), ($fnB + "function Get-C { 'C' }`n"), $u8)
      [IO.File]::WriteAllText((Join-Path $psDir 'host\dropped.ps1'), $fnB, $u8)

      $rWhole = Get-PsFunctionHashes -Path (Join-Path $psDir 'whole.ps1')
      Assert-PsCase 'CLEAN TWIN' 'every definition is found, a nested function Log included (4 in the host)' ($rWhole.Count -eq 4) ('count=' + $rWhole.Count)
      $rEntry = Get-PsFunctionHashes -Path (Join-Path $psDir 'entry.ps1')
      $rPiece = Get-PsFunctionHashes -Path (Join-Path $psDir 'host\piece.ps1')
      $rEdited = Get-PsFunctionHashes -Path (Join-Path $psDir 'host\edited.ps1')
      $rDropped = Get-PsFunctionHashes -Path (Join-Path $psDir 'host\dropped.ps1')
      $movedRows = @($rEntry) + @($rPiece)
      $d0 = Compare-FunctionSets -BeforeRows $rWhole -AfterRows $movedRows
      Assert-PsCase 'MUST NOT FIRE' 'a pure MOVE of two functions into a piece: the function multiset is equal, only the file differs' (@($d0).Count -eq 0) ('diff=' + (@($d0 | ForEach-Object { $_.side + ':' + $_.name }) -join ','))
      $editRows = @($rEntry) + @($rEdited)
      $d1 = Compare-FunctionSets -BeforeRows $rWhole -AfterRows $editRows
      Assert-PsCase 'MUST FIRE' 'a body changed by one character on the way (c -> C) is a difference on both sides, named' ((@($d1).Count -eq 2) -and (@($d1 | Where-Object { $_.name -eq 'Get-C' }).Count -eq 2)) ('diff=' + (@($d1 | ForEach-Object { $_.side + ':' + $_.name }) -join ','))
      $dropRows = @($rEntry) + @($rDropped)
      $d2 = Compare-FunctionSets -BeforeRows $rWhole -AfterRows $dropRows
      Assert-PsCase 'MUST FIRE' 'a function left behind by the cut (Get-C in neither file) is a difference' ((@($d2).Count -eq 1) -and ($d2[0].side -eq 'only-before') -and ($d2[0].name -eq 'Get-C')) ('diff=' + (@($d2 | ForEach-Object { $_.side + ':' + $_.name }) -join ','))
      $dupRows = @($movedRows) + @($rDropped)
      $d3 = Compare-FunctionSets -BeforeRows $rWhole -AfterRows $dupRows
      Assert-PsCase 'MUST FIRE' 'a function COPIED rather than moved (Get-B twice after) is a difference: the sets are multisets' ((@($d3).Count -eq 1) -and ($d3[0].side -eq 'only-after') -and ($d3[0].name -eq 'Get-B')) ('diff=' + (@($d3 | ForEach-Object { $_.side + ':' + $_.name }) -join ','))
      $threw = $false
      [IO.File]::WriteAllText((Join-Path $psDir 'broken.ps1'), "function X { `n", $u8)
      try { $null = Get-PsFunctionHashes -Path (Join-Path $psDir 'broken.ps1') } catch { $threw = $true }
      Assert-PsCase 'MUST FIRE' 'a file that does not parse throws (could not evaluate), never an empty set that compares equal' $threw

      $tmp = [IO.Path]::GetTempPath().TrimEnd('\')
      $g1 = @('  PASS  u001 board read in 12.4s', ('  PASS  sandbox at ' + $tmp + '\tc-fx-a1b2c3\x.json ok'), 'run started 2026-09-27T10:11:12.345-05:00', 'at 10:11:12 done', 'C:\root\wt\grocery\a.ps1 ok', 'TEST-AUDITORS-COMPLETE pass=3 fail=0')
      $g2 = @('  PASS  u001 board read in 9.1s', ('  PASS  sandbox at ' + $tmp + '\tc-fx-ffee99\x.json ok'), 'run started 2026-09-28T01:02:03.001-05:00', 'at 01:02:03 done', 'C:\root\wt2\grocery\a.ps1 ok', 'TEST-AUDITORS-COMPLETE pass=3 fail=0')
      $g2 = @($g2 | ForEach-Object { $_.Replace('C:\root\wt2', 'C:\root\wt') })
      $c0 = Compare-GoldenText -BeforeLines $g1 -AfterLines $g2 -RootFull 'C:\root\wt'
      Assert-PsCase 'MUST NOT FIRE' 'two runs differing only in a duration, a temp path, a timestamp and a clock time are identical' (@($c0.diff).Count -eq 0) ('diff=' + (@($c0.diff | ForEach-Object { $_.before + ' | ' + $_.after }) -join ' ;; '))
      $g3 = @($g2 | ForEach-Object { $_.Replace('  PASS  u001', '  FAIL  u001') })
      $c1 = Compare-GoldenText -BeforeLines $g1 -AfterLines $g3 -RootFull 'C:\root\wt'
      Assert-PsCase 'MUST FIRE' 'a case that turned PASS into FAIL is a difference at its line' ((@($c1.diff).Count -eq 1) -and ($c1.diff[0].at -eq 1)) ('diff=' + @($c1.diff).Count)
      $g4 = @($g2 | ForEach-Object { $_.Replace('pass=3', 'pass=2') })
      $c2 = Compare-GoldenText -BeforeLines $g1 -AfterLines $g4 -RootFull 'C:\root\wt'
      Assert-PsCase 'MUST FIRE' 'a changed tally (pass=3 -> pass=2) is not normalised away' (@($c2.diff).Count -eq 1) ('diff=' + @($c2.diff).Count)
      $g5 = @($g2[1], $g2[0]) + @($g2[2..5])
      $c3 = Compare-GoldenText -BeforeLines $g1 -AfterLines $g5 -RootFull 'C:\root\wt'
      $c4 = Compare-GoldenText -BeforeLines $g1 -AfterLines $g5 -RootFull 'C:\root\wt' -AsMultiset $true
      Assert-PsCase 'MUST FIRE' 'a reordered run is a difference when order is compared' (@($c3.diff).Count -gt 0) ('ordered=' + @($c3.diff).Count)
      Assert-PsCase 'MUST NOT FIRE' 'the same reordered run is identical as a multiset (-Sorted)' (@($c4.diff).Count -eq 0) ('multiset=' + @($c4.diff).Count)
      $g6 = @($g2) + @('  PASS  u002 extra case')
      $c5 = Compare-GoldenText -BeforeLines $g1 -AfterLines $g6 -RootFull 'C:\root\wt' -AsMultiset $true
      Assert-PsCase 'MUST FIRE' 'an extra line after the cut is a difference even as a multiset' (@($c5.diff).Count -eq 1) ('diff=' + @($c5.diff).Count)
    } catch {
      Assert-PsCase 'MUST FIRE' 'the self-test ran to the end without throwing' $false $_.Exception.Message
    }
  } finally {
    Remove-Item -LiteralPath $psDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $psExpected = 12
  if ($script:psCases -ne $psExpected) { Write-Output ('  FAIL  ran ' + $script:psCases + ' case(s), the list holds ' + $psExpected); $script:psFail++ }
  if ($script:psFail) { Write-Output ('PROVE-SPLIT SELF-TEST FAIL (' + $script:psFail + ' of ' + $script:psCases + ')'); exit 1 }
  Write-Output ('PROVE-SPLIT SELF-TEST PASS (' + $script:psCases + ' cases)')
  exit 0
}

$ErrorActionPreference = 'Stop'
try {
  if ($Snapshot) {
    if (-not @($Paths).Count -or -not $Out) { throw 'usage: -Snapshot -Paths <a.ps1,b.ps1> -Out <file.json>' }
    $rows = New-Object System.Collections.ArrayList
    foreach ($p in @($Paths | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) {
      $r = Get-PsFunctionHashes -Path $p
      foreach ($x in @($r)) { [void]$rows.Add($x) }
    }
    if (-not $rows.Count) { throw 'no function definition found in any of the paths: nothing to prove' }
    [IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 3), (New-Object Text.UTF8Encoding($false)))
    Write-Output ('PROVE-SPLIT-COMPLETE snapshot functions=' + $rows.Count + ' files=' + @($Paths).Count + ' out=' + $Out)
    exit 0
  }
  if ($CompareFunctions) {
    if (-not (Test-Path -LiteralPath $Before) -or -not (Test-Path -LiteralPath $After)) { throw 'usage: -CompareFunctions -Before <snap.json> -After <snap.json> (both must exist)' }
    $b = [IO.File]::ReadAllText($Before) | ConvertFrom-Json
    $a = [IO.File]::ReadAllText($After) | ConvertFrom-Json
    $b = @($b); $a = @($a)
    if (-not $b.Count -or -not $a.Count) { throw 'an empty snapshot proves nothing' }
    $d = Compare-FunctionSets -BeforeRows $b -AfterRows $a
    foreach ($x in @($d)) { Write-Output ('FUNCTION-DIFF ' + $x.side + ' ' + $x.name + ' x' + $x.times + ' ' + $x.hash.Substring(0, 12)) }
    $v = if (@($d).Count) { 'differ' } else { 'identical' }
    Write-Output ('PROVE-SPLIT-COMPLETE functions ' + $v + ' before=' + $b.Count + ' after=' + $a.Count + ' diff=' + @($d).Count)
    if (@($d).Count) { exit 1 } else { exit 0 }
  }
  if ($CompareGolden) {
    if (-not (Test-Path -LiteralPath $Before) -or -not (Test-Path -LiteralPath $After)) { throw 'usage: -CompareGolden -Before <out.txt> -After <out.txt> [-Root <dir>] [-Sorted] (both must exist)' }
    $rootFull = if ($Root) { (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\') } else { '' }
    $bl = [IO.File]::ReadAllLines($Before); $al = [IO.File]::ReadAllLines($After)
    $c = Compare-GoldenText -BeforeLines $bl -AfterLines $al -RootFull $rootFull -AsMultiset ([bool]$Sorted)
    if (-not $c.before -or -not $c.after) { throw 'an empty capture proves nothing' }
    $shown = 0
    foreach ($x in @($c.diff)) { if ($shown -lt 40) { Write-Output ('GOLDEN-DIFF at=' + $x.at + ' before: ' + $x.before); Write-Output ('GOLDEN-DIFF at=' + $x.at + ' after:  ' + $x.after) }; $shown++ }
    $v = if (@($c.diff).Count) { 'differ' } else { 'identical' }
    Write-Output ('PROVE-SPLIT-COMPLETE golden ' + $v + ' lines-before=' + $c.before + ' lines-after=' + $c.after + ' diff=' + @($c.diff).Count + ' mode=' + $(if ($Sorted) { 'multiset' } else { 'ordered' }))
    if (@($c.diff).Count) { exit 1 } else { exit 0 }
  }
  throw 'usage: prove-split.ps1 -Snapshot | -CompareFunctions | -CompareGolden | -SelfTest'
} catch {
  Write-Output ('prove-split: COULD NOT EVALUATE - ' + $_.Exception.Message + '. Not a pass.')
  Write-Output 'PROVE-SPLIT-COMPLETE could-not-evaluate'
  exit 3
}
