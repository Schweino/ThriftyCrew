<#
  patch-batch8.ps1 - the three things register-batch.ps1 cannot write for the proxy-debt batch:
    1. reciprocal excludes on the EXISTING commodities that were acting as the proxy (each one PROVEN by
       out\r300\who-claims-r300.ps1 against the pre-registration commodities.json, and each one checked against
       the live cells of that row first so the fence cannot drop existing coverage),
    2. relax_global tokens (verified verbatim against compare-deals' GLOBAL_EXCLUDE),
    3. pint_oz on cherry-tomatoes - the engine converts a bare '1 pt' size to 16 oz, which would price a
       10 oz clamshell 1.6x too cheap and hand it the cheapest slot.
  ADD-only and idempotent.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'

$RECIP = @(
  @{ id='tomatoes'; pats=@('\bcherry\b','\bgrape\b');                      why="bare '\btomato(?:es)?\b' claimed every cherry/grape clamshell - the proxy itself. Live cells are all roma/vine/beefsteak, so nothing drops -> cherry-tomatoes" }
  @{ id='cookies';  pats=@('ginger\s*snaps?');                             why="'\bcookies?\b' claimed 'Nabisco Ginger Snaps Cookies' / 'Great Value Gingersnap Cookies'. Live cells are choc-chip/vanilla-wafer -> gingersnaps" }
  @{ id='pasta';    pats=@('jumbo\s+(?:pasta\s+)?shells?','\bmanicotti\b');why="'\bpasta\b' claimed 'Barilla Jumbo Shells Pasta'; the row's filled-pasta excludes (ravioli/tortellini/lasagna) do NOT cover jumbo shells or manicotti -> jumbo-pasta-shells" }
  @{ id='ground-beef-8020'; pats=@('93\s*/\s*7');                          why="it already excluded '93%', but not the slash spelling - make the fence a rule, not luck -> ground-beef-93-7" }
  @{ id='potato-chips';   pats=@('corn\s+chips?','\bfritos\b');            why="durable class fence for the r100 corn-chips-as-potato-chips proxy (no-op today: the include is phrase-anchored to 'potato chips') -> corn-chips" }
  @{ id='tortilla-chips'; pats=@('corn\s+chips?','\bfritos\b');            why="durable class fence for the corn-chips-vs-tortilla-chips product-class trap (no-op today: phrase-anchored to 'tortilla chips') -> corn-chips" }
  # NO fence needed (and none added - an exclude that can never fire is noise): cottage-cheese is phrase-anchored
  # to 'cottage cheese'; onions ALREADY excludes 'red\s+onion'; kielbasa ALREADY excludes 'turkey'. All three
  # verified by the pre-registration probe.
)

$MIX = '\bmix\b(?!\s*(?:&|and)\s*match)'
$RELAX = @(
  @{ id='gingersnaps'; pats=@('\bsnack\b');            why="party/snack-size cookie bags; parity with cookies, which relaxes the same token" }
  @{ id='corn-chips';  pats=@('\bsnack\b','flavored'); why="parity with potato-chips and tortilla-chips - without these every 'Flavored'/'Snack Size' bag is globally dropped" }
)

# drift check: a 'verbatim' token must still exist in compare-deals' list
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$m = [regex]::Match($src, '(?s)\$GLOBAL_EXCLUDE\s*=\s*@\((.*?)\r?\n\)')
$GEX = @()
foreach ($line in ($m.Groups[1].Value -split "`n")) {
  $l = $line.Trim(); if (-not $l -or $l.StartsWith('#')) { continue }
  foreach ($q in [regex]::Matches($l, "'((?:[^']|'')*)'")) { $GEX += ($q.Groups[1].Value -replace "''", "'") }
}
foreach ($r in $RELAX) { foreach ($p in $r.pats) { if ($GEX -notcontains $p) { throw "relax token not found VERBATIM in GLOBAL_EXCLUDE: '$p' (id $($r.id))" } } }

$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }
$n = 0

Write-Output 'RECIPROCAL EXCLUDES (on the existing proxy rows):'
foreach ($r in $RECIP) {
  $c = $byId[$r.id]; if (-not $c) { throw "reciprocal target missing: $($r.id)" }
  $have = @($c.exclude); $new = @()
  foreach ($p in $r.pats) { if ($have -notcontains $p) { $new += $p } }
  foreach ($p in $new) { try { [void][regex]::new($p) } catch { throw "pattern does not compile: $p" } }
  if ($new.Count) { Write-Output ("  {0,-18} += {1}" -f $r.id, ($new -join ' , ')); Write-Output ("      why: " + $r.why); $c.exclude = @($have + $new); $n += $new.Count }
  else { Write-Output ("  {0,-18} already fenced" -f $r.id) }
}

Write-Output ''
Write-Output 'OWN-ROW TIGHTENING (from validate-fills over the actual fill rows):'
# 'Gustare Vita GNOCCHI with Ricotta and Spinach' passed the ricotta include, sat in the shared Hy-Vee file, and
# validate-fills showed it resolving to SPINACH - i.e. a primer row from my search able to re-price someone
# else's cell. Fixed on my row (and the row is then purged from the store file), not by loosening spinach.
$TIGHTEN = @( @{ id='ricotta'; pats=@('\bgnocchi\b','\bdumplings?\b') } )
foreach ($t in $TIGHTEN) {
  $c = $byId[$t.id]; if (-not $c) { throw "tighten target not registered: $($t.id)" }
  $have = @($c.exclude); $new = @()
  foreach ($p in $t.pats) { if ($have -notcontains $p) { $new += $p } }
  foreach ($p in $new) { try { [void][regex]::new($p) } catch { throw "pattern does not compile: $p" } }
  if ($new.Count) { Write-Output ("  {0,-18} += {1}" -f $t.id, ($new -join ' , ')); $c.exclude = @($have + $new); $n += $new.Count }
  else { Write-Output ("  {0,-18} already tightened" -f $t.id) }
}

Write-Output ''
Write-Output 'RELAX_GLOBAL:'
foreach ($r in $RELAX) {
  $c = $byId[$r.id]; if (-not $c) { throw "relax target not registered: $($r.id)" }
  $have = @($c.relax_global | Where-Object { $_ }); $new = @()
  foreach ($p in $r.pats) { if ($have -notcontains $p) { $new += $p } }
  if ($new.Count) { Write-Output ("  {0,-18} relax += {1}" -f $r.id, ($new -join ' , ')); Write-Output ("      why: " + $r.why); $c | Add-Member -NotePropertyName relax_global -NotePropertyValue @($have + $new) -Force; $n += $new.Count }
  else { Write-Output ("  {0,-18} already relaxed" -f $r.id) }
}

Write-Output ''
Write-Output 'INCLUDE FIXES (caught by the post-registration diff):'
# 'corn\s+chips?' with no LEADING word boundary matched "Sea Salt Pink PEPPERCORN CHIPS" (a Kettle Brand potato
# chip) and gave it the Baker's corn-chips cell. Same class as the egg/eggPLANT substring bug.
$INCFIX = @( @{ id='corn-chips'; from='corn\s+chips?'; to='\bcorn\s+chips?' } )
foreach ($f in $INCFIX) {
  $c = $byId[$f.id]; if (-not $c) { throw "include-fix target not registered: $($f.id)" }
  $inc = @($c.include)
  if ($inc -contains $f.from) {
    $c.include = @($inc | ForEach-Object { if ($_ -eq $f.from) { $f.to } else { $_ } })
    Write-Output ("  {0,-18} include '{1}' -> '{2}'  (leading \b: 'pepperCORN CHIPS' was matching)" -f $f.id, $f.from, $f.to); $n++
  } else { Write-Output ("  {0,-18} include already fixed" -f $f.id) }
}

Write-Output ''
Write-Output 'EXCLUDE FIXES (caught by the primer-isolation diff):'
# '\bsets\b' did not match the SINGULAR "Red Onion SET" - a bag of planting bulbs from the garden aisle - which
# took the Family Fare red-onion cell at $1.39. Applied inline during the run; kept here so the ruleset is
# reproducible from these scripts alone.
$EXCFIX = @( @{ id='red-onion'; from='\bsets\b'; to='\bsets?\b' } )
foreach ($f in $EXCFIX) {
  $c = $byId[$f.id]; if (-not $c) { throw "exclude-fix target not registered: $($f.id)" }
  $exc = @($c.exclude)
  if ($exc -contains $f.from) {
    $c.exclude = @($exc | ForEach-Object { if ($_ -eq $f.from) { $f.to } else { $_ } })
    Write-Output ("  {0,-18} exclude '{1}' -> '{2}'  (singular 'Red Onion Set' = planting bulbs)" -f $f.id, $f.from, $f.to); $n++
  } else { Write-Output ("  {0,-18} exclude already fixed" -f $f.id) }
}

Write-Output ''
Write-Output 'PINT_OZ:'
$ct = $byId['cherry-tomatoes']; if (-not $ct) { throw 'cherry-tomatoes not registered' }
if (-not $ct.PSObject.Properties['pint_oz']) {
  $ct | Add-Member -NotePropertyName pint_oz -NotePropertyValue 10 -Force
  Write-Output '  cherry-tomatoes    pint_oz = 10   (a bare "1 pt" would otherwise convert to 16 oz and underprice the clamshell 1.6x)'
  $n++
} else { Write-Output '  cherry-tomatoes    pint_oz already set' }

if ($WhatIf) { Write-Output ''; Write-Output "WhatIf: $n change(s), nothing written"; return }
if ($n) { ($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8; $null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json }
Write-Output ''
Write-Output "patch-batch8: $n change(s) applied (commodities.json re-validated as JSON)"
