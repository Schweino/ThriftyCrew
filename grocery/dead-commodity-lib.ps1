<#
  dead-commodity-lib.ps1 - can a commodity's rules ever match anything at all?

  THE CLASS (2026-08-30, queue 2026-08-22-51a5b6). compare-deals applies a GLOBAL_EXCLUDE list to every
  product name. A commodity whose every include REQUIRES a word that list blocks, and which carries no
  relax_global entry releasing that word, can never match a single product. It is not a rule that misses
  sometimes; it is a rule switched off from the day it was written - and from the outside it looks exactly
  like a commodity Omaha does not carry, so nothing ever asks about it.

  Two live commodities were in that state and had been since they were created:
    chili-garlic-sauce          both includes require the literal 'sauce'; GLOBAL_EXCLUDE carries \bsauce\b
    frozen-cauliflower-florets  its only include requires 'frozen';        GLOBAL_EXCLUDE carries \bfrozen\b
  Both now carry relax_global entries and price three stores each. This is the carve-out-inherits-its-killer
  class, and it had no audit until this file.

  WHY A LIB AND NOT A COPY IN THE TEST. The rule is used by test-auditors' live arm (which runs daily from
  check-ad-cycles) and by its frozen fixtures. Two copies of a rule is its own failure class here.
#>

# Reduce an include PATTERN to the plain-text skeleton of the names it can match, so a GLOBAL_EXCLUDE
# token can then be applied WITH ITS OWN WORD BOUNDARIES.
#
# The first cut of this check searched the token text as a SUBSTRING of the pattern and reported that
# \bcake\b killed pancake-mix, \bwater\b killed watermelon, \btart\b killed tartar-sauce and \bale\b
# killed kale. All four price four to seven stores. An over-eager version of this check is worse than no
# check, because the "fix" it argues for is weakening a global exclude.
#
# The reduction is ITERATIVE and innermost-first, because the constructs that let a pattern match WITHOUT
# a given word nest inside each other:
#     (?:able)?     OPTIONAL group      - drop it; the pattern matches without it
#     (?:a|b|c)     ALTERNATION         - drop it; no single branch is required
#     (?!...)       NEGATIVE lookahead  - never required
#     (?=...)       POSITIVE lookahead  - REQUIRED, so its contents are KEPT
# Whatever it cannot fully reduce is reported as undecidable and never as clean.
function Get-IncludeSkeleton([string]$pattern) {
  $p = $pattern
  for ($k = 0; $k -lt 12; $k++) {
    $before = $p
    $p = [regex]::Replace($p, '\(\?![^()]*\)', ' ')                  # negative lookahead
    $p = [regex]::Replace($p, '\((?:\?[:=!])?[^()]*\)\s*[?*]', ' ')  # optional / star group
    $p = [regex]::Replace($p, '\((?:\?[:=])?[^()]*\|[^()]*\)', ' ')  # alternation
    $p = [regex]::Replace($p, '\((?:\?[:=])?([^()]*)\)', ' $1 ')     # required group: keep its contents
    if ($p -eq $before) { break }
  }
  if ($p -match '[()|]') { return $null }                            # could not reduce: say nothing
  $p = [regex]::Replace($p, '\[\^?[^\]]*\]\s*[?*]', ' ')             # optional char class
  $p = [regex]::Replace($p, '\[\^?[^\]]*\]', ' ')                    # char class = one arbitrary char
  $p = [regex]::Replace($p, '\\[sSwWdD]', ' ')
  $p = [regex]::Replace($p, '\.\s*\{\d+(,\d*)?\}', ' ')              # .{0,25}
  $p = [regex]::Replace($p, '\.', ' ')
  $p = [regex]::Replace($p, '\w\s*\{\d+(,\d*)?\}', ' ')
  $p = $p -replace '\\b', ''
  $p = [regex]::Replace($p, '\w[?*]', ' ')                           # optional single char: florets? -> floret
  $p = [regex]::Replace($p, '[\^\$\?\*\+\\]', '')
  $p = [regex]::Replace($p, '\s+', ' ')
  $p = $p.Trim()
  if (-not $p) { return $null }
  return $p
}

# Returns the blocking GLOBAL_EXCLUDE token; '' when the commodity can still match something; and '?' when
# at least one include could not be reduced. '?' is NOT clean - a check that could not evaluate must say so
# rather than be counted as agreement.
function Test-CommodityIsDead($commodity, [string[]]$globalExclude) {
  $inc = @($commodity.include | Where-Object { $_ })
  if ($inc.Count -eq 0) { return '' }
  $skels = @()
  foreach ($i in $inc) {
    $s = Get-IncludeSkeleton ([string]$i)
    if ($null -eq $s) { return '?' }
    $skels += $s
  }
  $relax = @($commodity.relax_global | Where-Object { $_ } | ForEach-Object { [string]$_ })
  foreach ($tok in $globalExclude) {
    if ($relax -contains [string]$tok) { continue }
    $blocksAll = $true
    foreach ($s in $skels) {
      $hit = $false
      try { $hit = [regex]::IsMatch($s, [string]$tok, 'IgnoreCase') } catch { $hit = $false }
      if (-not $hit) { $blocksAll = $false; break }
    }
    if ($blocksAll) { return [string]$tok }
  }
  return ''
}

# The engine's GLOBAL_EXCLUDE has ONE home: the assignment in compare-deals.ps1. Lifting it from there is
# the house convention (audit-match-contested, audit-match-soundness, audit-household-in-food and
# audit-coverage-gaps all do the same); retyping the 83 tokens here would be a second copy that drifts.
function Get-EngineGlobalExclude([string]$Root) {
  $src = Get-Content (Join-Path $Root 'compare-deals.ps1') -Raw
  $m = [regex]::Match($src, '\$GLOBAL_EXCLUDE = @\((?<b>[\s\S]*?)\r?\n\)')
  if (-not $m.Success) { return $null }
  return @(Invoke-Expression ('@(' + $m.Groups['b'].Value + ')'))
}
