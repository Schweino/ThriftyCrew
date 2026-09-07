# ps-source.ps1 - THE one way to reduce PowerShell source to the part that actually runs.
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
# NOT A PARSER, and it does not pretend to be. A `<#` inside a single-quoted string would be treated
# as a comment opener. Nothing in this estate writes that, and the alternative - running the real
# tokenizer on every file - costs more than the gate can afford. Named here so the limit is a decision
# rather than a surprise.
#
# THIS FILE DECLARES NO param() BLOCK, DELIBERATELY: in PS 5.1 dot-sourcing runs a param() block in the
# CALLER's scope, so a param([switch]$SelfTest) here would reset every caller's own -SelfTest.

function Get-PsCodeOnly {
  # Source with BLOCK comments blanked and whole-line comments dropped.
  #
  # Blanked, not deleted: a block header is replaced by its own newlines so that a caller which checks
  # whether a match is INDENTED, or reads the line before it, still sees the same shape. The
  # whole-line drop is the estate's existing semantic and is kept identical to it, so routing a caller
  # through here changes what it sees about block comments and nothing else.
  #
  # THIS DOC IS LINE COMMENTS ON PURPOSE, and that is not a style choice. The first cut wrote it as a
  # block comment and spelled the closing delimiter inside its own prose while explaining the rule -
  # which CLOSED the comment there, dropped the rest of the sentence into the parser as code, and made
  # the file fail to parse. A file about comment syntax is the one file that cannot be careless with it.
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

function Get-PsCodeLines {
  <# The same reduction, as an array of lines, for callers that filter rather than match. #>
  param([string]$Text)
  return @((Get-PsCodeOnly -Text $Text) -split "`n")
}
