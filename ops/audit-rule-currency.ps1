<#
  audit-rule-currency.ps1 - a rules file whose scope key the loader never reads, a paths: entry that loads
  for nothing, and a dated claim nobody has re-read.

  WS 7e of design\PLAN-brain-v2-2026-09-09.md. Checks 1 and 2 rewritten by W2.3 of
  design\PLAN-brain-consults-on-code-and-analysis-2026-09-22.md.

  FOUR CHECKS, AND ONLY THREE OF THEM ARE VERDICTS (check 4 was added by the option-B experiment and is
  numbered last although it is written after check 2, which it extends).

  1. INERT SCOPE KEYS - HARD. Claude Code scopes a rules file by its `paths:` front matter key and by
     nothing else. Every installed build checked (2.1.173, 2.1.236, 2.1.263, 2.1.280) carries one loader:
         if(!n.paths)return{content:r};
         let s=net(n.paths).map((g)=>g.endsWith("/**")?g.slice(0,-3):g).filter((g)=>g.length>0);
         if(s.length===0||s.every((g)=>g==="**"))return{content:r};return{content:r,paths:s}
     `globs:` and `alwaysApply:` are Cursor's keys. They reached this estate on 2026-09-06 from Bun's
     embedded Cursor template inside claude.exe, which was read as Claude Code's own help text, and a file
     carrying them loads in EVERY session while looking scoped. Until W2.3 this check validated the
     `globs:` entries, so it blessed the very key the loader ignores. A front matter carrying `globs:`,
     `alwaysApply:`, or a `paths` key spelled in any other case (the loader reads `paths` exactly) is
     exit 2: "inert scope key: this file loads unconditionally".

  2. PATHS - HARD. Every `paths:` entry must match at least one tracked file (git ls-files). The value is
     read the way the loader reads it: a YAML block list, a flow list or a comma string; each item split
     at commas outside braces, trimmed, brace-expanded; a trailing /** stripped; empties dropped. No entry
     left, or only `**`, means the file is UNCONDITIONAL, exactly as the loader treats it. An entry that
     matches nothing DISARMS its file: it loads for no path, silently, and a session editing that area
     gets none of the traps written for it. That is the fail-open shape, decided by source alone. Exit 2.
     A file with no `paths:` key, or no front matter, is reported UNCONDITIONAL BY DESIGN, never a finding.
     Under W2.3 option B (D2, the experiment/rules-split-option-b branch) that is every LEAD file and
     measurement.md, on purpose; each `<name>-depth.md` carries a `paths:` key and loads only after a session
     READS a matching file (the loader matches the path relative to the checkout holding .claude\rules, with
     gitignore semantics, so a slashless entry matches at any depth).

  4. PAIRING - HARD, option B only. A `<name>-depth.md` must be SCOPED, or it loads in every session beside its
     lead and the split buys nothing; and its lead `<name>.md` must EXIST and be UNCONDITIONAL, or the one-line
     rules reach no session that has not read a matching file, which is the fail-open shape of check 2 one file
     over. A lead with no depth file (measurement.md) is fine. With no `-depth.md` file at all the check has
     nothing to judge and says so. Exit 2.

  3. DATED CLAIMS - A REPORT, NOT THE PLANNED RATCHET. A line carrying a date older than $StaleDays is
     listed with the numbers it states, for a person to re-verify and re-date. The plan asked for a
     ratchet here and this deliberately is not one: the count RISES WITH THE CALENDAR while nothing in
     the tree changes, so in run-gates - which the pre-push hook runs - it would turn red on a morning
     nobody touched a rules file and block the ~07:00 bot's deploy push. A gate must be hermetic over
     source. The listing is carried by -Json to the brain report instead, where a person reads it.

  WHAT IS A CLAIM. A date written as a date in prose ("on the 2026-07-30 board", "(2026-09-08, backlog
  I72)"). A date inside a file name or path (`EVAL-hunter-wall-clock-2026-09-04.md`) is not a claim; the
  newest date on a line is the claim's date.

  HOW AN ENTRY IS MATCHED. `git ls-files -- :(glob)<entry>`, and a slashless entry is ALSO tried at any
  depth (`**/<entry>`, the gitignore reading), so an entry is dead only when it matches nothing under
  either reading. That keeps a red from firing on a pattern the loader could still match.

  SCOPE OF A CLEAN REPORT: UNSOUND. The scope-key check is exact for the three spellings it names and
  says nothing about a key it does not know. The paths check says an entry matches SOME tracked file,
  never that it matches the RIGHT ones, and a slashless entry that matches only below the root passes
  even if the loader reads it root-only. A claim written without a date is invisible, and a re-dated
  line that nobody actually re-verified reads as fresh. A finding of checks 1 and 2 is COMPLETE, because
  the match IS the defect: an inert key is inert wherever it appears, and a dead entry matches nothing.

  The pairing check is exact over the file names and the scope it reads, and COMPLETE for the same reason:
  an unscoped depth file loads everywhere and a missing or scoped lead reaches nobody, whatever the text says.

  EXIT: 0 no inert key, every paths: entry matches and every depth file is paired (stale claims are content,
        not a verdict), 2 an inert scope key, a dead paths: entry or a pairing finding, 3 could not evaluate
        (no rules directory, or no git).
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [int]$StaleDays = 90)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$script:DATE_RX = '(?<![\w-])(20\d{2}-[01]\d-[0-3]\d)(?![\w-]|\.(?:md|json|jsonl|txt|log|ps1|py))'
$script:INERT_MSG = 'inert scope key: this file loads unconditionally'

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

function Get-TrackedMatchCount {
  <# Tracked files one loader entry matches: the glob pathspec, and for a slashless entry the any-depth reading
     as well, so an entry is dead only when neither matches (header, HOW AN ENTRY IS MATCHED). #>
  param([string]$Repo, [string]$Entry)
  $hits = @(& git -C $Repo ls-files -- ":(glob)$Entry")
  if ($hits.Count -eq 0 -and -not $Entry.Contains('/')) { $hits = @(& git -C $Repo ls-files -- ":(glob)**/$Entry") }
  return $hits.Count
}

function Get-RuleVerdict {
  <# Checks 1 and 2 for one file's text: Scope (from Get-RuleScope), Counts (entry -> tracked files), Dead. #>
  param([string]$Text, [string]$Repo)
  $sc = Get-RuleScope -Text $Text
  $counts = [ordered]@{}
  $dead = New-Object System.Collections.Generic.List[string]
  foreach ($e in @($sc.Entries)) {
    $n = Get-TrackedMatchCount -Repo $Repo -Entry $e
    $counts[$e] = $n
    if ($n -eq 0) { [void]$dead.Add($e) }
  }
  return [pscustomobject]@{ Scope = $sc; Counts = $counts; Dead = $dead.ToArray() }
}

function Get-RulePairingFindings {
  <# Check 4 over a set of rules files, name -> text. Pure. Returns Findings (strings), Pairs (depth files whose
     lead is present and unconditional and which are themselves scoped) and Depths (how many -depth.md exist). #>
  param([hashtable]$Files)
  $find = New-Object System.Collections.Generic.List[string]
  $pairs = 0; $depths = 0
  foreach ($name in @($Files.Keys | Sort-Object)) {
    if ($name -notmatch '^(.+)-depth\.md$') { continue }
    $depths++
    $leadName = $Matches[1] + '.md'
    $ok = $true
    $ds = Get-RuleScope -Text $Files[$name]
    if ($ds.Scope -ne 'scoped') { [void]$find.Add(("{0}: depth file is UNCONDITIONAL ({1}), so it loads in every session beside its lead" -f $name, $ds.Why)); $ok = $false }
    if (-not $Files.ContainsKey($leadName)) { [void]$find.Add(("{0}: no lead file {1}, so its rules reach no session that has not read a matching path" -f $name, $leadName)); $ok = $false }
    else {
      $ls = Get-RuleScope -Text $Files[$leadName]
      if ($ls.Scope -ne 'unconditional') { [void]$find.Add(("{0}: its lead {1} is SCOPED, so the one-line rules reach no session that has not read a matching path" -f $name, $leadName)); $ok = $false }
    }
    if ($ok) { $pairs++ }
  }
  return [pscustomobject]@{ Findings = $find.ToArray(); Pairs = $pairs; Depths = $depths }
}

function Get-DatedClaims {
  <# One object per line carrying a claim date: Line, Date, AgeDays, Stale, Numbers, Text. #>
  param([string]$Text, [datetime]$Today, [int]$StaleDays)
  $out = New-Object System.Collections.Generic.List[object]
  $lines = $Text -split "`r?`n"
  $start = 0
  if ($lines.Count -gt 1 -and $lines[0].Trim() -eq '---') {
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $start = $i + 1; break } }
  }
  for ($i = $start; $i -lt $lines.Count; $i++) {
    $ms = [regex]::Matches($lines[$i], $script:DATE_RX)
    if ($ms.Count -eq 0) { continue }
    $newest = $null
    foreach ($m in $ms) {
      try { $d = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
      if ($null -eq $newest -or $d -gt $newest) { $newest = $d }
    }
    if ($null -eq $newest) { continue }
    $noDates = [regex]::Replace($lines[$i], '20\d{2}-[01]\d-[0-3]\d', ' ')
    $nums = @([regex]::Matches($noDates, '(?<![\w.-])\d[\d,]*(?:\.\d+)?%?(?![\w-])') | ForEach-Object { $_.Value } | Select-Object -First 6)
    $age = [int]($Today.Date - $newest.Date).TotalDays
    [void]$out.Add([pscustomobject]@{ Line = $i + 1; Date = $newest.ToString('yyyy-MM-dd'); AgeDays = $age
                                      Stale = ($age -gt $StaleDays); Numbers = $nums
                                      Text = $lines[$i].Trim().Substring(0, [math]::Min(110, $lines[$i].Trim().Length)) })
  }
  $a = $out.ToArray()
  return ,$a
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-76} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  # A literal case list knows its own size, so a shortfall is a defect, not a smaller suite.
  $EXPECTED_CASES = 35
  $today = [datetime]'2026-12-01'
  $nl = "`n"

  # ---- check 1: inert scope keys (pure)
  $sG = Get-RuleScope -Text ('---' + $nl + 'description: x' + $nl + 'globs: "grocery/**"' + $nl + '---' + $nl + '# body' + $nl)
  Case 'MUST FIRE' 'globs-only front matter carries an inert scope key and is unconditional' ((($sG.InertKeys -join ',') -eq 'globs') -and $sG.Scope -eq 'unconditional') ("inert={0} scope={1}" -f ($sG.InertKeys -join ','), $sG.Scope)
  # The founding shape: Bun's embedded Cursor template, the text the 2026-09-06 "verification" copied.
  $bun = '---' + $nl + 'description: Use Bun instead of Node.js, npm, pnpm, or vite.' + $nl + 'globs: "*.ts, *.tsx, *.html, *.css, *.js, *.jsx, package.json"' + $nl + 'alwaysApply: false' + $nl + '---' + $nl + 'Default to using Bun.' + $nl
  $sB = Get-RuleScope -Text $bun
  Case 'MUST FIRE' 'the Bun-template shape names both inert keys, and scopes nothing' ((($sB.InertKeys -join ',') -eq 'globs,alwaysApply') -and $sB.Scope -eq 'unconditional') ("inert={0} scope={1}" -f ($sB.InertKeys -join ','), $sB.Scope)
  $sA = Get-RuleScope -Text ('---' + $nl + 'alwaysApply: true' + $nl + '---' + $nl + 'body' + $nl)
  Case 'MUST FIRE' 'alwaysApply: true alone is inert: the loader never reads it' (($sA.InertKeys -join ',') -eq 'alwaysApply') ($sA.InertKeys -join ',')
  $sP = Get-RuleScope -Text ('---' + $nl + 'Paths: "grocery/**"' + $nl + '---' + $nl + 'body' + $nl)
  Case 'MUST FIRE' 'a Paths key in the wrong case is inert: the loader reads paths exactly' ((($sP.InertKeys -join ',') -eq 'Paths') -and $sP.Scope -eq 'unconditional') ("inert={0} scope={1}" -f ($sP.InertKeys -join ','), $sP.Scope)
  $sGb = Get-RuleScope -Text ('# Title' + $nl + 'globs: "grocery/**"' + $nl + 'alwaysApply: false' + $nl)
  Case 'MUST NOT FIRE' 'globs and alwaysApply lines outside a front matter are prose, not keys' (@($sGb.InertKeys).Count -eq 0) ($sGb.InertKeys -join ',')
  $sU = Get-RuleScope -Text ('---' + $nl + 'globs: "x/**"' + $nl + '# no closing fence' + $nl)
  Case 'MUST NOT FIRE' 'an unclosed front matter is body, as the loader reads it' (-not $sU.HasFrontMatter -and @($sU.InertKeys).Count -eq 0) ("fm={0} inert={1}" -f $sU.HasFrontMatter, ($sU.InertKeys -join ','))

  # ---- check 2: the paths parser (pure)
  $sL = Get-RuleScope -Text ('---' + $nl + 'description: x' + $nl + 'paths:' + $nl + '  - "grocery/**"' + $nl + "  - 'ops/*.ps1'" + $nl + '---' + $nl + 'body' + $nl)
  Case 'CLEAN TWIN' 'a paths: YAML block list parses into its entries, trailing /** stripped' ($sL.Scope -eq 'scoped' -and ($sL.Entries -join '|') -eq 'grocery|ops/*.ps1') ("scope={0} entries={1}" -f $sL.Scope, ($sL.Entries -join '|'))
  $sC = Get-RuleScope -Text ('---' + $nl + 'paths: "src/{a,b}.md, lib/**"' + $nl + '---' + $nl)
  Case 'CLEAN TWIN' 'a comma-string paths: splits outside braces and brace-expands' ($sC.Scope -eq 'scoped' -and ($sC.Entries -join '|') -eq 'src/a.md|src/b.md|lib') ($sC.Entries -join '|')
  $sF = Get-RuleScope -Text ('---' + $nl + 'paths: ["grocery/**", ops/*.ps1]' + $nl + '---' + $nl)
  Case 'CLEAN TWIN' 'a flow-list paths: parses into its entries' ($sF.Scope -eq 'scoped' -and ($sF.Entries -join '|') -eq 'grocery|ops/*.ps1') ($sF.Entries -join '|')
  $sS = Get-RuleScope -Text ('---' + $nl + 'paths: "**"' + $nl + '---' + $nl)
  Case 'CLEAN TWIN' 'paths: "**" is reported unconditional, as the loader treats it' ($sS.Scope -eq 'unconditional' -and $sS.Why -match 'only \*\*') ("scope={0} why={1}" -f $sS.Scope, $sS.Why)
  $sN = Get-RuleScope -Text ('# Working in x' + $nl + 'No front matter here.' + $nl)
  Case 'CLEAN TWIN' 'no front matter is reported as unconditional by design' ($sN.Scope -eq 'unconditional' -and $sN.Why -match 'no front matter') ("scope={0} why={1}" -f $sN.Scope, $sN.Why)
  $sD = Get-RuleScope -Text ('---' + $nl + 'description: Rules for x.' + $nl + '---' + $nl + 'body' + $nl)
  Case 'CLEAN TWIN' 'a front matter holding only description: is unconditional by design' ($sD.Scope -eq 'unconditional' -and $sD.Why -eq 'no paths: key' -and $sD.HasFrontMatter) ("scope={0} why={1}" -f $sD.Scope, $sD.Why)
  $sBody = Get-RuleScope -Text ('# Title' + $nl + 'paths: "grocery/**"' + $nl)
  Case 'MUST NOT FIRE' 'a paths line outside a front matter scopes nothing' (-not $sBody.PathsKey -and @($sBody.Entries).Count -eq 0) ("key={0} entries={1}" -f $sBody.PathsKey, ($sBody.Entries -join '|'))

  # ---- check 2: the real matcher, against this checkout's tracked files
  $gitOk = $true
  $null = & git -C $repo rev-parse --verify --quiet HEAD
  if ($LASTEXITCODE -ne 0) { $gitOk = $false }
  Case 'CLEAN TWIN' 'this checkout is a git checkout, so the matcher cases below can look' $gitOk 'git rev-parse HEAD failed'
  $nowhere = 'nowhere-' + 'rule-currency-fixture/**'
  $vL = Get-RuleVerdict -Repo $repo -Text ('---' + $nl + 'paths:' + $nl + '  - "ops/**"' + $nl + ('  - "{0}"' -f $nowhere) + $nl + '---' + $nl)
  Case 'MUST FIRE' 'a paths: YAML-list entry matching no tracked file is dead, beside a live one' ((($vL.Dead -join '|') -eq 'nowhere-rule-currency-fixture') -and $vL.Counts['ops'] -gt 0) ("dead={0} ops={1}" -f ($vL.Dead -join '|'), $vL.Counts['ops'])
  $vOk = Get-RuleVerdict -Repo $repo -Text ('---' + $nl + 'paths:' + $nl + '  - "ops/**"' + $nl + '  - "lib/*.ps1"' + $nl + '---' + $nl)
  Case 'MUST NOT FIRE' 'a paths: list whose entries match tracked files has no dead entry' (@($vOk.Dead).Count -eq 0 -and @($vOk.Scope.Entries).Count -eq 2) ("dead={0} entries={1}" -f ($vOk.Dead -join '|'), ($vOk.Scope.Entries -join '|'))
  $vCs = Get-RuleVerdict -Repo $repo -Text ('---' + $nl + 'paths: "ops/**, .claude/rules/*.md"' + $nl + '---' + $nl)
  Case 'MUST NOT FIRE' 'a comma-string paths: whose entries match tracked files has no dead entry' (@($vCs.Dead).Count -eq 0 -and @($vCs.Scope.Entries).Count -eq 2) ("dead={0} entries={1}" -f ($vCs.Dead -join '|'), ($vCs.Scope.Entries -join '|'))
  $vDeep = Get-RuleVerdict -Repo $repo -Text ('---' + $nl + 'paths: "audit-rule-' + 'currency.ps1"' + $nl + '---' + $nl)
  Case 'MUST NOT FIRE' 'a slashless entry that matches only below the root is not dead' (@($vDeep.Dead).Count -eq 0) ("dead={0}" -f ($vDeep.Dead -join '|'))
  Case 'CLEAN TWIN' 'a paths entry that matches tracked files reports its count' ($vCs.Counts['ops'] -gt 0 -and $vCs.Counts['.claude/rules/*.md'] -ge 1) ("ops={0} rules={1}" -f $vCs.Counts['ops'], $vCs.Counts['.claude/rules/*.md'])

  # ---- check 4: pairing (pure)
  $leadT = '---' + $nl + 'description: lead' + $nl + '---' + $nl + '- one line' + $nl
  $depthT = '---' + $nl + 'description: depth' + $nl + 'paths:' + $nl + '  - "grocery/**"' + $nl + '---' + $nl + 'the account' + $nl
  $pOk = Get-RulePairingFindings -Files @{ 'grocery.md' = $leadT; 'grocery-depth.md' = $depthT; 'measurement.md' = $leadT }
  Case 'MUST NOT FIRE' 'a scoped depth file with an unconditional lead is one clean pair' (@($pOk.Findings).Count -eq 0 -and $pOk.Pairs -eq 1 -and $pOk.Depths -eq 1) ("findings={0} pairs={1}" -f (@($pOk.Findings) -join ';'), $pOk.Pairs)
  $pU = Get-RulePairingFindings -Files @{ 'grocery.md' = $leadT; 'grocery-depth.md' = $leadT }
  Case 'MUST FIRE' 'a depth file with no paths: key loads everywhere and is a finding' (@($pU.Findings).Count -eq 1 -and $pU.Findings[0] -match 'UNCONDITIONAL' -and $pU.Pairs -eq 0) (@($pU.Findings) -join ';')
  $pM = Get-RulePairingFindings -Files @{ 'grocery-depth.md' = $depthT }
  Case 'MUST FIRE' 'a depth file whose lead is missing is a finding' (@($pM.Findings).Count -eq 1 -and $pM.Findings[0] -match 'no lead file grocery\.md') (@($pM.Findings) -join ';')
  $pS = Get-RulePairingFindings -Files @{ 'grocery.md' = $depthT; 'grocery-depth.md' = $depthT }
  Case 'MUST FIRE' 'a depth file whose lead is itself scoped is a finding' (@($pS.Findings).Count -eq 1 -and $pS.Findings[0] -match 'lead grocery\.md is SCOPED') (@($pS.Findings) -join ';')
  $pN = Get-RulePairingFindings -Files @{ 'measurement.md' = $leadT; 'graph.md' = $leadT }
  Case 'CLEAN TWIN' 'leads with no depth file (the option-A shape) have nothing to pair and no finding' (@($pN.Findings).Count -eq 0 -and $pN.Depths -eq 0 -and $pN.Pairs -eq 0) ("findings={0} depths={1}" -f (@($pN.Findings) -join ';'), $pN.Depths)

  # ---- check 3: dated claims
  $cR = Get-DatedClaims -Text ('---' + $nl + 'paths: "a/**"' + $nl + '---' + $nl + 'Measured 2026-08-01: 41 of 492 commodities (8%).') -Today $today -StaleDays 90
  $c = @($cR)
  Case 'MUST FIRE' 'a claim dated more than 90 days ago is stale, with the numbers it states' ($c.Count -eq 1 -and $c[0].Stale -and ($c[0].Numbers -join ' ') -eq '41 492 8%') ("{0} {1}" -f $c.Count, ($c[0].Numbers -join ' '))
  $cR2 = Get-DatedClaims -Text 'See design\EVAL-hunter-wall-clock-2026-09-04.md and comparison-2026-07-30.json for the table.' -Today $today -StaleDays 90
  $c2 = @($cR2)
  Case 'MUST NOT FIRE' 'a date inside a file name is not a claim' ($c2.Count -eq 0) "$($c2.Count)"
  $cR3 = Get-DatedClaims -Text '(2026-09-03, backlog I72) twelve cases' -Today $today -StaleDays 90
  $c3 = @($cR3)
  Case 'MUST NOT FIRE' 'a claim 89 days old is not stale' ($c3.Count -eq 1 -and -not $c3[0].Stale) ("{0} {1}" -f $c3.Count, $c3[0].AgeDays)
  # THE BAR ITSELF (backlog I196). "Older than 90 days" is -gt, so a claim exactly 90 days old is not yet
  # stale and one day more is. 89 and 122 above cannot tell -gt from -ge; these two can.
  $cR3a = Get-DatedClaims -Text '(2026-09-02, backlog I72) twelve cases' -Today $today -StaleDays 90
  $c3a = @($cR3a)
  Case 'MUST NOT FIRE' 'a claim exactly AT the 90-day StaleDays bar is not stale' ($c3a.Count -eq 1 -and $c3a[0].AgeDays -eq 90 -and -not $c3a[0].Stale) ("{0} age={1} stale={2}" -f $c3a.Count, $c3a[0].AgeDays, $c3a[0].Stale)
  $cR3b = Get-DatedClaims -Text '(2026-09-01, backlog I72) twelve cases' -Today $today -StaleDays 90
  $c3b = @($cR3b)
  Case 'MUST FIRE' 'a claim 91 days old, one day past the 90-day StaleDays bar, is stale' ($c3b.Count -eq 1 -and $c3b[0].AgeDays -eq 91 -and $c3b[0].Stale) ("{0} age={1} stale={2}" -f $c3b.Count, $c3b[0].AgeDays, $c3b[0].Stale)
  $cR4 = Get-DatedClaims -Text ('no dates here at all' + $nl + 'nor here, 42 of them') -Today $today -StaleDays 90
  $c4 = @($cR4)
  Case 'MUST NOT FIRE' 'a line with no date is no claim' ($c4.Count -eq 0) "$($c4.Count)"
  $cR6 = Get-DatedClaims -Text ('---' + $nl + 'updated: 2026-01-01' + $nl + '---' + $nl + 'body') -Today $today -StaleDays 90
  $c6 = @($cR6)
  Case 'MUST NOT FIRE' 'a date in the front matter is not a claim' ($c6.Count -eq 0) "$($c6.Count)"
  $cR7 = Get-DatedClaims -Text 'could not reach that on the 2026-07-30 board' -Today $today -StaleDays 90
  $c7 = @($cR7)
  Case 'CLEAN TWIN' 'a date written in prose IS a claim, with its date' ($c7.Count -eq 1 -and $c7[0].Date -eq '2026-07-30') "$($c7.Count)"
  $cR8 = Get-DatedClaims -Text 'ruled 2026-09-01, re-measured 2026-11-20: 7 of 9' -Today $today -StaleDays 90
  $c8 = @($cR8)
  Case 'CLEAN TWIN' 'the newest date on a line is the claim date, and the numbers exclude the dates' ($c8[0].Date -eq '2026-11-20' -and ($c8[0].Numbers -join ' ') -eq '7 9') ("{0} {1}" -f $c8[0].Date, ($c8[0].Numbers -join ' '))
  $rules = @(Get-ChildItem (Join-Path $repo '.claude\rules') -File -Filter '*.md' -ErrorAction SilentlyContinue)
  Case 'CLEAN TWIN' 'the population is .claude\rules\*.md, and it is not empty' ($rules.Count -gt 0) "$($rules.Count)"

  Case 'CLEAN TWIN' ('the suite ran all {0} of its literal cases' -f $EXPECTED_CASES) (($ran.Count + 1) -eq $EXPECTED_CASES) ("ran {0} before this case" -f $ran.Count)
  Write-Output ''
  if ($fails.Count) {
    Write-Output ("audit-rule-currency selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'RULE-CURRENCY-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("audit-rule-currency selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'RULE-CURRENCY-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
$rulesDir = Join-Path $repo '.claude\rules'
$files = @(Get-ChildItem $rulesDir -File -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($files.Count -eq 0) {
  Write-Output 'RULE CURRENCY BLIND: no .claude\rules\*.md - nothing was judged, which is not every rule loading.'
  if ($Json) { 'rule-currency-json: {"known": false}' }
  Exit-Guard -Name 'RULE-CURRENCY' -Code 3 -Summary 'files=0 blind=1'
}
$null = & git -C $repo rev-parse --verify --quiet HEAD
if ($LASTEXITCODE -ne 0) {
  Write-Output 'RULE CURRENCY BLIND: not a git checkout, so no paths: entry can be matched against tracked files.'
  if ($Json) { 'rule-currency-json: {"known": false}' }
  Exit-Guard -Name 'RULE-CURRENCY' -Code 3 -Summary "files=$($files.Count) blind=1"
}

$today = Get-Date
$nPaths = 0; $nUncond = 0
$inertF = New-Object System.Collections.Generic.List[string]
$dead = New-Object System.Collections.Generic.List[string]
$claims = New-Object System.Collections.Generic.List[object]
Write-Output "RULE CURRENCY - does any rules file carry a scope key the loader ignores, does every paths: entry load for something, and which dated claims are older than $StaleDays days?"
Write-Output ''
foreach ($f in $files) {
  $text = [IO.File]::ReadAllText($f.FullName)
  $v = Get-RuleVerdict -Text $text -Repo $repo
  $sc = $v.Scope
  $parts = @()
  if (@($sc.InertKeys).Count -gt 0) {
    [void]$inertF.Add(("{0}: {1} ({2})" -f $f.Name, $script:INERT_MSG, ($sc.InertKeys -join ', ')))
    $parts += ("INERT {0} - {1}" -f ($sc.InertKeys -join ', '), $script:INERT_MSG)
  }
  if ($sc.Scope -eq 'unconditional') {
    $nUncond++
    $parts += ("UNCONDITIONAL - {0}, so it loads in every session" -f $sc.Why)
  }
  foreach ($e in $v.Counts.Keys) {
    $nPaths++
    $parts += ("{0}={1}" -f $e, $v.Counts[$e])
    if ($v.Counts[$e] -eq 0) { [void]$dead.Add("$($f.Name): $e") }
  }
  Write-Output ("  {0,-22} {1}" -f $f.Name, ($parts -join '  '))
  $cR = Get-DatedClaims -Text $text -Today $today -StaleDays $StaleDays
  foreach ($c in @($cR)) { $c | Add-Member -NotePropertyName File -NotePropertyValue $f.Name; [void]$claims.Add($c) }
}
$texts = @{}
foreach ($f in $files) { $texts[$f.Name] = [IO.File]::ReadAllText($f.FullName) }
$pairing = Get-RulePairingFindings -Files $texts
if ($pairing.Depths -eq 0) { Write-Output '  pairing: no -depth.md file, so no lead/depth pair to judge (the option-A shape)' }
else { Write-Output ("  pairing: {0} of {1} depth file(s) scoped with an unconditional lead" -f $pairing.Pairs, $pairing.Depths) }
$stale = @($claims | Where-Object { $_.Stale } | Sort-Object Date)
$oldest = if ($claims.Count) { (@($claims | Sort-Object Date))[0].Date } else { $null }
Write-Output ''
Write-Output ("  dated claims: {0} across {1} file(s), {2} older than {3} days, oldest {4}" -f $claims.Count, $files.Count, $stale.Count, $StaleDays, $(if ($oldest) { $oldest } else { 'none' }))
foreach ($s in ($stale | Select-Object -First 20)) {
  Write-Output ("    STALE {0}:{1} dated {2} ({3}d) states [{4}] - {5}" -f $s.File, $s.Line, $s.Date, $s.AgeDays, ($s.Numbers -join ', '), $s.Text)
}
if ($Json) {
  'rule-currency-json: ' + (([ordered]@{ known = $true; files = $files.Count; inert_files = $inertF.Count; paths = $nPaths
                                           dead_paths = $dead.Count; unconditional = $nUncond
                                           depth_files = $pairing.Depths; pairs = $pairing.Pairs; pairing_findings = @($pairing.Findings).Count
                                           dated_claims = $claims.Count; stale_claims = $stale.Count; oldest_claim = $oldest }) | ConvertTo-Json -Compress)
}
$pairFind = @($pairing.Findings)
$summary = "files=$($files.Count) inert=$($inertF.Count) paths=$nPaths dead=$($dead.Count) unconditional=$nUncond depth=$($pairing.Depths) pairs=$($pairing.Pairs) pairing=$($pairFind.Count) dated=$($claims.Count) stale=$($stale.Count)"
if ($inertF.Count -or $dead.Count -or $pairFind.Count) {
  Write-Output ''
  if ($inertF.Count) {
    Write-Output ("RULE CURRENCY FAILED: {0} file(s) carry a scope key the Claude Code loader never reads (it reads paths: only):" -f $inertF.Count)
    $inertF | ForEach-Object { Write-Output "    $_" }
  }
  if ($dead.Count) {
    Write-Output ("RULE CURRENCY FAILED: {0} paths: entr(y/ies) match no tracked file, so their rules load for nothing:" -f $dead.Count)
    $dead | ForEach-Object { Write-Output "    $_" }
  }
  if ($pairFind.Count) {
    Write-Output ("RULE CURRENCY FAILED: {0} lead/depth pairing finding(s):" -f $pairFind.Count)
    $pairFind | ForEach-Object { Write-Output "    $_" }
  }
  Exit-Guard -Name 'RULE-CURRENCY' -Code 2 -Summary $summary
}
Write-Output ("rule-currency: PASSED - no inert scope key in {0} file(s); all {1} paths: entr(y/ies) match tracked files; {2} file(s) unconditional by design; {3} of {4} depth file(s) paired. Stale claims above are for a person, not a verdict." -f $files.Count, $nPaths, $nUncond, $pairing.Pairs, $pairing.Depths)
Exit-Guard -Name 'RULE-CURRENCY' -Code 0 -Summary $summary
