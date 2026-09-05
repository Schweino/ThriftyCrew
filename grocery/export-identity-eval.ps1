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
         .\export-identity-eval.ps1 -Label          # after sidecar\hardeval.py --stage mine

  THE -Label STAGE (added 2026-08-23). Mining is a two-language round trip on purpose: Python picks
  which commodities are semantically NEAR a product, PowerShell rules whether the pair is a legal
  negative, because the regex lives here and Python never re-implements the corpus rules. -Label is
  the return leg - it reads mine-candidates.json and stamps rules_accept on every row. Until
  2026-08-23 it was only a sentence in a Write-Output, which is why every hardeval report ever
  written says `mined: 0`.
#>
param([int]$TopK = 8, [switch]$SelfTest, [switch]$Label, [string]$Root = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($Root) { $Root } elseif ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$sd = Join-Path (Split-Path $root -Parent) 'sidecar\data'

function Get-RuleIndex($coms) {
  $inc = New-Object System.Collections.Generic.List[object]
  $exc = @{}
  $incById = @{}
  foreach ($c in $coms) {
    $il = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($c.include)) {
      if ($p) {
        $rx = [regex]::new([string]$p, 'IgnoreCase,Compiled')
        $inc.Add([pscustomobject]@{ id = [string]$c.id; r = $rx })   # ordered, for first-match-wins callers
        $il.Add($rx)
      }
    }
    $incById[[string]$c.id] = $il
    $l = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($c.exclude)) { if ($p) { $l.Add([regex]::new([string]$p, 'IgnoreCase,Compiled')) } }
    $exc[[string]$c.id] = $l
  }
  return @{ inc = $inc; exc = $exc; incById = $incById }
}
function Test-CommodityAccepts($idx, [string]$cid, [string]$name) {
  <# Does commodity $cid's OWN rule set accept this product? Include-then-exclude, exactly as the engine
     evaluates a single commodity. NOT first-match-wins across commodities - that decides which commodity
     WINS a product, and the question here is whether this one would take it at all. #>
  $hit = $false
  # $incById is this commodity's includes only. Scanning the whole ordered list was the same answer
  # and 588x the work; -Label asks this question ~22,000 times.
  # No @() around the lookup: in PS 5.1 @(<empty List[object]>) throws "Argument types do not match",
  # and a commodity with zero include patterns is a real row.
  foreach ($rx in $idx.incById[$cid]) { if ($rx.IsMatch($name)) { $hit = $true; break } }
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
    [pscustomobject]@{ id = 'coffee';      label = 'Coffee';      include = @('coffee'); exclude = @() },
    [pscustomobject]@{ id = 'no-rules';     label = 'No Rules';     include = @(); exclude = @() }
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
  # A commodity with NO include patterns is a real row, and the lookup used to throw on it rather
  # than answer - which -Label would have hit ~22,000 times. Proven able to fail before it is trusted.
  $threw = $false
  try { $r = Test-CommodityAccepts $idx 'no-rules' 'Great Value Broccoli Florets' } catch { $threw = $true }
  Chk 'a commodity with zero include patterns answers NO instead of throwing' ((-not $threw) -and (-not $r)) $(if ($threw) { 'threw' } else { 'accepted' })
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

# ---- -Label: the return leg of the mining round trip.
# Python proposed the near pairs; this stamps the regex verdict on each one, in the same
# include-then-exclude semantics Test-CommodityAccepts uses everywhere else in this file.
if ($Label) {
  if (-not (Test-Path $sd)) { throw "sidecar data dir not found: $sd" }
  $cp = Join-Path $sd 'mine-candidates.json'
  if (-not (Test-Path $cp)) { throw "no mine-candidates.json: run `python sidecar\hardeval.py --stage mine --defs sidecar\data\frozen\phase3-baseline\commodity-defs.json` first" }
  $coms = Read-JsonFile (Join-Path $root 'commodities.json')
  $idx = Get-RuleIndex $coms
  $labelOf = @{}
  foreach ($c in $coms) { $labelOf[[string]$c.id] = [string]$c.label }

  $raw = Read-JsonFile $cp
  $cands = if ($raw.PSObject.Properties.Name -contains 'pairs') { @($raw.pairs) } else { @($raw) }
  Write-Output ("mine-candidates.json: {0} candidate pair(s), mined from {1}" -f $cands.Count, $(if ($raw.defs) { $raw.defs } else { 'an unrecorded def set' }))

  $out = New-Object System.Collections.Generic.List[object]
  $rejected = 0; $accepted = 0; $unknown = 0; $selfPair = 0
  $seen = @{}
  foreach ($r in $cands) {
    $cid = [string]$r.candidate
    $name = [string]$r.product
    if (-not $cid -or -not $name) { continue }
    # A pair whose candidate IS the owner is not a near miss, it is the row itself. Python already
    # skips these; the check is here too because this file is the one that decides what a negative is.
    if ($cid -eq [string]$r.owner) { $selfPair++; continue }
    if (-not $labelOf.ContainsKey($cid)) { $unknown++; continue }
    $k = $cid + [char]1 + $name   # `u{...} is PS6+; this file must run under 5.1
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = $true
    $acc = Test-CommodityAccepts $idx $cid $name
    if ($acc) { $accepted++ } else { $rejected++ }
    $out.Add([pscustomobject]@{
      product = $name; owner = [string]$r.owner; candidate = $cid
      commodity = $labelOf[$cid]; cos = $r.cos
      # Carried through from the mining stage, never recomputed here: `via` says WHY the pair was
      # proposed (the cosine margin, or a round-2 reranker that still believed it) and `ce` is what
      # that reranker said. A corpus that cannot say which round a negative came from cannot answer
      # "which pile taught it that" later.
      delta = $r.delta; via = $r.via; ce = $r.ce
      rules_accept = $acc; source = 'mined-near-miss'
    })
  }
  $payload = [pscustomobject]@{
    generated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    mined_from = $(if ($raw.defs) { [string]$raw.defs } else { $null })
    mined_generated = $(if ($raw.generated) { [string]$raw.generated } else { $null })
    labelled_by = 'export-identity-eval.ps1 -Label (commodities.json regex, include-then-exclude)'
    candidates = $cands.Count; clean_negatives = $rejected; contested_skipped = $accepted
    unknown_commodity = $unknown; self_pairs = $selfPair
    pairs = $out.ToArray()
  }
  ($payload | ConvertTo-Json -Depth 4 -Compress) | Set-Content (Join-Path $sd 'mine-labelled.json') -Encoding UTF8
  Write-Output ("mine-labelled.json: {0} CLEAN near-miss negative(s) (the candidate's own rules reject the product)" -f $rejected)
  # These are the honest limit named in the header: both commodities accept the name, so the pair is
  # genuinely contested and labelling it either way would teach the eval a lie.
  Write-Output ("  {0} pair(s) SKIPPED as contested - the candidate's rules accept the product too" -f $accepted)
  if ($unknown) { Write-Output ("  {0} pair(s) name a commodity absent from commodities.json - not guessed at" -f $unknown) }
  Write-Output 'next: sidecar\hardeval.py --stage score (mined AUC), then sidecar\build_pair_corpus.py'
  exit 0
}

if (-not (Test-Path $sd)) { throw "sidecar data dir not found: $sd (run audit-semantic-identity.ps1 -PrepareOnly first)" }
$coms = Read-JsonFile (Join-Path $root 'commodities.json')
$idx = Get-RuleIndex $coms
$labelOf = @{}
foreach ($c in $coms) { $labelOf[[string]$c.id] = [string]$c.label }

# ---- 1. GOLD negatives from the adjudicated blocklist
$kw = Read-JsonFile (Join-Path $root 'known-wrong.json')
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
$pos = Read-JsonFile (Join-Path $sd 'positives.json')
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
