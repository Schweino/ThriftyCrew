<#
  commodity-rules-lib.ps1 - ONE answer to "what does this commodity exclude?", as a PROVIDED interface.

  WHY (2026-09-19, design\PLAN-board-build-latency-2026-09-19.md, L2 phase 0). A commodity's effective
  rules are composed differently depending on which script is asking. Measured that day over the 80
  scripts that read commodities.json: 33 read `.exclude` directly and 17 of those 33 never apply
  the global list at all - select-fareway-shop, discover-hyvee, build-deals-page, audit-sale-fallback,
  promote-verdicts, register-batch among them. So `\bwipes\b` is excluded from a food commodity by the
  engine and NOT by those seventeen, and the ~1,887 per-commodity entries that merely restate a global
  pattern are load-bearing for them while being redundant for the engine. That is the same
  two-implementations-of-one-fact shape as prices-versus-links, one level down, and it is what makes the
  exclude de-duplication unsafe until there is one accessor to convert everyone onto.

  THE SEMANTICS ARE MATCH-LIB'S, NOT A NEW OPINION. Read off Invoke-MatchPsScan / BoundedMatchCore on
  2026-09-19:
      includes         tested against the RAW name OR its normalized variant
      global excludes  tested against the RAW name only; they BLOCK unless the commodity relaxes the
                       exact pattern string (relax_global, compared by string equality, not by regex)
      own excludes     tested against the RAW name only
  Because both exclude classes are raw-only and compared as text, "own + (global minus relaxed)" is a
  faithful set for anything that asks "would this commodity refuse this name". `Test-TcCommodityRulesAgree`
  below proves that against match-lib itself over the live commodity set, which is the same discipline
  test-match-lib applies to the matcher's own second copy: a rule that exists twice is proven against the
  first copy on the real data, not reasoned about once.

  WHAT THIS IS NOT. It does not match, rank or decide a winner - that is match-lib, and callers that need
  a verdict should use it. This answers the narrower question the seventeen are each answering by hand.

  NO SIDE EFFECTS ON LOAD, and it is FUNCTIONS rather than variables, for the reason global-exclude-lib's
  header gives: a $script: constant does not travel to a caller that lifts it, a function does.
#>

# The recipe board carries its own global list in its document (`global_exclude`); the staple board uses
# the shared one. Passing the DOC rather than a list is what keeps a caller from having to know which.
function Get-TcGlobalExcludeForDoc {
  param([Parameter(Mandatory)]$Doc)
  if ($Doc -and $Doc.PSObject.Properties['global_exclude'] -and @($Doc.global_exclude).Count -gt 0) {
    return @($Doc.global_exclude | ForEach-Object { [string]$_ })
  }
  # falls back to the shared list; the caller must have dot-sourced global-exclude-lib.ps1, which every
  # consumer of this file already does or can. Not auto-loaded here: NO SIDE EFFECTS ON LOAD.
  if (Get-Command Get-TcGlobalExclude -ErrorAction SilentlyContinue) { return @(Get-TcGlobalExclude | ForEach-Object { [string]$_ }) }
  throw 'commodity-rules-lib: no global_exclude on the document and Get-TcGlobalExclude is not loaded - dot-source global-exclude-lib.ps1 (same directory) first, or pass -GlobalExclude'
}

function Get-TcCommodityList {
  param([Parameter(Mandatory)]$Doc)
  if ($Doc.PSObject.Properties['commodities']) { return @($Doc.commodities) }
  return @($Doc)
}

<#
  The effective exclude patterns for ONE commodity: its own, plus every global it has not relaxed.
  Returns a string[] in a stable order (own first, then the globals in their own order), de-duplicated by
  exact text - the same equality relax_global uses.
#>
function Get-TcCommodityExclude {
  param(
    [Parameter(Mandatory)]$Commodity,
    [string[]]$GlobalExclude = $null,
    $Doc = $null
  )
  if ($null -eq $GlobalExclude) {
    if ($null -eq $Doc) { throw 'commodity-rules: pass -GlobalExclude or -Doc so the global list can be resolved' }
    $GlobalExclude = Get-TcGlobalExcludeForDoc -Doc $Doc
  }
  $relax = @{}
  foreach ($r in @($Commodity.relax_global)) { if ($null -ne $r) { $relax[[string]$r] = $true } }
  $seen = @{}
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($p in @($Commodity.exclude)) {
    if ($null -eq $p) { continue }
    $s = [string]$p
    if ($seen.ContainsKey($s)) { continue }
    $seen[$s] = $true; $out.Add($s)
  }
  foreach ($g in @($GlobalExclude)) {
    if ($null -eq $g) { continue }
    $s = [string]$g
    if ($relax.ContainsKey($s)) { continue }      # relaxed: this commodity is allowed to hold the word
    if ($seen.ContainsKey($s)) { continue }
    $seen[$s] = $true; $out.Add($s)
  }
  return ,$out.ToArray()
}

<#
  PROVE THE SECOND COPY AGAINST THE FIRST. For every commodity in $Doc, build match-lib's own matcher and
  assert that a name refused by this accessor's set is refused by the matcher, and vice versa, over the
  supplied probe names. Returns the disagreements; an empty array is the pass.

  It takes NAMES rather than inventing them: the honest corpus is the live capture pool, and a caller that
  passes three hand-written strings should not read the empty result as "the copies agree".
#>
function Test-TcCommodityRulesAgree {
  param(
    [Parameter(Mandatory)]$Doc,
    [Parameter(Mandatory)][string[]]$Names,
    [string[]]$GlobalExclude = $null,
    $Matcher = $null
  )
  if ($null -eq $GlobalExclude) { $GlobalExclude = Get-TcGlobalExcludeForDoc -Doc $Doc }
  $list = Get-TcCommodityList -Doc $Doc
  if ($null -eq $Matcher) {
    if (-not (Get-Command New-CommodityMatcher -ErrorAction SilentlyContinue)) { throw 'commodity-rules: dot-source match-lib.ps1 to compare against the matcher' }
    $Matcher = New-CommodityMatcher -Commodities $list -GlobalExclude $GlobalExclude
  }
  $bad = New-Object System.Collections.Generic.List[string]
  # THE ENTRY IS LOOKED UP ONCE PER COMMODITY, NOT ONCE PER NAME (2026-09-23). The lookup below used to sit inside the
  # name loop as a Where-Object over every matcher entry: commodities x names x entries pipeline steps, about 38
  # million for 520 commodities and 154 names, and 322 s of every push's gate. The first entry whose id matches
  # wins, exactly as `@(... | Where-Object ...)[0]` chose it.
  $entryById = @{}
  foreach ($e in $Matcher.entries) {
    $eid = [string]$e.commodity.id
    if (-not $entryById.ContainsKey($eid)) { $entryById[$eid] = $e }
  }
  foreach ($c in $list) {
    $eff = Get-TcCommodityExclude -Commodity $c -GlobalExclude $GlobalExclude
    $rx = @($eff | ForEach-Object { [regex]::new($_, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) })
    $entry = $null
    if ($entryById.ContainsKey([string]$c.id)) { $entry = $entryById[[string]$c.id] }
    foreach ($nm in $Names) {
      $mine = $false
      foreach ($r in $rx) { if ($r.IsMatch($nm)) { $mine = $true; break } }
      # match-lib's view: this commodity refuses the name when one of its own excludes hits, or a global
      # hits and is not relaxed. Reconstructed from the entry the matcher built, so it reads the same
      # compiled patterns the engine uses rather than re-deriving them here.
      $theirs = $false
      if ($entry) {
        # NEVER WRAP THESE IN @( ). match-lib builds entries, exc, gex and relax as
        # System.Collections.Generic.List[object], and under PS 5.1 the array subexpression around such a
        # list throws "Argument types do not match" - the trap ops-and-gates.md records and
        # ops/audit-list-array-wrap.ps1 holds at zero. foreach enumerates them directly, and -notcontains
        # works on the list as it stands. (Wrapping the Where-Object PIPELINE above is fine: that wraps the
        # pipeline's output array, not the list.)
        foreach ($r in $entry.exc) { if ($r.IsMatch($nm)) { $theirs = $true; break } }
        if (-not $theirs) {
          foreach ($g in $Matcher.gex) {
            if ($g.rx.IsMatch($nm) -and ($entry.relax -notcontains $g.text)) { $theirs = $true; break }
          }
        }
      }
      if ($mine -ne $theirs) { $bad.Add(("{0} :: '{1}' accessor={2} matcher={3}" -f $c.id, $nm, $mine, $theirs)) }
    }
  }
  return ,$bad.ToArray()
}

<#
  THE AGREEMENT CORPUS, ONE COPY (2026-09-23). Test-TcCommodityRulesAgree is run two ways and both must ask the same
  question: at push time over a FROZEN name list committed as a fixture (test-commodity-rules-lib.ps1, hermetic and
  cacheable), and daily over the LIVE capture pool (audit-commodity-rules-agree.ps1, in check-ad-cycles). These two
  functions are the corpus rule both read, so the frozen list is by construction what the live run would pick.
  Get-TcRulesProbeNames: the names that exercise the global list whatever a capture holds.
  Get-TcRulesCaptureCorpus: the newest *-regular-*.json in $CaptureDir by LastWriteTime and the item names of its
  first $Take deals, or $null when none is readable. The caller supplies the directory.
#>
function Get-TcRulesProbeNames {
  return @('Gerber Baby Food Banana', 'Coca-Cola Soda 12 pk', 'Kroger Disinfecting Wipes', 'Fresh Gala Apples')
}

function Get-TcRulesCaptureCorpus {
  param([Parameter(Mandatory)][string]$CaptureDir, [int]$Take = 150)
  $cap = Get-ChildItem (Join-Path $CaptureDir '*-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
  if (-not $cap) { return $null }
  $names = New-Object System.Collections.Generic.List[string]
  try {
    foreach ($d in @((Get-Content $cap.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).deals | Select-Object -First $Take)) {
      if ($d.item) { $names.Add([string]$d.item) }
    }
  } catch { return $null }
  return [pscustomobject]@{ file = $cap.Name; path = $cap.FullName; names = $names.ToArray() }
}

<#
  A LINK TO A PRODUCT ITS OWN COMMODITY'S RULE REFUSES (2026-09-22, queue 2026-09-22-e9aed3). An exclude
  releases a product from a commodity: the board stops pricing it, but a See-item link stored against that
  commodity still opens it. mexican-chorizo-fresh gained `\bbeef\b`, the Walmart cell moved to Cacique PORK
  Chorizo, and the link stayed on walmart.com/ip/10451933, "Cacique Beef Chorizo 12oz". No link check saw it:
  the names share brand and "chorizo", and the per-unit gap (2.00 vs 2.68/lb) is under the factor rule.
  Measured that day over product-urls.json: 33 of 2,962 links named a product their own commodity refuses.

  Add-TcRuleIndex adds id -> effective exclude regexes (own + unrelaxed globals, match-lib's semantics via
  Get-TcCommodityExclude) for ONE commodity document (the staple array or the recipe {commodities,
  global_exclude} doc) to $Index; an id already present is kept, so add the staple doc before the recipe doc,
  the order audit-name-drift reads the boards in. One doc per call: a document that IS an array must not be
  passed inside another array, where PS unrolls it.
  Get-TcReleasingPattern returns the exclude text that refuses $Name for $Id, or $null (unknown id included:
  no rule, no opinion). Raw name, case-insensitive, as match-lib tests excludes.
#>
function Add-TcRuleIndex {
  param([Parameter(Mandatory)][hashtable]$Index, [Parameter(Mandatory)]$Doc)
  $gex = Get-TcGlobalExcludeForDoc -Doc $Doc
  foreach ($c in (Get-TcCommodityList -Doc $Doc)) {
    $id = [string]$c.id
    if (-not $id -or $Index.ContainsKey($id)) { continue }
    $eff = Get-TcCommodityExclude -Commodity $c -GlobalExclude $gex
    $Index[$id] = @($eff | ForEach-Object { [pscustomobject]@{ text = $_; rx = [regex]::new($_, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) } })
  }
}

function Get-TcReleasingPattern {
  param([Parameter(Mandatory)][hashtable]$Index, [string]$Id = '', [string]$Name = '')
  if (-not $Id -or -not $Name -or -not $Index.ContainsKey($Id)) { return $null }
  foreach ($p in $Index[$Id]) { if ($p.rx.IsMatch($Name)) { return [string]$p.text } }
  return $null
}
