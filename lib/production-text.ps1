# production-text.ps1 - THE one way for a sweep over PowerShell source to read only what RUNS IN PRODUCTION.
#
# STANDING RULE, AND IT BINDS THE NEXT PERSON TO REWRITE THIS FILE (Brad's ruling, 2026-09-12,
# backlog I154). This estate has THREE source reducers: this one, lib\ps-source.ps1 (tokens, blanks
# block comments and drops whole-line ones), and Get-McBlankedText inside
# ops\audit-mustfire-census.ps1 (tokens, blanks every comment in place and keeps offsets). Measured
# 2026-09-12 by reading all three: NOT ONE OF THEM BLANKS A STRING LITERAL, which is why
# .claude\rules\ops-and-gates.md has to carry "a self-test that greps its own source cannot fail -
# build needles by concatenation". That rule is a WORKAROUND FOR A MISSING LEXER. Brad ruled: do NOT
# retrofit the switch now and do NOT re-fixture the callers for it alone, because the change it was
# written to protect has already shipped. What he ruled instead is the trigger - THE NEXT REWRITE OF
# ANY OF THE THREE, FOR ANY REASON, CONSOLIDATES THEM INTO ONE TOKEN-BASED REDUCER IN lib\ THAT BLANKS
# COMMENTS BY DEFAULT AND STRING-LITERAL CONTENTS BEHIND A SWITCH, AND MOVES THE CALLERS IT TOUCHES
# ONTO IT IN THE SAME CHANGE. Adding the string half later costs a SECOND re-fixturing of every
# caller. This file's rung is the AST one, so read the consolidation as one reducer with three modes
# and a string switch, not as a rewrite of what it decides: what it drops is a self-test clause BODY,
# and that rule is narrow on purpose (below) and does not move.
#
# WHY THIS EXISTS (2026-09-11, queue 2026-09-11-220094). Five sweeps in grocery\ read every grocery\*.ps1 as
# TEXT and flag a pattern they must never see live: a retired Hy-Vee identity, the PS 5.1 @()-no-unroll trap,
# the throwing empty-stamp idiom, a [string] cast over a search-term array, a drifted store list. Their only
# fixture discriminator was a hand-kept file skip list plus a leading '#'. A guard's own MUST FIRE fixture has
# to carry the literal it proves the guard refuses, and it has to sit on a NON-COMMENT line of a production
# file - so on 2026-09-10 pull-grocery-ads.ps1's -SelfTest froze a registry holding the retired Omaha #01
# identity, and test-hyvee-tag-check.ps1 flagged it. test-auditors went red on 1 of 702 cases and the estate
# carried that red as an accepted failure.
#
# WHY NOT A MARKER COMMENT. A marker can be copied onto a live line, and was: the fixture marker scoped away
# from -SelfTest blocks on 2026-09-09 met its next fixture within the hour. A `$SelfTest` clause body is dead
# code in production BY CONSTRUCTION, so scoping to it needs nothing anyone can wear.
#
# THE RULE IS NARROW ON PURPOSE, and it is the rule grocery\audit-store-registry.ps1 wrote on 2026-09-10
# (queue 2026-09-10-483a9c), lifted here so there is ONE copy: only the BODY of a clause whose condition is
# EXACTLY the switch is dropped. `if (-not $SelfTest)` is production - capture-watchdog.ps1 runs a real shard
# window under it - and so is an `else` branch, and so is `if ($SelfTest -and $x)`.
#
# THE ASYMMETRY (same one lib\ps-source.ps1 records): dropping too little leaves a sweep firing on its own
# fixtures; dropping too much makes a sweep silently blind to a live pin. So an unparseable file falls back to
# returning EVERY line - louder, never quieter.
#
# SCOPE OF A CLEAN REPORT: this is a reducer, not a detector. It is SOUND for the thing that matters to its
# callers - a line outside an `if ($SelfTest)` body is always returned - and deliberately UNSOUND about
# fixtures: a fixture written anywhere else (a function called from the clause, a data file, a here-string
# built at top level) is still returned and its caller must still decide.
#
# Self-test:   powershell -File lib\production-text.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope
# and would reset the caller's own -SelfTest. Same rule as lib\ps-source.ps1 and lib\atomic-write.ps1, and it
# matters more here than anywhere: four of this file's five callers are themselves self-testing guards.
$__ptSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-TcSelfTestClauseRange {
  <# The line ranges of every `if ($SelfTest) { ... }` clause BODY in one parsed file. #>
  param($Ast)
  $ranges = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Ast) { return $ranges }
  $ifs = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))
  foreach ($ifAst in $ifs) {
    foreach ($clause in $ifAst.Clauses) {
      $cond = $clause.Item1; $body = $clause.Item2
      if ($null -eq $cond -or $null -eq $body) { continue }
      # EXACTLY the switch. A condition that merely mentions it is production.
      if ($cond.Extent.Text -notmatch '^\s*\$(script:)?SelfTest\s*$') { continue }
      $ranges.Add([pscustomobject]@{ start = $body.Extent.StartLineNumber; end = $body.Extent.EndLineNumber })
    }
  }
  return $ranges
}

function Test-TcInsideSelfTestClause {
  <# Is line $Line inside the body of a clause whose condition is exactly the self-test switch? #>
  param($Ast, [int]$Line)
  if ($null -eq $Ast -or $Line -lt 1) { return $false }
  foreach ($r in (Get-TcSelfTestClauseRange -Ast $Ast)) {
    if ($Line -ge $r.start -and $Line -le $r.end) { return $true }
  }
  return $false
}

function Get-TcProductionLines {
  <#
    .SYNOPSIS Every line of a .ps1 that can run in production, as { line_no, text }.
    .DESCRIPTION Comment lines are KEPT: callers have their own '#' handling and this file must not change
                 what they decide about prose. Only `if ($SelfTest) { }` clause bodies are dropped. An
                 unparseable file yields all of its lines, so a sweep can never go blind through here.
  #>
  param([string]$Path)
  $out = New-Object System.Collections.Generic.List[object]
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $out }
  $lines = [IO.File]::ReadAllLines($Path)
  $ast = $null
  try {
    $tk = $null; $pe = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tk, [ref]$pe)
  } catch { $ast = $null }
  $ranges = @(Get-TcSelfTestClauseRange -Ast $ast)
  $n = 0
  foreach ($line in $lines) {
    $n++
    $skip = $false
    foreach ($r in $ranges) { if ($n -ge $r.start -and $n -le $r.end) { $skip = $true; break } }
    if ($skip) { continue }
    $out.Add([pscustomobject]@{ line_no = $n; text = $line })
  }
  return $out
}

function Get-TcProductionText {
  <#
    .SYNOPSIS The same reduction as ONE string, for callers that run a regex over the whole file.
    .DESCRIPTION A dropped line is BLANKED, not deleted, so the line count and every line number a caller
                 computes stay the file's own. Newlines are LF, as Get-PsCodeOnly returns them.
  #>
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
  $lines = [IO.File]::ReadAllLines($Path)
  $ast = $null
  try {
    $tk = $null; $pe = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tk, [ref]$pe)
  } catch { $ast = $null }
  $ranges = @(Get-TcSelfTestClauseRange -Ast $ast)
  $keep = New-Object System.Collections.Generic.List[string]
  $n = 0
  foreach ($line in $lines) {
    $n++
    $drop = $false
    foreach ($r in $ranges) { if ($n -ge $r.start -and $n -le $r.end) { $drop = $true; break } }
    if ($drop) { $keep.Add('') } else { $keep.Add([string]$line) }
  }
  return ($keep -join "`n")
}

if ($__ptSelfTest) {
  $ErrorActionPreference = 'Stop'
  $fail = 0; $cases = 0
  function Invoke-PtCase([string]$label, [scriptblock]$body) {
    $script:cases++
    try {
      if (& $body) { Write-Output "  ok    $label" } else { Write-Output "  FAIL  $label"; $script:fail++ }
    } catch { Write-Output ("  FAIL  $label - threw: " + $_.Exception.Message); $script:fail++ }
  }
  # ONE scratch directory per run, removed in finally: run-gates runs every self-test in the tree and several
  # sessions push at once, so a fixed name under %TEMP% is another run's file.
  $ptDir = Join-Path ([IO.Path]::GetTempPath()) ('pt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -ErrorAction Stop $ptDir | Out-Null
  $utf8 = New-Object Text.UTF8Encoding($false)
  # THE NEEDLE IS BUILT, never written whole: this file is read by the same grocery sweeps it serves, and a
  # detector that carries its own pattern as a literal is a detector that flags itself.
  $needle = '$HStore = ' + '14' + '65'
  function New-PtFile([string]$name, [string[]]$lines) {
    $p = Join-Path $ptDir $name
    [IO.File]::WriteAllText($p, (($lines -join "`n") + "`n"), $utf8)
    return $p
  }
  try {
    # 1. MUST FIRE - the founding bug of every caller: a pin on a TOP-LEVEL line is still reported.
    $topLine = $needle
    $fTop = New-PtFile 'top.ps1' @('# a production script', $topLine, 'Write-Output $HStore')
    Invoke-PtCase 'MUST FIRE  a pin on a top-level line is returned as production' {
      $r = @(Get-TcProductionLines -Path $fTop)
      @($r | Where-Object { $_.text -match '14' + '65' }).Count -eq 1
    }
    # 2. MUST NOT FIRE - the byte-identical line inside the clause body.
    $bodyLine = '  ' + $needle
    $fSelf = New-PtFile 'self.ps1' @('# a production script with a frozen fixture', 'if ($SelfTest) {', $bodyLine, '}', 'Write-Output "live"')
    Invoke-PtCase 'MUST NOT FIRE  the same pin inside an if ($SelfTest) body is not returned' {
      $r = @(Get-TcProductionLines -Path $fSelf)
      @($r | Where-Object { $_.text -match '14' + '65' }).Count -eq 0
    }
    # 3. MUST NOT FIRE - inside a function DEFINED inside the clause body.
    $fnLine = '    ' + $needle
    $fFn = New-PtFile 'fn.ps1' @('if ($SelfTest) {', '  function _Fx {', $fnLine, '  }', '  _Fx', '}')
    Invoke-PtCase 'MUST NOT FIRE  a pin in a function defined inside the clause is not returned' {
      @(@(Get-TcProductionLines -Path $fFn) | Where-Object { $_.text -match '14' + '65' }).Count -eq 0
    }
    # 4. CLEAN TWIN - the scope stays NARROW: a compound condition is production.
    $cmpLine = '  ' + $needle
    $fCmp = New-PtFile 'cmp.ps1' @('if ($SelfTest -and $x) {', $cmpLine, '}')
    Invoke-PtCase 'CLEAN TWIN  a pin under if ($SelfTest -and $x) is still returned' {
      @(@(Get-TcProductionLines -Path $fCmp) | Where-Object { $_.text -match '14' + '65' }).Count -eq 1
    }
    # 5. CLEAN TWIN - `if (-not $SelfTest)` is a PRODUCTION branch and stays readable.
    $notLine = '  ' + $needle
    $fNot = New-PtFile 'not.ps1' @('if (-not $SelfTest) {', $notLine, '}')
    Invoke-PtCase 'CLEAN TWIN  a pin under if (-not $SelfTest) is still returned' {
      @(@(Get-TcProductionLines -Path $fNot) | Where-Object { $_.text -match '14' + '65' }).Count -eq 1
    }
    # 6. CLEAN TWIN - the ELSE branch of a self-test clause is production.
    $elseLine = '  ' + $needle
    $fElse = New-PtFile 'else.ps1' @('if ($SelfTest) {', '  Write-Output "fixture"', '} else {', $elseLine, '}')
    Invoke-PtCase 'CLEAN TWIN  the else branch of an if ($SelfTest) is still returned' {
      @(@(Get-TcProductionLines -Path $fElse) | Where-Object { $_.text -match '14' + '65' }).Count -eq 1
    }
    # 7. CLEAN TWIN - line numbers are the FILE's own, so a caller can still name a line.
    Invoke-PtCase 'CLEAN TWIN  line_no is the real file line number' {
      $r = @(Get-TcProductionLines -Path $fTop)
      $hit = @($r | Where-Object { $_.text -match '14' + '65' })
      ($hit.Count -eq 1) -and ($hit[0].line_no -eq 2)
    }
    # 8. CLEAN TWIN - an UNPARSEABLE file is louder, never quieter.
    $badLine = $needle
    $fBad = New-PtFile 'bad.ps1' @('function {{{ broken', $badLine)
    Invoke-PtCase 'CLEAN TWIN  an unparseable file yields every line rather than going blind' {
      $r = @(Get-TcProductionLines -Path $fBad)
      ($r.Count -eq 2) -and (@($r | Where-Object { $_.text -match '14' + '65' }).Count -eq 1)
    }
    # 9. CLEAN TWIN - Get-TcProductionText keeps the line COUNT and blanks only the clause body.
    Invoke-PtCase 'CLEAN TWIN  Get-TcProductionText blanks the clause body and keeps the line count' {
      $t = Get-TcProductionText -Path $fSelf
      $ls = @($t -split "`n")
      ($ls.Count -eq 5) -and ($ls[2] -eq '') -and ($ls[4] -match 'live') -and ($t -notmatch '14' + '65')
    }
    # 10. CLEAN TWIN - a file with no self-test at all is returned whole.
    $fPlain = New-PtFile 'plain.ps1' @('$a = 1', '# note', $needle)
    Invoke-PtCase 'CLEAN TWIN  a file with no self-test clause is returned whole, comments included' {
      $r = @(Get-TcProductionLines -Path $fPlain)
      ($r.Count -eq 3) -and ($r[1].text -match '^# note$')
    }
  } finally { Remove-Item -LiteralPath $ptDir -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ("production-text: cases=$cases failed=$fail")
  Write-Output ("SELFTEST " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
  exit $(if ($fail) { 1 } else { 0 })
}
