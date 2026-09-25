<#
  rule-scope.ps1 - how the Claude Code loader scopes one .claude\rules file, read from its text alone.

  ONE COPY OF THE LOADER'S READING (2026-09-25, W6.6 of design\PLAN-brain-consults-on-code-and-analysis-2026-09-22.md).
  These five functions were written for ops\audit-rule-currency.ps1 (W2.3), which asks whether a scope key is inert and
  whether a paths: entry matches anything. ops\audit-always-loaded-bytes.ps1 asks a second question of the SAME reading:
  which rules files load in every session, so their bytes count against the always-loaded budget. Two copies of a
  loader reading drift apart the day one of them learns a new spelling, and the byte ratchet would then count a file
  the scope check calls scoped, or the reverse. So the reading moved here unchanged, and both scripts dot-source it.

  The loader string they follow, and the builds it was read from, are in audit-rule-currency.ps1's header, check 1.
  The fixtures live there too: its -SelfTest drives every function in this file with synthetic text, and
  audit-always-loaded-bytes.ps1's -SelfTest drives Get-RuleScope through the byte count.

  THIS FILE DECLARES NO param() BLOCK, deliberately: dot-sourced, a param() here would run in the caller's scope
  (lib\guard-contract.ps1 records the trap). It defines functions and nothing else, so loading it changes no state.
#>
# USE WHEN: decide whether a .claude\rules file is scoped by paths: or loads in every session, the way the Claude Code loader reads its front matter
# ENFORCED BY: ops/audit-rule-currency.ps1 (push)
function Get-FrontMatterBlock {
  <# The lines between a leading --- and the next ---, or $null when the text has none. An unclosed fence is
     not a front matter: the loader then reads the whole text as body, and so does this. #>
  param([string]$Text)
  $lines = $Text -split "`r?`n"
  if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') { return $null }
  $out = New-Object System.Collections.Generic.List[string]
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '---') { $a = $out.ToArray(); return ,$a }
    [void]$out.Add($lines[$i])
  }
  return $null
}

function ConvertFrom-RuleYamlScalar {
  <# One YAML scalar as text: a quoted value loses its quotes, an unquoted one loses a trailing comment. #>
  param([string]$Value)
  $t = $Value.Trim()
  if ($t.Length -ge 1 -and ($t[0] -eq [char]'"' -or $t[0] -eq [char]"'")) {
    $close = $t.IndexOf($t[0], 1)
    if ($close -gt 0) { return $t.Substring(1, $close - 1) }
    return $t.Substring(1)
  }
  $hash = $t.IndexOf(' #')
  if ($hash -ge 0) { $t = $t.Substring(0, $hash).TrimEnd() }
  return $t
}

function Expand-RuleBraces {
  <# The loader's brace expansion: a{b,c}d is abd and acd, innermost-last, and a pattern over the loader's
     1,000-result budget is used unexpanded. #>
  param([string]$Pattern)
  if (-not $Pattern.Contains('{')) { $one = @($Pattern); return ,$one }
  $out = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Pattern)
  $steps = 0
  while ($stack.Count -gt 0) {
    $steps++
    if ($steps -gt 1000) { $one = @($Pattern); return ,$one }
    $s = $stack.Pop()
    $m = [regex]::Match($s, '^([^{]*)\{([^}]+)\}(.*)$')
    if (-not $m.Success) { [void]$out.Add($s); continue }
    $alts = $m.Groups[2].Value -split ','
    for ($k = $alts.Count - 1; $k -ge 0; $k--) { $stack.Push($m.Groups[1].Value + $alts[$k].Trim() + $m.Groups[3].Value) }
  }
  $a = $out.ToArray()
  return ,$a
}

function Split-RulePathValue {
  <# The loader's splitter over one string: commas at brace depth 0 separate entries, each is trimmed,
     empties are dropped, then each is brace-expanded. #>
  param([string]$Value)
  $parts = New-Object System.Collections.Generic.List[string]
  $cur = New-Object System.Text.StringBuilder
  $depth = 0
  foreach ($ch in $Value.ToCharArray()) {
    if ($ch -eq [char]'{') { $depth++; [void]$cur.Append($ch) }
    elseif ($ch -eq [char]'}') { $depth--; [void]$cur.Append($ch) }
    elseif ($ch -eq [char]',' -and $depth -eq 0) {
      $t = $cur.ToString().Trim(); if ($t) { [void]$parts.Add($t) }
      [void]$cur.Clear()
    }
    else { [void]$cur.Append($ch) }
  }
  $t = $cur.ToString().Trim(); if ($t) { [void]$parts.Add($t) }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($p in $parts) {
    $exR = Expand-RuleBraces -Pattern $p
    foreach ($e in @($exR)) { if ($e) { [void]$out.Add($e) } }
  }
  $a = $out.ToArray()
  return ,$a
}

function Get-RuleScope {
  <# How the Claude Code loader scopes one rules file, read from its text alone. Pure, so the fixtures drive
     it with synthetic text. HasFrontMatter; InertKeys (the keys named in check 1); PathsKey (a `paths:` key
     is present); Raw (the entries as written, split and expanded); Entries (the loader's list, /** stripped);
     Scope ('scoped' or 'unconditional'); Why. #>
  param([string]$Text)
  $fmR = Get-FrontMatterBlock -Text $Text
  $inert = New-Object System.Collections.Generic.List[string]
  $raw = New-Object System.Collections.Generic.List[string]
  $pathsKey = $false
  $pathsNull = $false
  if ($null -eq $fmR) {
    return [pscustomobject]@{ HasFrontMatter = $false; InertKeys = @(); PathsKey = $false; Raw = @(); Entries = @()
                              Scope = 'unconditional'; Why = 'no front matter, so no paths: key' }
  }
  $fm = @($fmR)
  for ($i = 0; $i -lt $fm.Count; $i++) {
    $km = [regex]::Match($fm[$i], '^([A-Za-z_][\w-]*)\s*:(.*)$')
    if (-not $km.Success) { continue }
    $key = $km.Groups[1].Value
    $rest = $km.Groups[2].Value
    if ($key -ieq 'globs' -or $key -ieq 'alwaysApply') { [void]$inert.Add($key); continue }
    if ($key -ine 'paths') { continue }
    if (-not [string]::Equals($key, 'paths', [StringComparison]::Ordinal)) { [void]$inert.Add($key); continue }
    $pathsKey = $true
    $value = $rest.Trim()
    if ($value -eq '' -or $value -match '^#') {
      $items = New-Object System.Collections.Generic.List[string]
      for ($j = $i + 1; $j -lt $fm.Count; $j++) {
        $line = $fm[$j]
        if ($line.Trim() -eq '' -or $line -match '^\s*#') { continue }
        $im = [regex]::Match($line, '^\s*-(?:\s+(.*))?$')
        if (-not $im.Success) { break }
        [void]$items.Add((ConvertFrom-RuleYamlScalar -Value $im.Groups[1].Value))
      }
      if ($items.Count -eq 0) { $pathsNull = $true }
      foreach ($it in $items) { $sR = Split-RulePathValue -Value $it; foreach ($e in @($sR)) { [void]$raw.Add($e) } }
    }
    elseif ($value -eq '~' -or $value -ieq 'null') { $pathsNull = $true }
    elseif ($value.StartsWith('[')) {
      $end = $value.LastIndexOf(']')
      $inner = if ($end -gt 0) { $value.Substring(1, $end - 1) } else { $value.Substring(1) }
      foreach ($piece in ($inner -split ',')) {
        $sR = Split-RulePathValue -Value (ConvertFrom-RuleYamlScalar -Value $piece)
        foreach ($e in @($sR)) { [void]$raw.Add($e) }
      }
    }
    else {
      $sR = Split-RulePathValue -Value (ConvertFrom-RuleYamlScalar -Value $value)
      foreach ($e in @($sR)) { [void]$raw.Add($e) }
    }
  }
  $entries = New-Object System.Collections.Generic.List[string]
  foreach ($g in $raw) {
    $n = if ($g.EndsWith('/**')) { $g.Substring(0, $g.Length - 3) } else { $g }
    if ($n.Length -gt 0) { [void]$entries.Add($n) }
  }
  $allStar = ($entries.Count -gt 0 -and @($entries | Where-Object { $_ -ne '**' }).Count -eq 0)
  $scope = 'scoped'
  $why = ''
  if (-not $pathsKey) { $scope = 'unconditional'; $why = 'no paths: key' }
  elseif ($pathsNull -or $entries.Count -eq 0) { $scope = 'unconditional'; $why = 'paths: resolves to no entry' }
  elseif ($allStar) { $scope = 'unconditional'; $why = 'paths: is only **, which the loader treats as no scope' }
  else { $why = ('{0} paths: entr{1}' -f $entries.Count, $(if ($entries.Count -eq 1) { 'y' } else { 'ies' })) }
  # Assigned, never built inside $(...): a subexpression turns one entry into a bare string and none into $null,
  # and @($null).Count is 1, so the matcher would run once over nothing.
  [string[]]$outEntries = @()
  if ($scope -eq 'scoped') { $outEntries = $entries.ToArray() }
  return [pscustomobject]@{ HasFrontMatter = $true; InertKeys = $inert.ToArray(); PathsKey = $pathsKey
                            Raw = $raw.ToArray(); Entries = $outEntries; Scope = $scope; Why = $why }
}
