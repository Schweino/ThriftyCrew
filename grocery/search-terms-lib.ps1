<#
  search-terms-lib.ps1 - THE one reader of commodity-search.json (F3, 2026-08-01).

  WHY IT EXISTS. That file maps a commodity id to the string every store puller searches for, and it holds
  exactly ONE string per commodity. 210 of 429 commodities have a Family Fare product name that does not
  contain our search term at all, so a single term is structurally unable to reach them - `popsicles` finds
  "Popsicle Ice Pops" and never "Our Family Jr. Pops, Orange, Cherry, Grape & Lime".

  THE TRAP THAT MADE THIS A LIB INSTEAD OF A ONE-LINE EDIT. 23 scripts read the file, and the pullers
  flatten it with `[string]$_.Value`. In PowerShell that does not fail on an array - it JOINS it. Putting
  `["popsicles","ice pops"]` in the file would silently become the single search "popsicles ice pops",
  which matches nothing, and every one of those 23 consumers would carry on reporting a clean run over a
  term that can never hit. A shape change nobody can see is worse than the gap it was meant to close.

  SO: arrays are supported HERE, expanded to real separate searches, and Test-SearchTermShape exists to
  catch a consumer that is still flattening. A string value keeps working exactly as before - this is
  additive, and callers that genuinely want one string (a chip's `q=`, a display label) ask for the PRIMARY
  term rather than being handed a joined one.

  THE BUDGET IS THE REAL CONSTRAINT, not the code. Family Fare buys ~85 of 526 terms per rotation, so every
  extra term lengthens the rotation for everything else. Multi-term is therefore OPT-IN per commodity and
  deliberately not rolled out to all 210 - Get-SearchTermPairs reports the total so the cost is visible
  rather than discovered later as a slower sweep.

  *** NO param() BLOCK, DELIBERATELY *** - dot-sourcing runs a script's param() in the CALLER's scope.
#>

function Get-SearchTermPairs {
  <#
    Every (id, term) pair a puller should search, in file order, with array values EXPANDED into separate
    entries. This is what a puller iterates; it must never build its own list off .PSObject.Properties.
    Returns objects with: id, term, primary (true for a commodity's first term).
  #>
  param($Terms)
  $out = New-Object 'System.Collections.Generic.List[object]'
  if ($null -eq $Terms) { return $out.ToArray() }
  foreach ($p in $Terms.PSObject.Properties) {
    $id = [string]$p.Name
    # A bare string and a one-element array must behave identically, so normalise before iterating rather
    # than branching on type at every call site.
    $vals = @()
    if ($p.Value -is [array]) { $vals = @($p.Value) } else { $vals = @($p.Value) }
    $isFirst = $true
    foreach ($v in $vals) {
      $t = ([string]$v).Trim()
      if ($t -eq '') { continue }
      $out.Add([pscustomobject]@{ id = $id; term = $t; primary = $isFirst })
      $isFirst = $false
    }
  }
  return $out.ToArray()
}

function Get-PrimarySearchTerm {
  <#
    The ONE term for callers that legitimately need a single string - a search chip's `q=`, a worklist
    label, a display line. Always the FIRST term, so it is stable and matches what a single-term consumer
    saw before arrays existed. Returns '' when the commodity has no usable term, and the caller must treat
    that as a hole rather than as an empty search.
  #>
  param($Terms, [string]$Id)
  if ($null -eq $Terms -or -not $Id) { return '' }
  $p = $Terms.PSObject.Properties[$Id]
  if (-not $p) { return '' }
  if ($p.Value -is [array]) {
    foreach ($v in @($p.Value)) { $t = ([string]$v).Trim(); if ($t -ne '') { return $t } }
    return ''
  }
  return ([string]$p.Value).Trim()
}

function Test-SearchTermShape {
  <#
    Findings about the FILE itself, for an auditor to print. Not a gate - it returns strings.
    The one that matters is an array value reaching a consumer that would join it; that consumer cannot
    report the problem itself, because a joined term looks like an ordinary term that simply found nothing.
  #>
  param($Terms)
  $f = New-Object 'System.Collections.Generic.List[string]'
  if ($null -eq $Terms) { $f.Add('commodity-search.json holds no terms object at all'); return $f.ToArray() }
  foreach ($p in $Terms.PSObject.Properties) {
    $id = [string]$p.Name
    if ($p.Value -is [array]) {
      $vals = @($p.Value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
      if ($vals.Count -eq 0) { $f.Add(("'" + $id + "' has an array of terms with nothing usable in it - it will never be searched")) }
      elseif ($vals.Count -eq 1) { $f.Add(("'" + $id + "' is an array with a single term; write it as a plain string so single-term consumers cannot differ from multi-term ones")) }
    } elseif (([string]$p.Value).Trim() -eq '') {
      $f.Add(("'" + $id + "' has an EMPTY search term, so no store is ever searched for it. That is a hole in the file, not an absence of work."))
    }
  }
  return $f.ToArray()
}
