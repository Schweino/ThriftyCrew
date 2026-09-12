# ps-source.ps1 - THE one way to reduce PowerShell source to the part that actually runs.
#
# STANDING RULE, AND IT BINDS THE NEXT PERSON TO REWRITE THIS FILE (Brad's ruling, 2026-09-12,
# backlog I154). This estate has THREE source reducers: this one, lib\production-text.ps1 (AST, drops
# the body of a self-test clause, keeps comments), and Get-McBlankedText inside
# ops\audit-mustfire-census.ps1 (tokens, blanks every comment in place and keeps offsets). Measured
# 2026-09-12 by reading all three: NOT ONE OF THEM BLANKS A STRING LITERAL, which is why
# .claude\rules\ops-and-gates.md has to carry "a self-test that greps its own source cannot fail -
# build needles by concatenation". That rule is a WORKAROUND FOR A MISSING LEXER: a reducer that
# blanked string contents could not match inside one at all. Brad ruled: do NOT retrofit the switch
# now and do NOT re-fixture the callers for it alone, because the change it was written to protect has
# already shipped. What he ruled instead is the trigger, and this is it - THE NEXT REWRITE OF ANY OF
# THE THREE, FOR ANY REASON, CONSOLIDATES THEM INTO ONE TOKEN-BASED REDUCER IN lib\ THAT BLANKS
# COMMENTS BY DEFAULT AND STRING-LITERAL CONTENTS BEHIND A SWITCH, AND MOVES THE CALLERS IT TOUCHES
# ONTO IT IN THE SAME CHANGE. Adding the string half later costs a SECOND re-fixturing of every
# caller, which is the whole reason this is written now. If you are here to rewrite this file, that
# consolidation is your change and not a follow-up item. Until then the concatenation rule stands
# exactly as written, and nothing gates this: no detector can tell a rewrite from a one-line fix.
#
# WHY THIS EXISTS (2026-09-07). ops\run-gates.ps1 decides which scripts have a -SelfTest by matching
# `[switch]$SelfTest` against the file's source. On 2026-09-01 it learned to strip comments first,
# because a comment DISCUSSING the switch had enrolled run-gates in its own discovery and spawned 18
# copies of itself. The fix stripped LINE comments only:
#
#     ($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
#
# A `<# ... #>` header is not a line comment. So a block header explaining why a file has NO self-test
# enrolled it AS one, and run-gates then reported green coverage for a self-test that does not exist -
# the same shape as the bug it was fixing, one comment syntax over. Nine other places in the estate
# reduce source the same way before matching a declaration or a call.
#
# THE ASYMMETRY, and it is why this is worth a shared file rather than nine copies: a stripper that
# removes too little ENROLS prose as code (a check fires on its own documentation, or counts a file it
# should not); a stripper that removes too much DELETES code (a check goes silently blind). Both look
# like a pass from outside. One implementation, fixtured once.
#
# IT IS A TOKENIZER NOW, AND IT IS NOT FREE - THE OLD HEADER WAS HALF RIGHT (2026-09-12). This header
# used to say that running the real tokenizer on every file "costs more than the gate can afford", and
# the tokenize CALL refutes that: over all 769 tracked .ps1 (13,519,573 characters), every file read
# into memory first so no arm pays for disk, arms rotated each round, five rounds, this box shared:
#
#     PSParser::Tokenize, the call alone     702 / 645 / 653 / 808 / 910 ms      median   702
#     Get-PsCodeOnlyFallback, the regex pair 1,661 / 1,636 / 1,633 / 1,844 / 1,982 ms   median 1,661
#     Get-PsCodeOnly, the whole token rung   5,147 / 5,076 / 5,120 / 5,232 / 5,675 ms   median 5,147
#
# So tokenizing is 2.4x FASTER than the regex pair, and the reduction BUILT ON IT is 3.1x SLOWER, and
# both are true at once. The regex rung's entire output falls out of two .NET calls; the token rung has
# to assemble the output in PowerShell, one statement per comment, and this estate is heavily commented.
# The gap is the assembly, not the lexer, and PS 5.1 is where it is paid. In the real callers, four
# rounds each with the arms alternated, medians: run-gates' discovery pass over every tracked script
# went from 2,318 ms to 7,155 ms, ops\audit-git-fixture-env.ps1 from 3,434 to 7,933 ms, and
# ops\audit-cpu-load.ps1 from 6,121 to 9,992 ms. About four seconds per full-tree pass, on a gate run
# that takes minutes. That is the price, stated rather than hidden.
#
# WHAT IT BUYS. Three defects in eleven days, each a comment syntax the character rung could not see:
# 2026-09-01 run-gates enrolled itself off a comment and spawned 18 copies; 2026-09-07 a block header
# enrolled a file as having a self-test it does not have; 2026-09-11 Get-MustFireCount read a block
# comment's opening line as code, and was fixed by calling the tokenizer privately inside one audit -
# paying for the very thing this header called unaffordable, in one place, where nothing else could
# reuse it.
#
# WHAT THE TOKEN RUNG SEES THAT THE CHARACTER RUNG COULD NOT. A `<#` or a `#>` inside a string is a
# string, not a comment delimiter, and a line that begins with `#` inside a here-string or a multi-line
# double-quoted string is DATA, not a comment. The regex pair got every one of those wrong, always in
# the DELETES-CODE direction: it blanked from a quoted `<#` to the next real `#>` and took whatever ran
# in between with it, and it dropped here-string lines out from under their own terminator. The
# self-test below carries one frozen case per shape.
#
# AND THE DIRECTION WAS MEASURED, not assumed. Both rungs were run over all 769 tracked .ps1 and
# compared byte for byte: 25 of 769 files differ, 105 lines in all, and EVERY ONE of the 105 is a line
# the character rung DELETED and this one keeps - 105 of 105 that way, 0 the other. Not one is prose the
# character rung enrolled as code. Each was adjudicated by asking the tokenizer which token covers the
# line's first non-blank character: 61 String, 28 Variable, 8 GroupStart, 5 Command, 3 Keyword, and
# not one Comment. That is the asymmetry above landing on the safe side - the old rung's failure in a file
# that PARSES is always to cut live text out, because a header's opening line can only survive its regex
# when an earlier match ended after it, and such a match must have swallowed that header's own `<#`.
#
# THE OUTPUT CONTRACT IS UNCHANGED, deliberately - dozens of callers match against it:
#   * a BLOCK comment is blanked, keeping its own newlines, so a caller that checks indentation or
#     reads the line before a match still sees the same shape;
#   * a WHOLE-LINE comment is DROPPED, line and all;
#   * a TRAILING comment is KEPT, exactly as before. The tokenizer could now strip those safely, which
#     the regex never could, but that would change what every caller sees. Named here as available and
#     not taken, so the limit stays a decision rather than a surprise.
#
# A FILE THAT DOES NOT TOKENIZE FALLS BACK to the old character rung rather than throwing, so a broken
# file still reduces. Get-PsCodeOnlyFallback is that rung, kept whole and fixtured.
#
# SCOPE OF A CLEAN REDUCTION: SOUND for comment removal in any file PSParser accepts - PowerShell's own
# lexer decides what a comment is, so nothing quoted can be mistaken for one. UNSOUND for a file that
# does not tokenize, which is reduced by the old regex pair and carries every one of its defects.
#
# THIS FILE DECLARES NO param() BLOCK, DELIBERATELY: in PS 5.1 dot-sourcing runs a param() block in the
# CALLER's scope, so a param([switch]$SelfTest) here would reset every caller's own -SelfTest. The
# self-test is gated on the dot-sourced form instead, which lib\selftest-discovery.ps1 enrols by name.
$__psSourceSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-PsCodeOnlyFallback {
  # THE OLD CHARACTER RUNG, kept for files that do not tokenize. Comment delimiters are found by regex,
  # so a `<#` inside a single-quoted string is treated as a comment opener here and everything to the
  # next `#>` is deleted. That is wrong, and it is still the right answer for an unparseable file:
  # there is no lexer to ask, and removing too much is the direction the callers already survived.
  param([string]$Text)
  if ($null -eq $Text) { return '' }
  # Block comments first, keeping their newlines.
  $t = [regex]::Replace($Text, '(?s)<#.*?#>', {
    param($m)
    ($m.Value -replace '[^\r\n]', '')
  })
  # WHOLE-LINE comments only, never a trailing `#`. Stripping to end-of-line on any `#` would eat the
  # hash inside a quoted string - `$x -replace '#',''` - and take the rest of that line's code with it,
  # which unbalances brace and paren counting for every caller downstream. audit-write-only-reports
  # carries a fixture for exactly that shape. Matching the estate's existing, proven semantics.
  return (($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
}

function Get-PsCodeOnly {
  # Source with BLOCK comments blanked and whole-line comments dropped, decided by PowerShell's own
  # lexer rather than by a pattern over characters.
  #
  # THIS DOC IS LINE COMMENTS ON PURPOSE, and that is not a style choice. The first cut wrote it as a
  # block comment and spelled the closing delimiter inside its own prose while explaining the rule -
  # which CLOSED the comment there, dropped the rest of the sentence into the parser as code, and made
  # the file fail to parse. A file about comment syntax is the one file that cannot be careless with it.
  param([string]$Text)
  if ($null -eq $Text) { return '' }
  if ($Text.Length -eq 0) { return '' }

  $errs = $null
  $tokens = $null
  try {
    $tokens = [System.Management.Automation.PSParser]::Tokenize($Text, [ref]$errs)
  } catch {
    return (Get-PsCodeOnlyFallback -Text $Text)
  }
  if ($null -eq $tokens) { return (Get-PsCodeOnlyFallback -Text $Text) }
  # PS 5.1: @($null).Count is 1, so the null is tested before the wrap ([[ps-null-count-is-one]]).
  $errCount = 0
  if ($null -ne $errs) { $errList = @($errs); $errCount = $errList.Count }
  if ($errCount -gt 0) { return (Get-PsCodeOnlyFallback -Text $Text) }

  # NOT ONE LOOP HERE RUNS PER CHARACTER OR PER LINE, AND THAT IS THE WHOLE COST STORY (2026-09-12). The
  # first cut of this rewrite walked the file character by character in PowerShell and made run-gates' own
  # discovery pass 2.8x SLOWER than the regex it replaced - 7,027 ms against 2,517 ms over 769 files - even
  # though the tokenize call is FASTER than the regex pair (1,106 ms against 2,818 ms on the same corpus).
  # PS 5.1 pays about a microsecond per interpreted statement, so anything running once per character, or
  # once per line, loses to a .NET regex however good the algorithm is. Every loop below runs once per
  # COMMENT: the scan is [Array]::IndexOf over the token types, and the output is built in ONE pass with
  # Substring and Append, with no split, no per-line filter and no join at the end.
  $n = $Text.Length
  $types = $tokens.Type
  if ($null -eq $types) { return $Text.Replace("`r`n", "`n") }
  # THE COMMENTS ARE FOUND BY [Array]::IndexOf OVER THE TYPES, so the per-token scan runs in .NET and only
  # the comments cost a PowerShell statement. Measured 2026-09-12 over the same 769 files: pulling
  # $tokens.Start and $tokens.Length as arrays too, to save the two property reads below, was 1.2 s SLOWER
  # than reading them - materialising three arrays of every token costs more than it saves.
  $typeArr = [object[]]$types
  $commentType = [System.Management.Automation.PSTokenType]::Comment
  $cStart = New-Object System.Collections.Generic.List[int]
  $cLen = New-Object System.Collections.Generic.List[int]
  $bStart = New-Object System.Collections.Generic.List[int]
  $bEnd = New-Object System.Collections.Generic.List[int]
  $ti = 0
  while ($true) {
    $ti = [Array]::IndexOf($typeArr, $commentType, $ti)
    if ($ti -lt 0) { break }
    $tk = $tokens[$ti]
    $s = [int]$tk.Start
    $len = [int]$tk.Length
    $ti++
    if ($len -le 0 -or $s -lt 0 -or ($s + $len) -gt $n) { continue }
    $cStart.Add($s)
    $cLen.Add($len)
    if ($Text[$s] -eq '<') { $bStart.Add($s); $bEnd.Add($s + $len) }
  }
  $comments = $cStart
  # CRLF FOLDS TO LF AND A LONE CR SURVIVES, which is exactly what `-split "`r?`n"` then `-join "`n"` did:
  # that pair consumes a CR only when an LF follows it. One .NET Replace is the same transformation.
  if ($comments.Count -eq 0) { return $Text.Replace("`r`n", "`n") }

  $sb = New-Object System.Text.StringBuilder $n
  $prev = 0
  $nb = $bStart.Count
  for ($ci = 0; $ci -lt $comments.Count; $ci++) {
    $s = $cStart[$ci]
    $len = $cLen[$ci]
    if ($Text[$s] -eq '<') {
      # A BLOCK comment is BLANKED to its own newlines, so every caller's line numbering survives.
      if ($s -gt $prev) { [void]$sb.Append($Text, $prev, $s - $prev) }
      [void]$sb.Append([regex]::Replace($Text.Substring($s, $len), '[^\r\n]', ''))
      $prev = $s + $len
      continue
    }
    # A LINE comment is DROPPED WHOLE, line and all, only when nothing but whitespace precedes it on its
    # line - the estate's existing semantic, under which a TRAILING comment is kept, hash and all. The
    # second reading below only runs for the rare line where a block comment really does sit in front of
    # a `#`, which is the post-blank case `<# x #># y` the old rung dropped.
    # THE CHEAP HALF FIRST: a TRAILING comment - the common case - is decided by the one character in front
    # of it, with no scan back to the line start at all. A `>` is the one character that cannot settle it,
    # because a block comment ends in `#>` and `<# x #># y` is a line the old rung DID drop.
    $before = ' '
    if ($s -gt 0) { $before = $Text[$s - 1] }
    if ($before -ne '>' -and -not [char]::IsWhiteSpace($before)) { continue }
    $ls = 0
    if ($s -gt 0) { $ls = $Text.LastIndexOf("`n", $s - 1) + 1 }
    $whole = [string]::IsNullOrWhiteSpace($Text.Substring($ls, $s - $ls))
    $overlaps = $false
    if (-not $whole) {
      for ($bi = 0; $bi -lt $nb; $bi++) {
        if ($bStart[$bi] -lt $s -and $bEnd[$bi] -gt $ls) { $overlaps = $true; break }
      }
    }
    if ($overlaps) {
      $covered = $true
      $at = $ls
      while ($at -lt $s) {
        if ([char]::IsWhiteSpace($Text[$at])) { $at++; continue }
        $inBlock = $false
        for ($bi = 0; $bi -lt $nb; $bi++) {
          if ($at -ge $bStart[$bi] -and $at -lt $bEnd[$bi]) { $at = $bEnd[$bi]; $inBlock = $true; break }
        }
        if (-not $inBlock) { $covered = $false; break }
      }
      $whole = $covered
    }
    if (-not $whole) { continue }
    $eol = $Text.IndexOf("`n", $s)
    $stop = [Math]::Max($prev, $ls)
    if ($eol -lt 0) {
      # THE LAST LINE, with no terminator after it. Dropping it takes the SEPARATOR before it too, because
      # the old rung rebuilt the file by joining the surviving lines.
      if ($stop -gt $prev) { [void]$sb.Append($Text, $prev, $stop - $prev) }
      if ($sb.Length -gt 0 -and $sb[$sb.Length - 1] -eq "`n") { [void]$sb.Remove($sb.Length - 1, 1) }
      if ($sb.Length -gt 0 -and $sb[$sb.Length - 1] -eq "`r") { [void]$sb.Remove($sb.Length - 1, 1) }
      $prev = $n
      break
    }
    if ($stop -gt $prev) { [void]$sb.Append($Text, $prev, $stop - $prev) }
    $prev = $eol + 1
  }
  if ($prev -lt $n) { [void]$sb.Append($Text, $prev, $n - $prev) }
  return $sb.ToString().Replace("`r`n", "`n")
}

function Get-PsCodeLines {
  <# The same reduction, as an array of lines, for callers that filter rather than match. #>
  param([string]$Text)
  return @((Get-PsCodeOnly -Text $Text) -split "`n")
}

function Get-PsBlockCommentsBlanked {
  # BLOCK comments blanked to their own newlines and NOTHING ELSE: every line of the input survives, line
  # comments included, and line endings are left exactly as they came in. For a caller that REPORTS A LINE
  # NUMBER, which Get-PsCodeOnly cannot serve, because it drops whole-line comments and so shifts every
  # line after the first one.
  #
  # WHY (2026-09-12). ops\verify-bulk-edit.ps1's order check stripped `#` line comments per line and reported
  # "calls Read-JsonFile at top level on line 47" for prose INSIDE a header block, where no line starts with
  # a hash. The commit was refused over a sentence. That caller keeps its own per-line handling of strings
  # and line comments, so it needs the block half alone, with the numbering intact.
  #
  # Same lexer, same fallback direction as Get-PsCodeOnly: a file PSParser refuses is blanked by the regex
  # half of the character rung, which removes too much rather than too little.
  param([string]$Text)
  if ($null -eq $Text) { return '' }
  if ($Text.Length -eq 0) { return '' }
  $errs = $null
  $tokens = $null
  try { $tokens = [System.Management.Automation.PSParser]::Tokenize($Text, [ref]$errs) } catch { $tokens = $null }
  $errCount = 0
  if ($null -ne $errs) { $errList = @($errs); $errCount = $errList.Count }
  if ($null -eq $tokens -or $errCount -gt 0) {
    return [regex]::Replace($Text, '(?s)<#.*?#>', { param($m) ($m.Value -replace '[^\r\n]', '') })
  }
  $types = $tokens.Type
  if ($null -eq $types) { return $Text }
  $typeArr = [object[]]$types
  $commentType = [System.Management.Automation.PSTokenType]::Comment
  $n = $Text.Length
  $sb = New-Object System.Text.StringBuilder $n
  $prev = 0
  $ti = 0
  while ($true) {
    $ti = [Array]::IndexOf($typeArr, $commentType, $ti)
    if ($ti -lt 0) { break }
    $tk = $tokens[$ti]
    $ti++
    $s = [int]$tk.Start
    $len = [int]$tk.Length
    if ($len -le 0 -or $s -lt $prev -or ($s + $len) -gt $n) { continue }
    if ($Text[$s] -ne '<') { continue }
    if ($s -gt $prev) { [void]$sb.Append($Text, $prev, $s - $prev) }
    [void]$sb.Append([regex]::Replace($Text.Substring($s, $len), '[^\r\n]', ''))
    $prev = $s + $len
  }
  if ($prev -lt $n) { [void]$sb.Append($Text, $prev, $n - $prev) }
  return $sb.ToString()
}

if ($__psSourceSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:psFail = 0
  $script:psCases = 0
  function Test-PsSourceCase {
    # A case that THROWS is a counted failure, never a skipped line: a suite whose cases all error must
    # not print PASS over nothing ([[a self-test can run ZERO cases and exit 0]]). The helper is named
    # in full for the same reason - a one-letter name resolves to a built-in ALIAS before a function.
    param([string]$Label, [scriptblock]$Check)
    $script:psCases++
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Label = $Label + ' (threw: ' + $_.Exception.Message + ')' }
    if ($ok) { Write-Output ('  PASS  ' + $Label) } else { Write-Output ('  FAIL  ' + $Label); $script:psFail++ }
  }
  # THE FIXTURES WRITE `~` FOR `$` so this file's own source never spells a declaration that
  # lib\selftest-discovery.ps1 or ops\run-gates.ps1 would read out of it
  # ([[selftest-greps-its-own-source]]).
  function New-PsSourceText { param([string[]]$Lines) return (($Lines -join "`n").Replace('~', '$')) }

  # ONE directory per run, removed in finally: run-gates runs every -SelfTest in the tree and several
  # sessions push at once, so a fixed name under %TEMP% is another run's file
  # ([[a self-test names every temp path PER RUN]]). The name is kept short because every character
  # lands on every fixture path and PS 5.1 stops at 260.
  $psDir = Join-Path ([IO.Path]::GetTempPath()) ('pss-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -ErrorAction Stop $psDir | Out-Null
  try {
    # ---- MUST FIRE 1: a `<#` inside a SINGLE-QUOTED string ------------------------------------------
    # The exact case this file's old header named as its known limit. The regex rung opens a comment at
    # the quoted `<#`, runs to the next real `#>` two lines down, and DELETES the assignment in between.
    $fxQuotedOpen = New-PsSourceText -Lines @(
      '~opener = ''<# this is a string, not a comment''',
      '~live = 1',
      '<# a real header',
      '   with prose #>',
      '~after = 2')
    Test-PsSourceCase 'MUST FIRE  a <# inside a single-quoted string is a string: the assignment after it survives, and the real header is still blanked' {
      $code = Get-PsCodeOnly -Text $fxQuotedOpen
      $old = Get-PsCodeOnlyFallback -Text $fxQuotedOpen
      ($code -match '~live = 1'.Replace('~', '\$')) -and ($code -match '\$opener') -and
      ($code -notmatch 'a real header') -and ($old -notmatch '\$live = 1')
    }

    # ---- MUST FIRE 2: a `#` inside a DOUBLE-QUOTED string, at the start of a line --------------------
    # A multi-line double-quoted string whose second line begins with a hash. The regex rung drops that
    # line, which takes a line of DATA out of the string and unbalances the quote for every caller after.
    $fxQuotedHash = New-PsSourceText -Lines @(
      '~banner = "first line',
      '#second line is data, not a comment',
      'third line"',
      '~live = 3')
    Test-PsSourceCase 'MUST FIRE  a # opening a line INSIDE a double-quoted string is data: the line survives, where the character rung dropped it' {
      $code = Get-PsCodeOnly -Text $fxQuotedHash
      $old = Get-PsCodeOnlyFallback -Text $fxQuotedHash
      ($code -match 'second line is data') -and ($old -notmatch 'second line is data')
    }

    # ---- MUST FIRE 3: a HERE-STRING carrying BOTH -----------------------------------------------------
    # The worst of the three, because the regex rung deletes the here-string's own TERMINATOR: it blanks
    # from the quoted `<#` through the next `#>`, and separately drops the `#` line. Either one alone
    # leaves a caller counting quotes that no longer balance.
    $fxHere = New-PsSourceText -Lines @(
      '~doc = @''',
      '<# an example header',
      '# an example line comment',
      'plain text #>',
      '''@',
      '~live = 4')
    Test-PsSourceCase 'MUST FIRE  a here-string holding both a <# and a whole-line # keeps all five of its lines, where the character rung emptied three' {
      $code = Get-PsCodeOnly -Text $fxHere
      $old = Get-PsCodeOnlyFallback -Text $fxHere
      ($code -match 'an example header') -and ($code -match 'an example line comment') -and
      ($code -match 'plain text') -and ($code -match "'@") -and
      ($old -notmatch 'an example header') -and ($old -notmatch 'an example line comment') -and
      ($old -notmatch 'plain text')
    }

    # ---- MUST FIRE 4: a block comment whose OPENING LINE looks like a declaration, inside a fixture ----
    # The live shape, found in the differential over all 769 tracked .ps1: ops\audit-run-log-claims.ps1 and
    # ops\audit-arg-binding.ps1 both freeze a FIXTURE whose text is a header opening on a declaration. The
    # character rung blanks that header as though it were this file's own comment and the fixture silently
    # loses the line it exists to carry. To the tokenizer the whole thing is one string token.
    #
    # AND THE DIRECTION IS WORTH STATING, because it is not the one this library's callers fear most: over
    # all 769 tracked files, EVERY line the two rungs disagreed about was one the character rung DELETED.
    # Not one was prose it enrolled. A block comment's opening line can only survive the old regex when a
    # previous match ended after it, and such a match must have swallowed its own `<#` first - so in a file
    # that parses, the old rung cannot leave a header standing. It can only cut live text out.
    $fxDecl = New-PsSourceText -Lines @(
      '~fixture = @''',
      '<# param([switch]~SelfTest) - the line this frozen fixture exists to carry',
      '#>',
      'Write-Output 1',
      '''@',
      '~live = 5')
    Test-PsSourceCase 'MUST FIRE  a frozen fixture whose text opens on a declaration keeps that line, where the character rung blanked the fixture''s own header away' {
      $code = Get-PsCodeOnly -Text $fxDecl
      $old = Get-PsCodeOnlyFallback -Text $fxDecl
      ($code -match '\[switch\]\$SelfTest') -and ($code -match '\$live = 5') -and
      ($old -notmatch '\[switch\]\$SelfTest')
    }

    # ---- CLEAN TWIN: ordinary code both rungs already handled -----------------------------------------
    # The positive assertion. Everything the character rung was right about must still be right: a block
    # header blanked to its own newlines, a whole-line comment dropped, a TRAILING comment kept, and the
    # line count of the blanked header preserved so an indentation check still sees the same shape.
    $fxOrdinary = New-PsSourceText -Lines @(
      '<# header line one',
      '   header line two #>',
      '# a whole-line comment',
      '  # an indented whole-line comment',
      '~x = 1 # a trailing comment',
      'function Get-Thing { 2 }')
    Test-PsSourceCase 'CLEAN TWIN  ordinary source reduces byte for byte as the character rung reduced it' {
      $code = Get-PsCodeOnly -Text $fxOrdinary
      $old = Get-PsCodeOnlyFallback -Text $fxOrdinary
      [string]::Equals($code, $old, [StringComparison]::Ordinal)
    }
    Test-PsSourceCase 'CLEAN TWIN  a block header keeps its newlines, a whole-line comment is dropped, and a TRAILING comment is kept' {
      $lines = @(Get-PsCodeLines -Text $fxOrdinary)
      ($lines.Count -eq 4) -and ($lines[0] -eq '') -and ($lines[1] -eq '') -and
      ($lines[2] -eq '$x = 1 # a trailing comment') -and ($lines[3] -match 'function Get-Thing')
    }
    Test-PsSourceCase 'CLEAN TWIN  a line comment that FOLLOWS a block comment on the same line still drops the whole line' {
      # `<# x #># y` reads as a whole-line comment only once the block in front of it is blanked. The
      # character rung got this right by blanking first and testing second, and so must this one.
      $fxAfterBlock = New-PsSourceText -Lines @('~live = 9', '<# x #># y', '~after = 10')
      $code = Get-PsCodeOnly -Text $fxAfterBlock
      $old = Get-PsCodeOnlyFallback -Text $fxAfterBlock
      ($code -notmatch '# y') -and ($code -match '\$live = 9') -and ($code -match '\$after = 10') -and
      [string]::Equals($code, $old, [StringComparison]::Ordinal)
    }
    Test-PsSourceCase 'CLEAN TWIN  CRLF source reduces to LF, as every caller already reads it' {
      $crlf = "<# h #>`r`n# drop me`r`n`$x = 1`r`n"
      $code = Get-PsCodeOnly -Text $crlf
      ($code -notmatch "`r") -and (@($code -split "`n") -contains '$x = 1')
    }
    Test-PsSourceCase 'CLEAN TWIN  an empty string and a null reduce to an empty string rather than throwing' {
      ((Get-PsCodeOnly -Text '') -eq '') -and ((Get-PsCodeOnly -Text $null) -eq '')
    }

    # ---- MUST FIRE 5: a LONE CARRIAGE RETURN inside a string ------------------------------------------
    # Found by the differential over all 769 tracked .ps1 on 2026-09-12, and it was a real regression in the
    # first cut of this rewrite. PowerShell's lexer counts a bare CR as a line break; `-split "`r?`n"` does
    # not. Taking a comment's line number from PSToken.StartLine therefore ran one line high after the first
    # such character, and grocery\audit-script-census.ps1 - the one tracked file that carries one - lost a
    # row of its $KNOWN table while keeping the comment above it.
    # THE CLASS IS NOW CLOSED BY CONSTRUCTION, not by this case, and the mutation probe said so: there are
    # no line NUMBERS left in the reduction at all - the output is built from offsets in one pass - and a
    # mutant that widened the line-start search to treat a lone CR as a break SURVIVED, because for a CR to
    # decide a comment's line start, everything between it and the `#` must be whitespace, and a CR inside
    # a string always has that string's closing quote after it. The case stays as a regression guard over
    # the whole reduction (it goes red when line comments stop being dropped), not as a guard over a rule
    # that no longer exists.
    $fxLoneCr = '$s = ''a' + [char]13 + 'b''' + "`n" + '# drop this comment line' + "`n" + '$live = 8' + "`n"
    Test-PsSourceCase 'MUST FIRE  a lone CR inside a string does not shift the line numbering: the comment is dropped and the code line after it survives' {
      $code = Get-PsCodeOnly -Text $fxLoneCr
      $old = Get-PsCodeOnlyFallback -Text $fxLoneCr
      ($code -notmatch 'drop this comment line') -and ($code -match '\$live = 8') -and
      [string]::Equals($code, $old, [StringComparison]::Ordinal)
    }

    # ---- THE FALLBACK, DRIVEN -------------------------------------------------------------------------
    # A file that does not tokenize must still reduce, and it must reduce through the OLD rung rather
    # than throwing. Asserted against the fallback's own answer so the case cannot pass on a silent
    # empty string.
    $fxBroken = New-PsSourceText -Lines @(
      '~a = ''unterminated',
      '# a comment line',
      '~b = 2')
    Test-PsSourceCase 'CLEAN TWIN  a file PSParser refuses still reduces, through the character rung, and does not throw' {
      $code = Get-PsCodeOnly -Text $fxBroken
      $old = Get-PsCodeOnlyFallback -Text $fxBroken
      $e = $null
      $null = [System.Management.Automation.PSParser]::Tokenize($fxBroken, [ref]$e)
      (@($e).Count -gt 0) -and [string]::Equals($code, $old, [StringComparison]::Ordinal)
    }

    # ---- THE LIVE CALLERS' SHAPE ----------------------------------------------------------------------
    # This library's whole job is what run-gates and lib\selftest-discovery.ps1 match against, so the
    # founding bug of 2026-09-07 is asserted here too: a header EXPLAINING a declaration must not leave
    # that declaration in the reduction.
    $fxHeader = New-PsSourceText -Lines @(
      '<#',
      '  this library declares no param([switch]~SelfTest), because a dot-sourced',
      '  param block runs in the caller''''s scope',
      '#>',
      'function Get-Thing { 1 }')
    Test-PsSourceCase 'MUST NOT FIRE  a block header quoting the self-test declaration leaves nothing for run-gates to enrol (the 8 libraries of 2026-09-07)' {
      (Get-PsCodeOnly -Text $fxHeader) -notmatch '\[switch\]\$SelfTest'
    }
    $fxLineProse = New-PsSourceText -Lines @(
      '# run-gates matches param([switch]~SelfTest) against this file',
      'Write-Output 1')
    Test-PsSourceCase 'MUST NOT FIRE  a LINE comment quoting the declaration leaves nothing to enrol (the 2026-09-01 recursion)' {
      (Get-PsCodeOnly -Text $fxLineProse) -notmatch '\[switch\]\$SelfTest'
    }

    # ---- THE BLOCK-ONLY REDUCTION, for callers that report line numbers (2026-09-12) --------------------
    $fxBlockOnly = New-PsSourceText -Lines @(
      '<# header naming Read-JsonFile',
      '   over two lines #>',
      '# a line comment that must SURVIVE here',
      '~q = ''<# a quoted opener, not a comment''',
      '~live = 7')
    Test-PsSourceCase 'MUST FIRE  the block-only reduction blanks a header to its own newlines and keeps every other line, so line 5 is still line 5' {
      $lines = @((Get-PsBlockCommentsBlanked -Text $fxBlockOnly) -split "`n")
      ($lines.Count -eq 5) -and ($lines[0] -eq '') -and ($lines[1] -eq '') -and
      ($lines[2] -match 'must SURVIVE') -and ($lines[3] -match 'a quoted opener') -and ($lines[4] -eq '$live = 7')
    }
    Test-PsSourceCase 'CLEAN TWIN  the block-only reduction leaves CRLF endings and comment-free source byte-identical' {
      $plain = "`$a = 1`r`n# note`r`n`$b = 2`r`n"
      [string]::Equals((Get-PsBlockCommentsBlanked -Text $plain), $plain, [StringComparison]::Ordinal)
    }

    # ---- A REAL FILE, READ FROM DISK ------------------------------------------------------------------
    # The temp directory exists for this one: the callers hand this library the text of a file, so one
    # case goes through a file rather than a here-built string.
    $fxPath = Join-Path $psDir 'sample.ps1'
    [IO.File]::WriteAllText($fxPath, (New-PsSourceText -Lines @(
      '<# a header #>',
      '~pattern = ''<# not a comment''',
      '~live = 6')), (New-Object Text.UTF8Encoding($false)))
    Test-PsSourceCase 'CLEAN TWIN  a real file read from disk reduces with its quoted opener intact' {
      $code = Get-PsCodeOnly -Text ([IO.File]::ReadAllText($fxPath))
      ($code -match '\$live = 6') -and ($code -match '\$pattern') -and ($code -notmatch 'a header')
    }
  } finally {
    Remove-Item -LiteralPath $psDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($script:psCases -eq 0) { Write-Output 'PS-SOURCE SELF-TEST FAILED (ran zero cases)'; exit 1 }
  if ($script:psFail) {
    Write-Output ("PS-SOURCE SELF-TEST FAILED ({0} of {1} case(s))" -f $script:psFail, $script:psCases)
    exit 1
  }
  Write-Output ("PS-SOURCE SELF-TEST PASSED ({0} of {0} case(s): quoted comment delimiters and here-string hashes are read as data, ordinary source reduces byte for byte as before, and a file that does not tokenize falls back)" -f $script:psCases)
  exit 0
}
