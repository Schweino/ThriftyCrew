<#
  gate-input-derived.ps1 - which variables outside the four named bases lib\gate-input-key.ps1 may RESOLVE.

  Self-test:   powershell -File lib\gate-input-derived.ps1 -SelfTest

  Round 5 of design\PLAN-push-gate-diet-2026-09-27.md (Brad, 2026-09-27). The round-4 safety fix refused a key for any
  path built on a variable the key could not see (Get-TcGateUnpinnedBase). Many of those variables are fixed repo folders
  (meal-prep's $mp = Split-Path -Parent $here, the json-io walk-up $__jioRoot). This file says exactly which: a variable
  is resolved only when EVERY assignment of it traces to a repo-rooted folder, and then lib\gate-input-key.ps1 hashes the
  files built on it, refuses the data directories among them, and refuses a computed or unparsed spelling on it, exactly
  as for $repo. A parameter, a loop variable, a by-name setter, a mid-line assignment or anything unreadable stays
  unresolved, so the key is still refused.
  Split out of lib\gate-input-key.ps1 so that file stays at its size mark (ops\audit-file-size-budget.ps1).
#>
# Its self-test builds every sandbox it reads under %TEMP%, and loads the key library it fixtures.
# gate-inputs: lib\gate-input-derived.ps1, lib\gate-input-key.ps1, lib\git-repo-env.ps1
$__gidSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
function Get-TcGateDerivedBases {
  <# Pure over comment-stripped TEXT (round 5 of design\PLAN-push-gate-diet-2026-09-27.md). A variable outside the four
     named bases is RESOLVED when every assignment of it in this file traces to a repo-rooted folder: `$mp = Split-Path
     -Parent $here`, `$d = Join-Path $mp 'sub'`, `$x = $here`, or the json-io walk-up idiom
     (`$v = $PSScriptRoot; while ($v -and -not (Test-Path (Join-Path $v '<lit>'))) { $v = Split-Path $v -Parent }`).
     $Vars is Get-TcGateVarBase's answer for the named bases. Returns name(lower) -> array of base strings:
     'up:<n>:<sub>' (n folders above the file's own folder, then sub), 'repo::<sub>', or 'walk:<lit>:<sub>' (the first
     ancestor of the file holding <lit>). A variable that is a parameter anywhere, a loop variable, set by
     Set-Variable/-OutVariable, assigned mid-line, or assigned anything this reader cannot place is NOT returned, and
     Get-TcGateUnpinnedBase then refuses the key. #>
  param([string]$Code, [hashtable]$Vars)
  $names = New-Object Collections.Generic.List[string]
  foreach ($m in [regex]::Matches($Code, '(?i)(?<!`)Join-Path\s+(?:-Path\s+)?\$(?:script:)?(\w+)\b')) {
    $n = $m.Groups[1].Value.ToLowerInvariant()
    if (@('repo', 'root', 'reporoot', 'here', 'psscriptroot') -contains $n -or $names.Contains($n)) { continue }
    $names.Add($n)
  }
  $res = @{}
  if (-not $names.Count) { return $res }
  $known = @{}
  foreach ($k in @($Vars.Keys)) {
    $l = $Vars[$k]
    if ($null -eq $l) { continue }
    $known[$k] = @(foreach ($x in $l) { if ($x -is [string]) { if ($x -eq 'repo') { 'repo::' } else { $null } } else { 'up:' + [int]$x + ':' } })
    if (@($known[$k] | Where-Object { $null -eq $_ }).Count) { $known.Remove($k) }
  }
  $known['psscriptroot'] = @('up:0:')
  $idiomRx = '(?im)^[ \t]*\$(\w+)[ \t]*=[ \t]*\$PSScriptRoot[ \t]*;[ \t]*while[ \t]*\([ \t]*\$\1[ \t]+-and[ \t]+-not[ \t]+\(Test-Path[ \t]+\(Join-Path[ \t]+\$\1[ \t]+''([^''\$\*\?]+)''\)\)\)[ \t]*\{[ \t]*\$\1[ \t]*=[ \t]*Split-Path[ \t]+\$\1[ \t]+-Parent[ \t]*\}[ \t]*$'
  $candidates = @{}
  foreach ($n in $names) {
    $e = [regex]::Escape($n)
    # Decided somewhere this file cannot see: a parameter, a loop variable, a by-name setter.
    if ([regex]::IsMatch($Code, ('(?i)\[[\w\.\[\]]+\]\s*\$' + $e + '\b'))) { continue }
    if ([regex]::IsMatch($Code, ('(?i)foreach\s*\(\s*\$' + $e + '\s+in\b'))) { continue }
    if ([regex]::IsMatch($Code, ('(?is)\bparam\s*\((?:[^()]|\([^()]*\))*\$' + $e + '\b'))) { continue }
    if ([regex]::IsMatch($Code, ('(?i)\bfunction\s+[\w-]+\s*\([^)]*\$' + $e + '\b'))) { continue }
    if ([regex]::IsMatch($Code, ('(?i)(?:Set-Variable|New-Variable|-OutVariable|-ov|-ErrorVariable|-ev|-PipelineVariable|-pv)\b[^\r\n]*\b' + $e + '\b'))) { continue }
    if ([regex]::IsMatch($Code, ('(?i)\[ref\]\s*\$' + $e + '\b|\$' + $e + '\s*,[^\r\n]*=(?!=)|,\s*\$' + $e + '\s*=(?!=)'))) { continue }
    $allAsg = [regex]::Matches($Code, ('(?i)(?<![\w`])\$(?:script:|global:|local:|private:)?' + $e + '\s*(?:[-+*/%]?=)(?!=)'))
    if (-not $allAsg.Count) { continue }
    $idioms = @([regex]::Matches($Code, $idiomRx) | Where-Object { $_.Groups[1].Value -ieq $n })
    $lineAsg = [regex]::Matches($Code, ('(?im)^[ \t]*\$(?:script:)?' + $e + '[ \t]*=(?!=)[ \t]*(.+?)[ \t]*$'))
    # Every assignment must be a whole statement at the start of a line, or part of the walk-up idiom (two per line).
    if ($allAsg.Count -ne ($lineAsg.Count + $idioms.Count)) { continue }
    $rhs = New-Object Collections.Generic.List[string]
    $bad = $false
    foreach ($a in $lineAsg) {
      $isIdiom = $false
      foreach ($im in $idioms) { if ($a.Index -ge $im.Index -and $a.Index -lt ($im.Index + $im.Length)) { $isIdiom = $true } }
      if ($isIdiom) { continue }
      $r = ($a.Groups[1].Value -replace '\s+#.*$', '').Trim().TrimEnd(';').Trim()
      if ($r -match '[;{}]') { $bad = $true; break }
      $rhs.Add($r)
    }
    if ($bad) { continue }
    $candidates[$n] = [pscustomobject]@{ Rhs = $rhs.ToArray(); Walk = @($idioms | ForEach-Object { $_.Groups[2].Value }) }
  }
  for ($round = 0; $round -lt 8; $round++) {
    $grew = $false
    foreach ($n in @($candidates.Keys)) {
      if ($res.ContainsKey($n)) { continue }
      $c = $candidates[$n]
      $out = New-Object Collections.Generic.List[string]
      $ok = $true
      foreach ($w in $c.Walk) { $out.Add('walk:' + ($w -replace '/', '\') + ':') }
      foreach ($r in $c.Rhs) {
        $bases = $null
        $jm = [regex]::Match($r, '(?i)^Join-Path\s+\$(?:script:)?(\w+)\s+''([^''\$\*\?]+)''$')
        if ($jm.Success) {
          $src = $jm.Groups[1].Value.ToLowerInvariant()
          $srcB = if ($known.ContainsKey($src)) { $known[$src] } elseif ($res.ContainsKey($src)) { $res[$src] } else { $null }
          if ($null -eq $srcB) { $ok = $false; break }
          $lit = ($jm.Groups[2].Value -replace '/', '\').Trim('\')
          $bases = @(foreach ($b in $srcB) { $p = $b.Split(':', 3); $p[0] + ':' + $p[1] + ':' + ((@($p[2], $lit) | Where-Object { $_ }) -join '\') })
        } else {
          $vm = [regex]::Matches($r, '\$(?:script:)?(\w+)')
          if ($vm.Count -ne 1) { $ok = $false; break }
          $src = $vm[0].Groups[1].Value.ToLowerInvariant()
          $rest = $r -replace '(?i)\$(?:script:)?\w+|\bSplit-Path\b|-Parent\b|-Path\b|-LiteralPath\b', ''
          if ($rest -notmatch '^[\s\(\)]*$') { $ok = $false; break }
          $srcB = if ($known.ContainsKey($src)) { $known[$src] } elseif ($res.ContainsKey($src)) { $res[$src] } else { $null }
          if ($null -eq $srcB) { $ok = $false; break }
          $ups = ([regex]::Matches($r, '(?i)\bSplit-Path\b')).Count
          $bases = @()
          foreach ($b in $srcB) {
            $p = $b.Split(':', 3); $kind = $p[0]; $sub = $p[2]; $n2 = $p[1]
            for ($u = 0; $u -lt $ups; $u++) {
              if ($sub) { $i = $sub.LastIndexOf('\'); $sub = if ($i -lt 0) { '' } else { $sub.Substring(0, $i) } }
              elseif ($kind -eq 'up') { $n2 = [string]([int]$n2 + 1) }
              else { $kind = 'bad'; break }
            }
            if ($kind -eq 'bad') { $bases = $null; break }
            $bases += ($kind + ':' + $n2 + ':' + $sub)
          }
          if ($null -eq $bases) { $ok = $false; break }
        }
        foreach ($b in $bases) { if (-not $out.Contains($b)) { $out.Add($b) } }
      }
      if ($ok -and $out.Count) { $res[$n] = $out.ToArray(); $grew = $true }
    }
    if (-not $grew) { break }
  }
  return $res
}

function Get-TcGateDerivedItems {
  <# Every Join-Path literal lib\gate-input-key.ps1 must resolve in one file's code: those on the named bases
     ($script:TcGateLiteralRx, Derived = $null) and those on a RESOLVED variable (Derived = its base strings). #>
  param([string]$Code, [hashtable]$Vars)
  $items = [Collections.Generic.List[object]]::new()
  foreach ($m in [regex]::Matches($Code, $script:TcGateLiteralRx)) { $items.Add([pscustomobject]@{ Base = $m.Groups[1].Value; Lit = $m.Groups[2].Value; Derived = $null }) }
  $derived = Get-TcGateDerivedBases -Code $Code -Vars $Vars
  if ($derived.Count) {
    $alt = (@($derived.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    foreach ($m in [regex]::Matches($Code, ('(?i)(?<!`)Join-Path\s+\$(?:script:)?(' + $alt + ')\b\s+''([^'']+)'''))) {
      $items.Add([pscustomobject]@{ Base = ''; Lit = $m.Groups[2].Value; Derived = $derived[$m.Groups[1].Value.ToLowerInvariant()] })
    }
  }
  return , $items
}

function Get-TcGateDerivedDirs {
  <# The repo-relative folders a resolved variable's base strings name, from the file's own ancestors ($FileAnc, the
     file's folder first). $null when any base cannot be placed inside the repo: the caller then refuses (strict). #>
  param([string[]]$Derived, [string[]]$FileAnc, [string]$RepoFull)
  $dd = [Collections.Generic.List[string]]::new()
  foreach ($db in $Derived) {
    $p = ([string]$db).Split(':', 3)
    $root = $null
    if ($p[0] -eq 'repo') { $root = '' }
    elseif ($p[0] -eq 'up') { if ([int]$p[1] -lt $FileAnc.Count) { $root = $FileAnc[[int]$p[1]] } }
    elseif ($p[0] -eq 'walk') { foreach ($a in $FileAnc) { if ([IO.File]::Exists([IO.Path]::Combine([IO.Path]::Combine($RepoFull, $a), $p[1]))) { $root = $a; break } } }
    if ($null -eq $root) { return $null }
    $d = ((@($root, $p[2]) | Where-Object { $_ }) -join '\')
    if (-not $dd.Contains($d)) { $dd.Add($d) }
  }
  return , $dd.ToArray()
}

function Test-TcGateDerivedRefusal {
  <# A RESOLVED variable gets the refusals a named base gets: a computed child, and every unparsed spelling.
     Returns the refusal's Why, or ''. #>
  param([string]$Code)
  $derived = Get-TcGateDerivedBases -Code $Code -Vars (Get-TcGateVarBase -Code $Code)
  if (-not $derived.Count) { return '' }
  $alt = (@($derived.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|'
  if ([regex]::IsMatch($Code, ('(?i)(?<!`)Join-Path\s+\$(?:script:)?(?:' + $alt + ')\s+[\$\(]'))) { return 'builds a repo path from a variable, which a source key cannot watch' }
  $u = Test-TcGateUnparsed -Code $Code -ExtraBases @($derived.Keys)
  if ($u) { return ('builds a path with ' + $u + ', a spelling the key does not parse, so the file it reads cannot be hashed') }
  return ''
}

if ($__gidSelfTest) {
  $ErrorActionPreference = 'Stop'
  . (Join-Path $PSScriptRoot 'gate-input-key.ps1')
  $script:f = 0; $script:cases = 0
  function T([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('ok    ' + $m) } else { $script:f++; Write-Output ('FAIL  ' + $m + '   got: ' + $got) }
  }
  $sb = Join-Path $env:TEMP ('gid-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    $null = New-Item -ItemType Directory -Path $sb -ErrorAction Stop
    # ---- ROUND 5: A VARIABLE WHOSE EVERY ASSIGNMENT TRACES TO A REPO FOLDER IS RESOLVED, AND ITS READS ARE HASHED ----
    $dr = Join-Path $sb 'derived'
    $mpDir = 'meal-' + 'prep'   # built, so no module-reach scan reads a fixture path as a reach
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $dr 'lib'), (Join-Path $dr 'meal-prep\pipeline'), (Join-Path $dr ($mpDir + '\db')) -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $dr 'lib\json-io.ps1'), "function Read-Zz { 1 }`n")
    [IO.File]::WriteAllText((Join-Path $dr 'meal-prep\vocab-list.json'), '{"a":1}')
    [IO.File]::WriteAllText((Join-Path $dr ($mpDir + '\db\x.json')), '{}')
    $hereLine = "`$here = Split-Path -Parent `$MyInvocation.MyCommand.Path`n"
    $dGate = Join-Path $dr 'meal-prep\pipeline\zz-mp.ps1'
    [IO.File]::WriteAllText($dGate, ($hereLine + "`$mp   = Split-Path -Parent `$here`n`$v = Join-Path `$mp 'vocab-list.json'`n"))
    $dk1 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'MUST NOT FIRE  $mp = Split-Path -Parent $here resolves to a repo folder, so the gate keys' ($dk1.Ok) ('why=' + $dk1.Why)
    [IO.File]::WriteAllText((Join-Path $dr 'meal-prep\vocab-list.json'), '{"a":2}')
    $dk2 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'MUST FIRE  the file read through the resolved $mp is IN the key: changing it moves the key' ($dk1.Ok -and $dk2.Ok -and $dk1.Key -ne $dk2.Key) ('k1=' + $dk1.Key + ' k2=' + $dk2.Key)
    $jGate = Join-Path $dr 'meal-prep\pipeline\zz-jio.ps1'
    [IO.File]::WriteAllText($jGate, "`$__jioRoot = `$PSScriptRoot; while (`$__jioRoot -and -not (Test-Path (Join-Path `$__jioRoot 'lib\json-io.ps1'))) { `$__jioRoot = Split-Path `$__jioRoot -Parent }`n. (Join-Path `$__jioRoot 'lib\json-io.ps1')`n")
    $jk1 = Get-TcGateInputKey -Repo $dr -GateFile $jGate -GateArg '-SelfTest'
    [IO.File]::WriteAllText((Join-Path $dr 'lib\json-io.ps1'), "function Read-Zz { 2 }`n")
    $jk2 = Get-TcGateInputKey -Repo $dr -GateFile $jGate -GateArg '-SelfTest'
    T 'MUST NOT FIRE  the json-io walk-up idiom resolves to the folder holding lib\json-io.ps1, which moves the key' ($jk1.Ok -and $jk2.Ok -and $jk1.Key -ne $jk2.Key) ('ok=' + $jk1.Ok + ' why=' + $jk1.Why)
    [IO.File]::WriteAllText($dGate, ($hereLine + "`$mp   = if (`$Root) { `$Root } else { Split-Path -Parent `$here }`n`$v = Join-Path `$mp 'vocab-list.json'`n"))
    $dk3 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'MUST FIRE  an assignment that may take a caller''s $Root leaves $mp unresolvable: refused' ((-not $dk3.Ok) -and $dk3.Why -match '\$mp') ('ok=' + $dk3.Ok + ' why=' + $dk3.Why)
    [IO.File]::WriteAllText($dGate, ($hereLine + "`$mp   = Split-Path -Parent `$here`n`$v = Join-Path `$mp 'db\x.json'`n"))
    $dk4 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'MUST FIRE  a resolved $mp joined into the meal-prep data folder is refused as a data read' ((-not $dk4.Ok) -and $dk4.Why -match 'data directory') ('ok=' + $dk4.Ok + ' why=' + $dk4.Why)
    [IO.File]::WriteAllText($dGate, ($hereLine + "`$mp   = Split-Path -Parent `$here`n`$v = Join-Path `$mp `$name`n"))
    $dk5 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'MUST FIRE  a resolved $mp joined to a computed child is refused' (-not $dk5.Ok) ('why=' + $dk5.Why)
    [IO.File]::WriteAllText($dGate, ($hereLine + "`$mp   = Split-Path -Parent `$here`n`$v = `"`$mp\vocab-list.json`"`n`$w = Join-Path `$mp 'vocab-list.json'`n"))
    $dk6 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'MUST FIRE  a resolved $mp interpolated into a string path is an unparsed spelling: refused' (-not $dk6.Ok) ('why=' + $dk6.Why)
    [IO.File]::WriteAllText($dGate, ("function Read-It([string]`$mp) { Join-Path `$mp 'vocab-list.json' }`n" + $hereLine + "`$mp   = Split-Path -Parent `$here`n"))
    $dk7 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'CLEAN TWIN  a base that is also a function parameter is decided by a caller: still refused' ((-not $dk7.Ok) -and $dk7.Why -match '\$mp') ('ok=' + $dk7.Ok + ' why=' + $dk7.Why)
    [IO.File]::WriteAllText($dGate, ("param([string]`$Base)`n`$d = Split-Path -Parent `$Base`n`$v = Join-Path `$d 'vocab-list.json'`n"))
    $dk8 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'CLEAN TWIN  a variable built on a script parameter still refuses the key' ((-not $dk8.Ok) -and $dk8.Why -match '\$d\b') ('ok=' + $dk8.Ok + ' why=' + $dk8.Why)
    [IO.File]::WriteAllText($dGate, ($hereLine + "`$mp   = Split-Path -Parent `$here`nif (`$x) { `$mp = `$other }`n`$v = Join-Path `$mp 'vocab-list.json'`n"))
    $dk9 = Get-TcGateInputKey -Repo $dr -GateFile $dGate -GateArg '-SelfTest'
    T 'MUST FIRE  a second assignment in the middle of a line leaves $mp unresolvable: refused' ((-not $dk9.Ok) -and $dk9.Why -match '\$mp') ('ok=' + $dk9.Ok + ' why=' + $dk9.Why)
  } catch {
    $script:f++
    Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A SUITE CAN RUN ZERO CASES AND EXIT 0, so the count is asserted.
  if ($script:cases -lt 10) { $script:f++; Write-Output ("FAIL  only {0} of 10 cases ran" -f $script:cases) }
  if ($script:f) { Write-Output ("gate-input-derived SELF-TEST FAIL: {0} of {1} case(s)" -f $script:f, $script:cases); exit 1 }
  Write-Output ("gate-input-derived SELF-TEST PASS: {0} cases - a repo-rooted variable keys and its reads move the key; a caller's parameter, a mid-line assignment, a data read and a computed or interpolated path still refuse" -f $script:cases)
  exit 0
}