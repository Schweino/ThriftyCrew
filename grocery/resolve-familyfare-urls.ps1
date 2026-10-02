<#
  resolve-familyfare-urls.ps1 - resolve Family Fare product links for the Family Fare chips in out\url-worklist.json,
  through the Freshop search API (store 6401, Omaha). Writes out\url-inputs\store-ff-urls.json (merge format) and
  out\ff-notcarry.json (not-carried CANDIDATES).

  EVERY CHIP ENDS IN EXACTLY ONE VERDICT, and only one of them says anything about whether the store carries it:
    resolved-board      a product passing the commodity rules whose name carries the BOARD ITEM'S name (score >= 0.75,
                        Get-FfNameScore, the scorer fix-links-ff.ps1 uses). The link opens the thing the board prices.
    resolved-commodity  no board-item match, so the rule-passing product whose per-unit is CLOSEST to the board's.
                        Right commodity, possibly another brand or size.
    no-match            the store ANSWERED with rows and none passed the commodity rules. The only verdict written to
                        ff-notcarry.json, and even then only as a candidate.
    unpriceable         rule-passing rows exist but none gives a per-unit in the commodity's unit and none is the
                        board item. The store sells something of the kind, so it is never a not-carried candidate.
    empty               HTTP 200 with zero rows. UNCHECKED: Freshop has answered a throttle with an empty 200
                        before ([[fail-open-reads-as-empty]]), and the pull keeps the same answer "rejected" until
                        empty-means-not-carried is ruled for this store (pull-regular-familyfare.ps1).
    blocked             a non-2xx answer, a throw or a timeout, after the backoff retries. UNCHECKED (gr-17).
    not-attempted       the circuit breaker tripped first. UNCHECKED.

  WHY THIS WAS REWRITTEN (2026-10-02, design\MEASURE-chip-resolvers-2026-10.md). The old loop had `catch { }`, so 38 of
  its 47 misses on 2026-10-02 were HTTP 400 answers in one unbroken run (the same searches answered normally alone),
  reported "no valid match" and written to ff-notcarry.json as not-carried. Freshop's throttle is a 400 whose body
  is {"error_code":429}; at the old 350 ms pacing it walls a run. And it picked the CHEAPEST rule-passing product, so
  avocados linked a Marzetti avocado dressing and cantaloupe an 18 oz tub of cubes (its own per-unit read "18 oz" as
  18 each). Per-unit now comes from pu-lib's Get-LinkPerUnit, which refuses an ounce size for an `each` commodity.

  REQUESTS: one search for the board item's own name (first 6 words, as fix-links-ff does) and, unless that found the
  board item, one for the commodity's primary term. -PaceMs between calls (4 s, the spacing the estate's other
  Freshop probes use), and a blocked call is retried after each -BackoffMs. Never retried on an empty 200: the pull's
  account is that retrying empties under a hard throttle ran 45 minutes. -BreakerAt consecutive blocked chips trip
  the breaker and the rest are not attempted, because a walled run only deepens the wall.

  ONE RUN DOES NOT FIT ONE FRESHOP WINDOW. Up to 2 calls a chip against a wall measured at roughly 40-130 calls, and
  the same budget is what pull-regular-familyfare.ps1's production windows (07:00, 08:00, 10:30) buy prices with.
  -Ids "a,b,c" runs a slice of the worklist, in worklist order; an id not on the worklist is refused. A string, not
  an array, because -File binds a list into one value (og-10).

  Exit 0 = every chip attempted. 3 = the breaker tripped (the outputs hold what was resolved; the rest is UNCHECKED).

  SCOPE OF A CLEAN REPORT: UNSOUND as a claim about carriage - a chip not in ff-notcarry.json may still be one the
  store does not carry (empty, blocked, not attempted). A no-match row is INCOMPLETE: a candidate, because the
  commodity rules or a one-query search can miss a product the store sells.
#>
param([string]$OutDir = "", [double]$MinScore = 0.75, [int]$PaceMs = 4000, [string]$BackoffMs = '8000,20000', [int]$BreakerAt = 3, [string]$Ids = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage; $ProgressPreference='SilentlyContinue'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\lf-write.ps1')  # Write-TcLfFile: the outputs are TRACKED, so LF (og-39)
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'pu-lib.ps1')               # Get-LinkPerUnit
. (Join-Path $root 'ff-name-score-lib.ps1')    # Get-FfNameScore
. (Join-Path $root 'search-terms-lib.ps1')     # Get-PrimarySearchTerm

$script:FfApiBase = 'https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&limit=25&q='
# -File binds a list into one string, so the backoff list is a string split into a new variable (og-10).
$script:FfBackoff = @(([string]$BackoffMs -split ',') | Where-Object { $_.Trim() } | ForEach-Object { [int]$_.Trim() })
$script:FfPaceMs = $PaceMs
$script:FfCalls = 0
# SEAMS: the self-test swaps these. Invoke-WebRequest throws on a non-2xx answer under PS 5.1; the StatusCode check
# below is for any seam that returns one instead.
$script:FfHttp = { param([string]$Url) Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Mozilla/5.0'; 'Accept' = 'application/json' } }
$script:FfSleep = { param([int]$Ms) Start-Sleep -Milliseconds $Ms }
$script:rules = @{}

# The staple board's global exclude is hardcoded in compare-deals.ps1 (staples are never a beverage/candy/
# prepared form); the recipe board relaxes juice/sauce/canned/frozen (recipe items legitimately are those)
# and carries its own global_exclude in recipe-commodities.json. Apply the RIGHT one per id's board.
$STAPLE_GEX = @('drink\s*mix','kool[\s-]?aid','probiotic','kombucha','\bdip\b','\bsauce\b','wrapped','\bbake\b','\bbaked\b','seasoned','marinated','stuffed','\bkit\b','flavored','\bsoup\b','helper','lunchable','smoothie','\bpudding\b','ice\s*cream','\bcreamer\b','\bfrozen\b','\bcanned\b','breaded','\bsnack\b','\bmeal\b','casserole','\bwrap\b','poppers','muffin','pretzel','filled','strudel','\bcake\b','drinkable','(?<!orange\s)\bjuice\b','\bsoda\b','sparkling','seltzer','\bwater\b','energy\s*drink','sports\s*drink','tonic','lemonade','cocktail','pop[\s-]?tart','pastr','toaster','\btart\b','cereal','granola\s*bar','fruit\s*snack','\bgum\b')

function MatchesRules($name, $id) {
  $n = ([string]$name).ToLower()
  if (-not $script:rules.ContainsKey($id)) { return $true }
  $r = $script:rules[$id]
  foreach ($g in $r.gex) { if ($g -and $n -match $g) { return $false } }      # board-appropriate global exclude first
  $hit = $false; foreach ($inc in $r.include) { if ($inc -and $n -match $inc) { $hit = $true; break } }
  if ($r.include.Count -gt 0 -and -not $hit) { return $false }
  foreach ($exc in $r.exclude) { if ($exc -and $n -match $exc) { return $false } }
  return $true
}

# One search. Returns answered=$true with the rows (possibly none), or answered=$false with what the API said.
function Invoke-FfSearch([string]$Query) {
  $url = $script:FfApiBase + [uri]::EscapeDataString($Query)
  $waits = @(0) + $script:FfBackoff
  $said = ''
  foreach ($w in $waits) {
    if ($w -gt 0) { & $script:FfSleep $w }
    elseif ($script:FfCalls -gt 0) { & $script:FfSleep $script:FfPaceMs }
    $script:FfCalls++
    try {
      $resp = & $script:FfHttp $url
      $sc = [int]$resp.StatusCode
      if ($sc -lt 200 -or $sc -ge 300) { $said = "HTTP $sc"; continue }
      $doc = ConvertFrom-Json ([string]$resp.Content)
      if ($null -eq $doc -or -not $doc.PSObject.Properties['items']) { $said = "HTTP $sc without an items array"; continue }
      $items = if ($null -eq $doc.items) { @() } else { @($doc.items) }   # @($null) is one row, not zero
      return [pscustomobject]@{ answered = $true; items = $items; said = "HTTP $sc" }
    } catch {
      # The status is on the exception; the 400's BODY ({"error_code":429}) is in ErrorDetails under PS 5.1, because
      # the error stream is already consumed (the same read pull-regular-familyfare.ps1 makes).
      $sc = 0; try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
      $ec = ''; try { if ([string]$_.ErrorDetails.Message -match '"error_code"\s*:\s*(\d+)') { $ec = $Matches[1] } } catch { }
      $said = if ($sc -and $ec) { "HTTP $sc (error_code $ec)" } elseif ($sc) { "HTTP $sc" } else { 'no response: ' + $_.Exception.Message }
    }
  }
  return [pscustomobject]@{ answered = $false; items = @(); said = $said }
}

# Rows passing the commodity rules, with their per-unit (or $null) and link. A row without a positive price or a
# canonical_url is kept as rule-passing, because it still says the store sells the kind of thing.
function Get-FfCandidates($Items, [string]$Id, [string]$Unit) {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($Items)) {
    if ($null -eq $p) { continue }
    $nm = [string]$p.name
    if (-not (MatchesRules $nm $Id)) { continue }
    $price = 0.0
    foreach ($f in 'base_price', 'price') { if ($price -le 0 -and $p.$f) { [void][double]::TryParse((([string]$p.$f) -replace '[^0-9.]', ''), [ref]$price) } }
    $sz = [string]$p.size
    $pu = if ($price -gt 0) { Get-LinkPerUnit -size $sz -unit $Unit -price $price -name $nm } else { $null }
    $out.Add([pscustomobject]@{ name = $nm; url = [string]$p.canonical_url; price = $price; size = $sz; pu = $pu })
  }
  return , $out.ToArray()
}

# Distance of a per-unit from the board's, on a ratio scale; $null per-unit sorts last.
function Get-FfPuDistance($Pu, [double]$BoardPu) {
  if ($null -eq $Pu -or $Pu -le 0) { return [double]::MaxValue }
  if ($BoardPu -le 0) { return [double]$Pu }   # no board price to aim at: cheapest wins, the old behaviour
  return [math]::Abs([math]::Log($Pu / $BoardPu))
}

function Select-FfBoardMatch($Cands, [string]$BoardItem, [double]$BoardPu, [double]$Min) {
  if (-not $BoardItem) { return $null }
  $ok = @($Cands | Where-Object { $_.url -and $_.price -gt 0 } | ForEach-Object {
      $_ | Add-Member -NotePropertyName score -NotePropertyValue (Get-FfNameScore $BoardItem $_.name) -Force -PassThru })
  $ok = @($ok | Where-Object { $_.score -ge $Min })
  if (-not $ok.Count) { return $null }
  return ($ok | Sort-Object @{ e = { $_.score }; Descending = $true }, @{ e = { Get-FfPuDistance $_.pu $BoardPu } }, @{ e = { $_.url } } | Select-Object -First 1)
}

function Select-FfCommodityMatch($Cands, [double]$BoardPu) {
  $ok = @($Cands | Where-Object { $_.url -and $null -ne $_.pu -and $_.pu -gt 0 })
  if (-not $ok.Count) { return $null }
  return ($ok | Sort-Object @{ e = { Get-FfPuDistance $_.pu $BoardPu } }, @{ e = { $_.url } } | Select-Object -First 1)
}

function Get-FfBoardQuery([string]$BoardItem) {
  $q = (($BoardItem -replace '[^A-Za-z0-9 ]', ' ') -replace '\s{2,}', ' ').Trim()
  return (($q -split ' ' | Where-Object { $_ } | Select-Object -First 6) -join ' ')
}

function Resolve-FfChip($Chip, [string]$CommodityTerm, [double]$Min) {
  $id = [string]$Chip.id
  $unit = if ($script:rules.ContainsKey($id) -and $script:rules[$id].unit) { $script:rules[$id].unit } else { [string]$Chip.unit }
  $board = [string]$Chip.board_item
  $bpu = 0.0; if ($Chip.price_per_unit) { $bpu = [double]$Chip.price_per_unit }
  $v = [ordered]@{ id = $id; verdict = ''; said = ''; query = ''; pick = $null; rows_seen = 0 }
  $all = @()
  $bq = Get-FfBoardQuery $board
  if ($bq) {
    $r1 = Invoke-FfSearch $bq
    if (-not $r1.answered) { $v.verdict = 'blocked'; $v.said = $r1.said; $v.query = $bq; return [pscustomobject]$v }
    $c1 = Get-FfCandidates $r1.items $id $unit; $all += $c1
    $m = Select-FfBoardMatch $c1 $board $bpu $Min
    if ($m) { $v.verdict = 'resolved-board'; $v.query = $bq; $v.pick = $m; return [pscustomobject]$v }
  }
  $r2 = Invoke-FfSearch $CommodityTerm
  $v.query = $CommodityTerm
  if (-not $r2.answered) { $v.verdict = 'blocked'; $v.said = $r2.said; return [pscustomobject]$v }
  $v.rows_seen = @($r2.items).Count
  $c2 = Get-FfCandidates $r2.items $id $unit; $all += $c2
  $m = Select-FfBoardMatch $c2 $board $bpu $Min
  if ($m) { $v.verdict = 'resolved-board'; $v.pick = $m; return [pscustomobject]$v }
  $m = Select-FfCommodityMatch $all $bpu
  if ($m) { $v.verdict = 'resolved-commodity'; $v.pick = $m; return [pscustomobject]$v }
  if ($v.rows_seen -eq 0) { $v.verdict = 'empty'; $v.said = $r2.said; return [pscustomobject]$v }
  if (@($all).Count -eq 0) { $v.verdict = 'no-match'; return [pscustomobject]$v }
  $v.verdict = 'unpriceable'; return [pscustomobject]$v
}

# The loop, with its breaker. $TermFor maps an id to its commodity search term.
function Invoke-FfResolve($Chips, $TermFor, [double]$Min, [int]$Breaker) {
  $res = New-Object System.Collections.Generic.List[object]
  $consec = 0; $tripped = $false
  foreach ($c in @($Chips)) {
    $id = [string]$c.id
    if ($tripped) { $res.Add([pscustomobject]@{ id = $id; verdict = 'not-attempted'; said = 'circuit breaker tripped'; query = ''; pick = $null; rows_seen = 0 }); continue }
    $r = Resolve-FfChip $c (& $TermFor $id) $Min
    $res.Add($r)
    if ($r.verdict -eq 'blocked') { $consec++; if ($consec -ge $Breaker) { $tripped = $true } } else { $consec = 0 }
  }
  return [pscustomobject]@{ results = $res.ToArray(); tripped = $tripped }
}

function Select-FfChips($Chips, [string]$IdList) {
  $want = @(([string]$IdList -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if (-not $want.Count) { return , @($Chips) }
  $have = @{}; foreach ($c in @($Chips)) { $have[[string]$c.id] = $true }
  $missing = @($want | Where-Object { -not $have.ContainsKey($_) })
  if ($missing.Count) { throw ('-Ids names chips not on the Family Fare worklist: ' + ($missing -join ', ')) }
  return , @(@($Chips) | Where-Object { $want -contains [string]$_.id })
}

function Write-FfOutputs($Results, [string]$Dir) {
  $urlDir = Join-Path $Dir 'url-inputs'; if (-not (Test-Path -LiteralPath $urlDir)) { New-Item -ItemType Directory -Force -Path $urlDir | Out-Null }
  $rows = @($Results | Where-Object { $_.verdict -like 'resolved-*' } | ForEach-Object {
      [pscustomobject]([ordered]@{ id = $_.id; url = $_.pick.url; price = ('$' + ('{0:0.00}' -f $_.pick.price)); size = $_.pick.size; name = $_.pick.name
          per_unit = $(if ($null -ne $_.pick.pu) { [math]::Round([double]$_.pick.pu, 4) } else { $null }); match = ($_.verdict -replace '^resolved-', '') }) })
  $nc = @($Results | Where-Object { $_.verdict -eq 'no-match' } | ForEach-Object { [pscustomobject]([ordered]@{ id = $_.id; store = 'Family Fare'; term = $_.query; rows_seen = $_.rows_seen }) })
  [void](Write-TcLfFile -Path (Join-Path $urlDir 'store-ff-urls.json') -Text (ConvertTo-Json -InputObject $rows -Depth 5))
  [void](Write-TcLfFile -Path (Join-Path $Dir 'ff-notcarry.json') -Text (ConvertTo-Json -InputObject $nc -Depth 4))
}

if ($SelfTest) {
  $fail = 0; $cases = 0
  function Check([string]$Name, [bool]$Ok, [string]$Got = '') { $script:cases++; if ($Ok) { Write-Output "ok    $Name" } else { $script:fail++; Write-Output "FAIL  $Name  (got: $Got)" } }
  function Resp([int]$Sc, [string]$Json) { [pscustomobject]@{ StatusCode = $Sc; Content = $Json } }
  function Item([string]$N, [string]$P, [string]$S, [string]$U) { [ordered]@{ name = $N; base_price = $P; size = $S; canonical_url = $U } }
  function Items($List) { ConvertTo-Json -InputObject @{ items = @($List) } -Depth 4 -Compress }
  $script:sleeps = New-Object System.Collections.Generic.List[int]
  $script:FfSleep = { param([int]$Ms) $script:sleeps.Add($Ms) }
  $script:FfBackoff = @(8000, 20000); $script:FfPaceMs = 4000
  $script:rules = @{
    'avocados'   = @{ include = @('avocado'); exclude = @(); unit = 'each'; gex = @() }
    'butter'     = @{ include = @('butter'); exclude = @('peanut'); unit = 'oz'; gex = @() }
    'cantaloupe' = @{ include = @('cantaloupe'); exclude = @(); unit = 'each'; gex = @() }
    'capers'     = @{ include = @('caper'); exclude = @(); unit = 'oz'; gex = @() }
  }
  $chip = { param($Id, $Board, $Pu) [pscustomobject]@{ id = $Id; board_item = $Board; price_per_unit = $Pu; unit = 'each' } }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('rffu-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
    $c400 = 0
    $script:FfHttp = { param($u) $script:c400++; Resp 400 '{"error_code":429}' }
    $script:FfCalls = 0; $script:sleeps.Clear()
    $r = Resolve-FfChip (& $chip 'avocados' 'Hass Avocados, Small' 0.79) 'avocados' 0.75
    Check 'MUST FIRE: a 400 on every try is BLOCKED, never no-match' ($r.verdict -eq 'blocked') $r.verdict
    Check 'MUST FIRE: a blocked call is retried after each backoff (3 tries, 8 s then 20 s)' (($c400 -eq 3) -and ($script:sleeps -contains 8000) -and ($script:sleeps -contains 20000)) ("calls=$c400 sleeps=" + ($script:sleeps -join ','))

    $script:FfHttp = { param($u) throw 'The operation has timed out.' }
    $r = Resolve-FfChip (& $chip 'avocados' 'Hass Avocados, Small' 0.79) 'avocados' 0.75
    Check 'MUST FIRE: a thrown request (timeout) is BLOCKED' (($r.verdict -eq 'blocked') -and ($r.said -match 'timed out')) "$($r.verdict) / $($r.said)"

    $script:FfHttp = { param($u) Resp 200 '{"error":"x"}' }
    $r = Resolve-FfChip (& $chip 'avocados' 'Hass Avocados, Small' 0.79) 'avocados' 0.75
    Check 'MUST FIRE: a 200 with no items array is BLOCKED, not empty' ($r.verdict -eq 'blocked') $r.verdict

    $script:FfHttp = { param($u) Resp 200 '{"items":[]}' }
    $r = Resolve-FfChip (& $chip 'avocados' 'Hass Avocados, Small' 0.79) 'avocados' 0.75
    Check 'MUST FIRE: a 200 with zero rows is EMPTY (unchecked), not no-match' ($r.verdict -eq 'empty') $r.verdict

    $script:FfHttp = { param($u) Resp 200 '{"items":null}' }
    $r = Resolve-FfChip (& $chip 'avocados' 'Hass Avocados, Small' 0.79) 'avocados' 0.75
    Check 'MUST FIRE: items null is EMPTY with 0 rows seen, not one row and a no-match' (($r.verdict -eq 'empty') -and ($r.rows_seen -eq 0)) "$($r.verdict) rows=$($r.rows_seen)"

    $script:FfHttp = { param($u) Resp 200 (Items @((Item 'Mango Chunks' '2.99' '1 ea' 'u/mango'))) }
    $r = Resolve-FfChip (& $chip 'avocados' 'Hass Avocados, Small' 0.79) 'avocados' 0.75
    Check 'CLEAN TWIN: rows came back and none passed the rules - still a NO-MATCH candidate' (($r.verdict -eq 'no-match') -and ($r.rows_seen -eq 1)) "$($r.verdict) rows=$($r.rows_seen)"

    $script:FfHttp = { param($u) Resp 200 (Items @((Item 'Marzetti Dressed Avocado Green Goddess' '3.49' '13 oz' 'u/dressing'), (Item 'Hass Avocados, Small' '0.79' '1 ea' 'u/hass'))) }
    $r = Resolve-FfChip (& $chip 'avocados' 'Hass Avocados, Small' 0.79) 'avocados' 0.75
    Check 'MUST FIRE: avocados opens the board item, not the avocado dressing' (($r.verdict -eq 'resolved-board') -and ($r.pick.url -eq 'u/hass')) "$($r.verdict) $($r.pick.url)"

    $script:FfHttp = { param($u) Resp 200 (Items @((Item 'Our Family Butter, Salted 4 Ea' '3.49' '16 oz' 'u/of'), (Item 'Land O Lakes Butter, Unsalted 4 Ea' '5.49' '16 oz' 'u/lol'))) }
    $r = Resolve-FfChip ([pscustomobject]@{ id = 'butter'; board_item = 'Land O Lakes Butter, Unsalted 4 Ea'; price_per_unit = 0.343; unit = 'oz' }) 'butter' 0.75
    Check 'MUST FIRE: the board item wins over a CHEAPER rule-passing product' (($r.verdict -eq 'resolved-board') -and ($r.pick.url -eq 'u/lol')) "$($r.verdict) $($r.pick.url)"

    $script:FfHttp = { param($u) Resp 200 (Items @((Item 'Fresh & Finest Cantaloupe Cubes' '5.00' '18 oz' 'u/cubes'), (Item 'Cantaloupe' '2.99' '1 ea' 'u/melon'))) }
    $r = Resolve-FfChip (& $chip 'cantaloupe' 'Organic Melon, Cantaloupe, Small' 3.49) 'cantaloupe' 0.75
    Check 'MUST FIRE: cantaloupe falls back to the whole melon, never the 18 oz cubes read as 18 each' (($r.verdict -eq 'resolved-commodity') -and ($r.pick.url -eq 'u/melon')) "$($r.verdict) $($r.pick.url)"

    $script:FfHttp = { param($u) Resp 200 (Items @((Item 'Capers Gift Jar' '0' '' ''))) }
    $r = Resolve-FfChip ([pscustomobject]@{ id = 'capers'; board_item = 'Reese Capers 3.5 Oz'; price_per_unit = 1.1; unit = 'oz' }) 'capers' 0.75
    Check 'MUST NOT FIRE: rule-passing rows with no price or link are UNPRICEABLE, never a not-carried candidate' ($r.verdict -eq 'unpriceable') $r.verdict

    $script:n = 0
    $script:FfHttp = { param($u) $script:n++; if ($script:n -eq 1) { Resp 400 '' } else { Resp 200 (Items @((Item 'Hass Avocados, Small' '0.79' '1 ea' 'u/hass'))) } }
    $r = Resolve-FfChip (& $chip 'avocados' 'Hass Avocados, Small' 0.79) 'avocados' 0.75
    Check 'CLEAN TWIN: a 400 that clears on the backoff retry resolves normally' ($r.verdict -eq 'resolved-board') $r.verdict

    # Breaker, bar 3: two blocked chips then an answered one must not trip; three blocked in a row must.
    $script:FfHttp = { param($u) if ($u -match 'blk') { Resp 400 '' } else { Resp 200 '{"items":[]}' } }
    $termFor = { param($id) $id }
    $mk = { param($id) [pscustomobject]@{ id = $id; board_item = ''; price_per_unit = 0; unit = 'each' } }
    $at = Invoke-FfResolve @((& $mk 'blk1'), (& $mk 'blk2'), (& $mk 'ok1'), (& $mk 'ok2')) $termFor 0.75 3
    Check 'MUST NOT FIRE: AT the bar minus one (2 consecutive blocked, breaker 3) the run carries on' ((-not $at.tripped) -and ($at.results[3].verdict -eq 'empty')) ("tripped=$($at.tripped) last=$($at.results[3].verdict)")
    $past = Invoke-FfResolve @((& $mk 'blk1'), (& $mk 'blk2'), (& $mk 'blk3'), (& $mk 'ok1')) $termFor 0.75 3
    Check 'MUST FIRE: AT the bar (3 consecutive blocked, breaker 3) the breaker trips and the rest is not attempted' (($past.tripped) -and ($past.results[3].verdict -eq 'not-attempted')) ("tripped=$($past.tripped) last=$($past.results[3].verdict)")

    # End to end through the writer: only the no-match chip reaches ff-notcarry.json, and the bytes are LF.
    $script:FfHttp = { param($u) if ($u -match 'blk') { Resp 400 '' } elseif ($u -match 'ghost') { Resp 200 '{"items":[]}' } else { Resp 200 (Items @((Item 'Mango Chunks' '2.99' '1 ea' 'u/mango'))) } }
    $run = Invoke-FfResolve @((& $mk 'blk1'), (& $mk 'ghost1'), (& $mk 'avocados')) $termFor 0.75 3
    Write-FfOutputs $run.results $tmp
    $ncPath = Join-Path $tmp 'ff-notcarry.json'
    $ncDoc = Read-JsonFile $ncPath; $nc = @($ncDoc)
    $ids = (@($nc | ForEach-Object { $_.id }) -join ',')
    Check 'MUST FIRE: ff-notcarry.json holds the no-match chip and NOT the blocked or empty ones' ($ids -eq 'avocados') $ids
    $bytes = [IO.File]::ReadAllBytes($ncPath)
    Check 'MUST FIRE: ff-notcarry.json is written LF (no CR byte)' (-not ($bytes -contains 13)) 'found a CR'
    $urlDoc = Read-JsonFile (Join-Path $tmp 'url-inputs\store-ff-urls.json'); $urlRows = @($urlDoc)
    Check 'CLEAN TWIN: with nothing resolved, store-ff-urls.json is an empty array, not an empty file' ($urlRows.Count -eq 0) ("rows=" + $urlRows.Count)

    $wlChips = @((& $mk 'a'), (& $mk 'b'), (& $mk 'c'))
    $sl = Select-FfChips $wlChips 'c, a'
    Check 'CLEAN TWIN: -Ids keeps worklist order and only the named chips' ((@($sl | ForEach-Object { $_.id }) -join ',') -eq 'a,c') (@($sl | ForEach-Object { $_.id }) -join ',')
    $all = Select-FfChips $wlChips ''
    Check 'MUST NOT FIRE: no -Ids runs every chip' (@($all).Count -eq 3) (@($all).Count)
    $threw = $false; try { [void](Select-FfChips $wlChips 'a,zz') } catch { $threw = $true }
    Check 'MUST FIRE: an -Ids entry not on the worklist is refused, never silently dropped' $threw ''
  } catch {
    $fail++; Write-Output ("FAIL  self-test threw: " + $_.Exception.Message)
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
  }
  $expect = 20
  if ($cases -ne $expect) { $fail++; Write-Output "FAIL  ran $cases cases, expected $expect" }
  if ($fail) { Write-Output "resolve-familyfare-urls self-test FAIL ($fail of $cases)"; exit 1 }
  Write-Output "resolve-familyfare-urls self-test pass ($cases cases)"
  exit 0
}

if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$wl = Read-JsonFile (Join-Path $OutDir 'url-worklist.json')
$ffAll = @($wl.stores.'Family Fare')
$ff = Select-FfChips $ffAll $Ids
$terms = (Read-JsonFile (Join-Path $root 'commodity-search.json')).terms

# rules: id -> @{include;exclude;unit;gex}   gex = the global-exclude list for that id's board
$sdoc = Read-JsonFile (Join-Path $root 'commodities.json')
$slist = if ($sdoc.PSObject.Properties['commodities']) { $sdoc.commodities } else { $sdoc }
foreach ($c in $slist) { $script:rules[[string]$c.id] = @{ include = @($c.include); exclude = @($c.exclude); unit = [string]$c.unit; gex = $STAPLE_GEX } }
$rdoc = Read-JsonFile (Join-Path $root 'recipe-commodities.json')
$rgex = @($rdoc.global_exclude)
foreach ($c in $rdoc.commodities) { if (-not $script:rules.ContainsKey([string]$c.id)) { $script:rules[[string]$c.id] = @{ include = @($c.include); exclude = @($c.exclude); unit = [string]$c.unit; gex = $rgex } } }

# Get-PrimarySearchTerm: [string]$terms.$id JOINS a multi-term commodity into one dead search string.
$termFor = { param($id) if ($terms.PSObject.Properties[$id]) { Get-PrimarySearchTerm $terms $id } else { $id -replace '-', ' ' } }
$run = Invoke-FfResolve $ff $termFor $MinScore $BreakerAt
foreach ($r in $run.results) {
  if ($r.verdict -like 'resolved-*') { Write-Output ("OK    {0,-26} {1,-9} `${2,-6} {3,-8} {4}" -f $r.id, ($r.verdict -replace '^resolved-', ''), ('{0:0.00}' -f $r.pick.price), $r.pick.size, $r.pick.name) }
  else { Write-Output ("{0,-13} {1,-26} {2} (query: {3})" -f $r.verdict.ToUpper(), $r.id, $r.said, $r.query) }
}
Write-FfOutputs $run.results $OutDir

$count = { param($v) @($run.results | Where-Object { $_.verdict -eq $v }).Count }
$n = $ff.Count
$rb = & $count 'resolved-board'; $rc = & $count 'resolved-commodity'
$unchecked = (& $count 'blocked') + (& $count 'empty') + (& $count 'not-attempted')
Write-Output ("---- resolved {0} of {1} Family Fare chips (board item {2}, commodity {3}); not-carried candidates {4}; unpriceable {5}; UNCHECKED {6} (blocked {7}, empty {8}, not attempted {9}); {10} API calls" -f ($rb + $rc), $n, $rb, $rc, (& $count 'no-match'), (& $count 'unpriceable'), $unchecked, (& $count 'blocked'), (& $count 'empty'), (& $count 'not-attempted'), $script:FfCalls)
if ($run.tripped) { Write-Output ("CIRCUIT BREAKER: $BreakerAt consecutive chips blocked - Freshop has walled this run. The unchecked chips say nothing about carriage; re-run after the wall lifts."); exit 3 }
exit 0
