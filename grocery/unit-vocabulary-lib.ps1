<#
  unit-vocabulary-lib.ps1 - can a commodity's declared UNIT ever be turned into a price?

  THE CLASS (2026-08-30, queue 2026-08-22-51a5b6, bounced from that round for measurement).
  compare-deals normalizes every matched row to the commodity's canonical unit through Convert-ToUnit,
  which is a `switch ($unit)` over exactly six values with NO DEFAULT ARM. Any other value falls through
  to `return $null`. No canonical amount means no per-unit price means NO CELL - on every row, at every
  store, forever. Nothing validated the field when a commodity was written.

  Seven commodities were in that state, measured over all 592 against comparison-2026-08-30:

      unit      commodities   with board cells
      floz          74              74
      fl_oz          5               0     garlic-infused-olive-oil, coconut-aminos, avocado-oil,
                                            peanut-oil, creamy-cilantro-lime-dressing
      sq_ft          1               0     aluminum-foil
      gram           1               0     saffron

  A perfect separation on a one-character difference in a data field.

  DISTINCT FROM [dead-commodity-lib], which it otherwise looks exactly like. There the MATCHER can never
  keep a row; here the matcher keeps the row and the PRICER can never use it. compare-deals -Explain
  coconut-aminos reported its Bragg row as OURS, kept, while the commodity had no board row at all.
  From outside both are identical - zero cells, which reads as a food Omaha does not carry.

  THE VOCABULARY IS READ OUT OF THE SWITCH, NEVER RETYPED. A second copy of the engine's unit list is
  the same failure this estate keeps paying for (pu-lib had three copies of the per-unit rule; the
  category-exclude library drifted 2,165 patterns from the baked copy). Retyping it here would mean the
  day someone adds a 'gram' arm to Convert-ToUnit, this check keeps rejecting gram - and the fix would
  be to edit the guard, which is how a guard becomes something people route around.

  WHY A LIB AND NOT A COPY IN THE TEST: the rule is used by test-auditors' live arm (which runs daily
  from check-ad-cycles) and by its frozen fixtures. Same reason as dead-commodity-lib.ps1.
#>

# The engine's unit vocabulary, lifted from Convert-ToUnit's own switch in compare-deals.ps1.
# Returns $null when it cannot parse the switch - BLIND, which is not the same as clean, and the caller
# must report it as a failure rather than as agreement (could-not-run-is-not-a-failure).
function Get-EngineUnitVocabulary([string]$Root) {
  $f = Join-Path $Root 'compare-deals.ps1'
  if (-not (Test-Path $f)) { return $null }
  $src = Get-Content $f -Raw
  # the function body, from its declaration to the first line that closes at column 0
  $m = [regex]::Match($src, '(?m)^function Convert-ToUnit\([^\r\n]*\r?\n(?<b>[\s\S]*?)\r?\n\}')
  if (-not $m.Success) { return $null }
  $body = $m.Groups['b'].Value
  if ($body -notmatch 'switch\s*\(\s*\$unit\s*\)') { return $null }
  # an arm is a quoted literal alone on its line followed by the opening brace. The quoted regexes INSIDE
  # the arms ("if ($t -match '^(lb|lbs)$') { ... }") can never match this: a ')' stands between their
  # closing quote and the brace.
  $units = @()
  foreach ($a in [regex]::Matches($body, "(?m)^\s+'(?<u>[a-z0-9_ ]+)'\s*\{\s*$")) { $units += [string]$a.Groups['u'].Value }
  $units = @($units | Select-Object -Unique)
  # PARSE-INTEGRITY ANCHORS, not a second copy of the vocabulary. An empty or near-empty parse would
  # condemn every commodity in the estate; a runaway one would pass everything vacuously. Both are worse
  # than saying nothing, so either shape returns BLIND. 'lb' and 'each' are the two arms that have been
  # in this switch since it was written and are load-bearing for 198 of 592 commodities.
  if ($units.Count -lt 4 -or $units.Count -gt 24) { return $null }
  if ($units -notcontains 'lb' -or $units -notcontains 'each') { return $null }
  return ,@($units)
}

# Returns '' when this commodity's unit can be priced; otherwise the offending value, so the caller can
# name it. A missing or blank unit is reported as '(none)' - it is the same defect with a different
# spelling, and Convert-ToUnit falls through on it identically.
function Test-CommodityUnitIsPriceable($commodity, [string[]]$vocabulary) {
  $u = ''
  if ($commodity -and $commodity.PSObject.Properties['unit']) { $u = ([string]$commodity.unit).Trim() }
  if (-not $u) { return '(none)' }
  if ($vocabulary -contains $u) { return '' }
  return $u
}

# Every rule FILE the engine is ever pointed at, in the shape compare-deals itself reads them: a bare
# array (staples) or a { global_exclude, commodities } wrapper (the recipe set, which recipe-overlay.ps1
# runs through the same engine). Checking only commodities.json would leave the recipe board's units
# unguarded, and they reach exactly the same Convert-ToUnit.
function Get-EngineRuleFiles([string]$Root) {
  $out = @()
  foreach ($n in @('commodities.json', 'recipe-commodities.json')) {
    $p = Join-Path $Root $n
    if (Test-Path $p) { $out += $p }
  }
  return ,@($out)
}

# Reads one rule file and returns its commodity objects. `@(Get-Content | ConvertFrom-Json)` does NOT
# unroll a bare top-level JSON array in PS 5.1 - it counts 1 - so the assignment happens first.
function Read-RuleFileCommodities([string]$Path) {
  $doc = Get-Content $Path -Raw | ConvertFrom-Json
  if ($null -eq $doc) { return ,@() }
  if ($doc.PSObject.Properties['commodities']) { return ,@($doc.commodities) }
  return ,@($doc)
}
