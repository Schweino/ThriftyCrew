<#
  tighten-r300.ps1 - round-2 exclude tightening for the r300 batch, driven by what the FIRST primer pass
  actually put on the board (diff r300-afterreg -> r300-afterprimer). Every pattern here fixes a REAL row that
  landed, not a hypothetical:

    turkey-breast   'Buddig Turkey Breast, Oven Roasted 9 Oz' (deli lunchmeat) and 'Lean Cuisine Signature
                    Roasted Turkey Breast, Frozen Turkey Dinner' (frozen entree) both priced the RAW breast
                    row. The \bfrozen\b relax this commodity needs is exactly what let the TV dinner in, so the
                    entree/dinner class has to be fenced by name.
                    Also 'Marie Callender's Turkey Breast & Stuffing' - contributed by the turkey-breast search
                    but claimed by STUFFING-MIX (earlier in the array), which re-priced an existing cell. That
                    is the primer-pollution failure mode; the fix belongs in the searched commodity's rules.
                    Also 'Hy-Vee Oven Roasted Turkey Breast' -> turkey-lunchmeat (a cheaper, legitimate deli
                    product, but still an EXISTING cell moved by my batch, which is not allowed to happen
                    silently).
    wild-rice       'Canoe White n Wild Rice' and 'Hy-Vee Select Long Grain Brown & Wild Rice' are BLENDS -
                    mostly cheap white/brown rice - and they undercut real wild rice by ~10x per oz. My first
                    blend fence ('\bblend\b' + 'long grain and wild') missed both spellings.
    sazon-seasoning 'La Preferida Sazon All Purpose Seasoning 8 oz' is the adobo-class 8 oz shaker, not the
                    1.41 oz sazon box - different price class (the same reason adobo was not folded in).
    dried chiles    'McCormick Gourmet Ancho Chile Pepper' - the McCormick Gourmet chile line is GROUND jarred
                    spice, not whole pods, and its name never says powder.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\income\grocery'

$ADD = @(
  # round 3: every remaining Family Fare match was DELI lunchmeat under a brand turkey-lunchmeat's include
  # does not reach ('Oscar Mayer Cracked Black Pepper Turkey Breast', 'Land O'Frost Honey Roasted Turkey
  # Breast & White Turkey'). Fenced by deli brand + deli phrasing on MY row (never by loosening the existing
  # turkey-lunchmeat include, which would move existing cells).
  @{ id='turkey-breast'; pats=@('\bentree\b','\bdinner\b','marie\s+callender','lean\s+cuisine','stouffer','healthy\s+choice','banquet','\bbuddig\b','oven\s+roasted','\bstuffing\b','\bmeals?\b','\brotisserie\b','\bcarved?\b','\bcarving\b','\bdeli\s*style\b','land\s*o.?\s*frost','oscar\s+mayer','hillshire','prime\s+fresh','honey\s+roasted','cracked\s+black\s+pepper','\bslices?\b','\bthin\b','white\s+turkey') }
  @{ id='wild-rice';     pats=@('\bwhite\b','\bbrown\b','long\s+grain','basmati','jasmine','\bmedley\b','\bblends?\b','wild\s+rice\s+(?:&|and)') }
  @{ id='sazon-seasoning'; pats=@('all\s+purpose','all-purpose') }
  # round 4, from validate-fills over the actual fill rows:
  #   'Wild Rice Bratwurst' matched wild-rice's include and would have sat in the Hy-Vee file able to
  #     re-price the BRATWURST cell (validate-fills flagged it before it won anything).
  #   'Chile De Arbol MOLIDO' is GROUND arbol - my form fence was English-only ('powder'/'ground').
  #   'Mateo's Medium Ancho Chile TACO SEASONING' is a seasoning, not pods.
  @{ id='wild-rice';     pats=@('\bbratwurst\b','\bsausage\b','\bburger\b','\bbrat\b') }
  # round 5 replacement for the withdrawn n.{0,2}\s*wild\s+rice pattern (see $REMOVE below): the blend
  # spellings are already covered by \bwhite\b / \bbrown\b / long\s+grain, plus this ANCHORED apostrophe form.
  @{ id='wild-rice';     pats=@("(?:white|brown|long\s*grain)\s*'?\s*n'?\s+wild") }
  @{ id='dried-ancho-chiles';    pats=@('\bgourmet\b','\bmolido\b','en\s+polvo','\btaco\b','\bseasoning\b','\bmarinade\b') }
  @{ id='dried-arbol-chiles';    pats=@('\bgourmet\b','\bmolido\b','en\s+polvo','\btaco\b','\bseasoning\b','\bmarinade\b') }
  @{ id='dried-guajillo-chiles'; pats=@('\bgourmet\b','\bmolido\b','en\s+polvo','\btaco\b','\bseasoning\b','\bmarinade\b') }
)

# WITHDRAWN patterns - a tightening that turned out to be too greedy. 'n.{0,2}\s*wild\s+rice' was meant to catch
# "White'n Wild Rice"; it also matched "LundbergORGANIC WILD RICE" (the 'n' of organic), i.e. it rejected a
# genuine 100% wild rice. Caught by the post-tightening probe re-run, which is why the probe runs LAST as well
# as first: an exclude can silently kill the item it was written to protect.
$REMOVE = @( @{ id='wild-rice'; pats=@('n.{0,2}\s*wild\s+rice') } )

$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }
$n = 0
foreach ($r in $REMOVE) {
  $c = $byId[$r.id]; if (-not $c) { continue }
  $before = @($c.exclude)
  $after = @($before | Where-Object { $r.pats -notcontains $_ })
  if ($after.Count -ne $before.Count) { Write-Output ("  {0,-22} -= {1}  (withdrawn: too greedy)" -f $r.id, ($r.pats -join ' , ')); $c.exclude = $after; $n++ }
}
foreach ($a in $ADD) {
  $c = $byId[$a.id]; if (-not $c) { throw "tighten target not registered: $($a.id)" }
  $have = @($c.exclude); $new = @()
  foreach ($p in $a.pats) { if ($have -notcontains $p) { $new += $p } }
  foreach ($p in $new) { try { [void][regex]::new($p) } catch { throw "pattern does not compile: $p" } }
  if ($new.Count) { Write-Output ("  {0,-22} += {1}" -f $a.id, ($new -join ' , ')); $c.exclude = @($have + $new); $n += $new.Count }
  else { Write-Output ("  {0,-22} already tightened" -f $a.id) }
}
if ($WhatIf) { Write-Output ''; Write-Output "WhatIf: $n pattern(s)"; return }
if ($n) { ($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8; $null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json }
Write-Output ''
Write-Output "tightening patterns added: $n"
