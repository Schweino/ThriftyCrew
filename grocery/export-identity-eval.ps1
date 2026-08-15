<#
  export-identity-eval.ps1 - build the HARDER identity eval set the sidecar's Phase 1 backtest lacked.

  WHY (2026-08-02, L1). Phase 1 scored AUC 0.985 and that number was misleading, which the Phase 2 wiring
  said out loud: all 25 labelled negatives are DRAMATICALLY wrong - a bath soap as coconut oil, dog food as
  meat - so the eval contained no subtle error at all. When the identity lane then ran on the real board it
  flagged 173 pairs and every one inspected was CORRECT (Wimmer's Wieners vs Hot Dogs, Kroger Olive Oil Mayo
  vs Mayonnaise, Yellow Bananas vs Bananas). A model that separates soap from oil tells you nothing about
  whether it can separate a wiener from a hot dog, and the second question is the one the lane exists for.

  So this is a backtest-design fix, not a model change. It exports three files:

    negatives-gold.json     THE 63 ADJUDICATED RULINGS from known-wrong.json, expanded over every spelling
                            each ruling covers. These are the real thing: a reasoner looked at the product
                            and the commodity and ruled they are not the same. They include the subtle
                            shapes the old set had none of - sandwich cookies matched into FROSTING on the
                            words "Butter Cream Icing", a ready-to-drink oat milk latte matched into COFFEE.
    hardneg-candidates.json every (commodity, product) pair mined as a NEAR MISS: the product is assigned
                            to some other commodity and the candidate commodity's rules REJECT it, so the
                            pair is a true negative - but it was chosen because the two are confusable.
                            The regex verdict is computed HERE, in the same first-match-wins semantics the
                            engine uses, because Python never re-implements the corpus rules.
    eval-positives.json     the accepted board pairs, unchanged, as the positive class.

  THE ONE JUDGEMENT CALL, stated: a pair is only mined as a negative when the candidate commodity's own
  rules reject the product. A product that BOTH commodities' rules accept is genuinely contested (the
  board has 477 such names) and labelling it either way would teach the eval a lie, so those are skipped
  and counted. That keeps the negative set honest at the cost of leaving the hardest cases of all - the
  truly ambiguous ones - out of the measurement, which is a limit worth naming rather than hiding.

  Usage: .\export-identity-eval.ps1 [-TopK 8] [-SelfTest]
#>
param([int]$TopK = 8, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$root = if ($Root) { $Root } elseif ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$sd = Join-Path (Split-Path $root -Parent) 'sidecar\data'

function Get-RuleIndex($coms) {
  $inc = New-Object System.Collections.Generic.List[object]
  $exc = @{}
  foreach ($c in $coms) {
    foreach ($p in @($c.include)) { if ($p) { $inc.Add([pscustomobject]@{ id = [string]$c.id; r = [regex]::new([string]$p, 'IgnoreCase,Compiled') }) } }
    $l = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($c.exclude)) { if ($p) { $l.Add([regex]::new([string]$p, 'IgnoreCase,Compiled')) } }
    $exc[[string]$c.id] = $l
  }
  return @{ inc = $inc; exc = $exc }
}
function Test-CommodityAccepts($idx, [string]$cid, [string]$name) {
  <# Does commodity $cid's OWN rule set accept this product? Include-then-exclude, exactly as the engine
     evaluates a single commodity. NOT first-match-wins across commodities - that decides which commodity
     WINS a product, and the question here is whether this one would take it at all. #>
  $hit = $false
  foreach ($e in $idx.inc) { if ($e.id -eq $cid -and $e.r.IsMatch($name)) { $hit = $true; break } }
  if (-not $hit) { return $false }
  foreach ($xp in $idx.exc[$cid]) { if ($xp.IsMatch($name)) { return $false } }
  return $true
}

if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  $fx = @(
    [pscustomobject]@{ id = 'broccoli';    label = 'Broccoli';    include = @('broccoli'); exclude = @('\bcauliflower\b','\bfrozen\b') },
    [pscustomobject]@{ id = 'cauliflower'; label = 'Cauliflower'; include = @('cauliflower'); exclude = @('\bbroccoli\b') },
    [pscustomobject]@{ id = 'coffee';      label = 'Coffee';      include = @('coffee'); exclude = @() }
  )
  $idx = Get-RuleIndex $fx
  Chk 'a commodity accepts its own product' (Test-CommodityAccepts $idx 'broccoli' 'Great Value Broccoli Florets, 14 oz') 'rejected'
  Chk 'an EXCLUDE overrides the include (the medley case)' (-not (Test-CommodityAccepts $idx 'broccoli' 'Marketside Fresh Broccoli and Cauliflower Medley')) 'accepted'
  Chk 'a commodity rejects a product it has no include for' (-not (Test-CommodityAccepts $idx 'coffee' 'Great Value Broccoli Florets')) 'accepted'
  # THE MINING RULE: a pair is a valid negative ONLY when the candidate commodity rejects the product.
  # 'Onyx Coffee Lab Salted Mocha Oat Milk Latte' is an adjudicated WRONG product for coffee, and coffee's
  # rules still ACCEPT it - which is exactly why it shipped. It must never be mined as a clean negative;
  # it belongs to the GOLD set, where the label comes from a reasoner and not from the rules.
  Chk 'a rule-accepted product is NOT minable as a negative (it is contested, not clean)' (Test-CommodityAccepts $idx 'coffee' 'Onyx Coffee Lab Salted Mocha Oat Milk Latte, 11 fl oz Can') 'rejected'
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

if (-not (Test-Path $sd)) { throw "sidecar data dir not found: $sd (run audit-semantic-identity.ps1 -PrepareOnly first)" }
$coms = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$idx = Get-RuleIndex $coms
$labelOf = @{}
foreach ($c in $coms) { $labelOf[[string]$c.id] = [string]$c.label }

# ---- 1. GOLD negatives from the adjudicated blocklist
$kw = Get-Content (Join-Path $root 'known-wrong.json') -Raw | ConvertFrom-Json
$gold = New-Object System.Collections.Generic.List[object]
$goldRuleAccepted = 0
foreach ($e in @($kw.entries)) {
  if (([string]$e.verdict) -ne 'wrong-product') { continue }
  $cid = [string]$e.commodity
  foreach ($n in @($e.names)) {
    if (-not $n) { continue }
    $accepted = Test-CommodityAccepts $idx $cid ([string]$n)
    if ($accepted) { $goldRuleAccepted++ }
    $gold.Add([pscustomobject]@{
      id = $cid; commodity = $(if ($labelOf.ContainsKey($cid)) { $labelOf[$cid] } else { $cid })
      store = [string]$e.store; product = [string]$n
      source = 'known-wrong'; rules_accept = $accepted; ruled_by = [string]$e.ruled_by
    })
  }
}
($gold.ToArray() | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $sd 'negatives-gold.json') -Encoding UTF8
Write-Output ("negatives-gold.json: {0} adjudicated wrong-product pair(s) from {1} ruling(s); {2} of them are STILL ACCEPTED by that commodity's rules (which is why they had to be blocklisted)" -f $gold.Count, @($kw.entries).Count, $goldRuleAccepted)

# ---- 2. positives, unchanged
$pos = Get-Content (Join-Path $sd 'positives.json') -Raw | ConvertFrom-Json
($pos | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $sd 'eval-positives.json') -Encoding UTF8
Write-Output ("eval-positives.json: {0} accepted board pair(s)" -f @($pos).Count)

# ---- 3. the mining SURFACE. Python picks which commodities are near; this says which pairs are LEGAL
# negatives at all, so the regex verdict never leaves PowerShell.
$prodSet = @{}
foreach ($p in @($pos)) { $prodSet[[string]$p.product] = [string]$p.id }
$rows = New-Object System.Collections.Generic.List[object]
foreach ($p in @($pos)) { $rows.Add([pscustomobject]@{ product = [string]$p.product; owner = [string]$p.id }) }
($rows.ToArray() | ConvertTo-Json -Depth 3 -Compress) | Set-Content (Join-Path $sd 'mine-products.json') -Encoding UTF8
Write-Output ("mine-products.json: {0} product(s) to mine near-miss commodities for (TopK={1} chosen in Python)" -f $rows.Count, $TopK)
Write-Output 'next: sidecar\hardeval.py mines candidates, then re-run this with -Label to stamp the regex verdict.'
exit 0
