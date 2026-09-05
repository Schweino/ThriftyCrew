<#
  repair-missing-scaler-bid.ps1 - heal a scaler.ing block that carries NO bid while its vocabulary row
  already knows one.

  THE DEFECT (2026-08-29). Three LIVE paid specs carry an ingredient line with no `bid` and no `gpu`:

      baked-turkey-kibbeh-casserole  Bulgur Wheat  957 g   vocabulary bid: bulgur-wheat
      musakhan-sumac-chicken         Sumac          62 g   vocabulary bid: ground-sumac
      turkey-meatball-sub-bake       Keto Bun     1320 g   vocabulary bid: NULL (Brad's ruling pending)

  WHAT IT IS NOT. It is not a price bug, and the brief that found it said it was. cost-recipes.ps1 does
  not read the spec's bid at all - it lifts canon+grams from the spec (line 37) and resolves the bid from
  db\ingredients.json (line 187). NEUTER-PROVED 2026-08-29: stripping a WORKING bid ("fresh-mint" + gpu)
  out of the kibbeh spec and recosting produced a byte-identical costed record - ps=2.81, batch=39.32,
  lines_priced=9, lines_unpriced=0, mint still $3.77. All three ingredients were already priced on the
  live pages (Bulgur $6.81 off a Walmart label, Sumac $2.46 off The Spice Way 8 oz, Keto Bun $15.90 off
  bettergoods 14 oz). No published per-serving number ever omitted them.

  WHAT IT ACTUALLY BREAKS is the INTERACTIVE scaler, which is fail-closed by design. tpl2-scaler-prefix
  line 317 returns null for the whole batch total if ANY line prices to null, and price() returns null
  when `it.bid` is falsy. So on all three live cards the reader sees the ingredient row read "Price
  unavailable in this release", the grand total read "Unavailable - one or more release prices are
  missing" (line 385), the cost-composition chart hidden (line 333), and the shopping-list total read
  "Unavailable". The static prose number beside it is correct and complete. A dark feature on a paid
  page, not a understated price - the opposite severity, and worth stating because the guard that finds
  these rows still claims they cost $0.00.

  THE RULE, and it is narrow: a block is healed ONLY when its vocabulary row already carries the bid.
  This script never invents a commodity id, never picks between candidates, and never allowlists. A
  bid-less vocabulary row (Keto Bun) is a product-class RULING and is reported, never guessed - which is
  why Keto Bun is untouched by a script that fixes the two beside it. Minting an id is the commodity
  registrar's job, not a repair's.

  GPU IS RECONCILED, NOT COPIED. gpu means "grams in one unit of the basis the FEED quotes", so copying
  the vocabulary's gpu blind serves a wrong price whenever the map unit and the live unit differ. This
  reproduces build-v2-spec.ps1's Resolve-ScalerGpu exactly (same UNIT_G table, same '0.000' GpuStr
  format), because a spec healed by this script must be indistinguishable from one the builder wrote.
  A non-standard unit mismatch leaves gpu as mapped and FLAGS it, same as the builder.

  PROSE-SAFE. Targeted, object-scoped string edits, never a re-serialize: the prose carries \uXXXX
  escapes that a ConvertTo-Json round trip rewrites. The block is selected by IDENTITY (canon, or item on
  the pre-canon specs) and the match must be UNIQUE or the spec is refused - the lesson rebid-ingredient
  learned when it selected blocks by bid and found 14 bids shared across rows. Every file is
  parse-verified before it is written, written BOM-less, and its CRLF line endings are preserved.

  AFTER RUNNING, the spec's machine fields have moved, so the rest of the chain must follow:
    engine\cost-recipes.ps1 -> pipeline\recost-spec-cost-block.ps1 -Slugs <slugs>
    -> pipeline\reanchor-machine-fields.ps1 -Slugs <slugs> -> pipeline\sync-recipesdb-cost.ps1
    -> rebuild the cards, then republish them.

  Usage: repair-missing-scaler-bid.ps1 [-Apply] [-Slugs a,b] [-SelfTest]
         Read-only by default: prints what it would change and writes nothing.
  Exit 0 clean/applied, 1 blocks needing a ruling remain, 2 self-test failure.
#>
param([switch]$Apply, [string[]]$Slugs = @(), [switch]$SelfTest, [string]$Root = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')

$UNIT_G = @{ lb = 453.592; oz = 28.3495; floz = 29.57; kg = 1000.0; g = 1.0 }

function Format-Gpu([double]$v) { $v.ToString('0.000') }

function Resolve-ScalerGpu {
  <# Ported from build-v2-spec.ps1 Resolve-ScalerGpu. gpu is grams per the unit the FEED quotes; the
     widget computes feed.cheapest * grams/gpu. Returns @{ Gpu; Flag } - Flag is '' or a warning. #>
  param([double]$Gpu, [string]$MapUnit, [string]$RowUnit, [string]$Item, [string]$Bid)
  if (-not $RowUnit -or -not $MapUnit -or $RowUnit -eq $MapUnit) { return @{ Gpu = $Gpu; Flag = '' } }
  if ($UNIT_G.ContainsKey($MapUnit) -and $UNIT_G.ContainsKey($RowUnit)) {
    return @{ Gpu = ($Gpu * ($UNIT_G[$RowUnit] / $UNIT_G[$MapUnit])); Flag = '' }
  }
  return @{ Gpu = $Gpu; Flag = ("{0} [{1}] NON-STANDARD UNIT MISMATCH map={2} live={3} (gpu left as mapped)" -f $Item, $Bid, $MapUnit, $RowUnit) }
}

# ---------------------------------------------------------------------------------------------------
# THE PREDICATE, kept pure so the fixtures test the same code the sweep runs. Spec + vocabulary + feed
# units in, decisions out. Never touches disk.
#   $Vocab     : identity (name or alias) -> @{ bid; gpu; unit }
#   $FeedUnits : bid -> live unit string
# Returns objects with Verdict = 'HEAL' (vocabulary knows the bid) or 'RULING' (it does not) or
# 'NO-IDENTITY' (the block declares neither canon nor item, which is a refusal, not a default).
# ---------------------------------------------------------------------------------------------------
function Get-MissingBidEdits {
  param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)]$Vocab, $FeedUnits = @{})
  $out = New-Object System.Collections.Generic.List[object]
  $ing = @($Spec.scaler.ing)
  for ($i = 0; $i -lt $ing.Count; $i++) {
    $e = $ing[$i]
    # already bid? nothing to do. An empty-string bid counts as missing, same rule audit-unbid uses.
    $hasBid = $false
    if ($e -and ($e.PSObject.Properties.Name -contains 'bid')) {
      $b = [string]$e.bid
      if ($b -and $b.Trim() -ne '') { $hasBid = $true }
    }
    if ($hasBid) { continue }

    $canon = ''
    if ($e -and ($e.PSObject.Properties.Name -contains 'canon') -and $e.canon) { $canon = [string]$e.canon }
    elseif ($e -and ($e.PSObject.Properties.Name -contains 'item') -and $e.item) { $canon = [string]$e.item }
    $item = if ($e -and ($e.PSObject.Properties.Name -contains 'item')) { [string]$e.item } else { '' }

    if (-not $canon) {
      $out.Add([pscustomobject]@{ Index = $i; Item = $item; Canon = ''; Verdict = 'NO-IDENTITY'; Bid = ''; Gpu = ''; Why = 'block declares neither canon nor item'; Flag = '' })
      continue
    }

    if (-not $Vocab.ContainsKey($canon)) {
      $out.Add([pscustomobject]@{ Index = $i; Item = $item; Canon = $canon; Verdict = 'RULING'; Bid = ''; Gpu = ''; Why = 'no vocabulary row for this name'; Flag = '' })
      continue
    }
    $row = $Vocab[$canon]
    $rowBid = [string]$row.bid
    if (-not $rowBid -or $rowBid.Trim() -eq '') {
      $out.Add([pscustomobject]@{ Index = $i; Item = $item; Canon = $canon; Verdict = 'RULING'; Bid = ''; Gpu = ''; Why = 'vocabulary row is deliberately bid-less - product-class ruling required'; Flag = '' })
      continue
    }
    $rowGpu = [double]$row.gpu
    if (-not ($rowGpu -gt 0)) {
      $out.Add([pscustomobject]@{ Index = $i; Item = $item; Canon = $canon; Verdict = 'RULING'; Bid = $rowBid; Gpu = ''; Why = 'vocabulary row carries no usable gpu'; Flag = '' })
      continue
    }
    $mapUnit = if ($row.PSObject.Properties.Name -contains 'unit') { [string]$row.unit } else { '' }
    $liveUnit = if ($FeedUnits.ContainsKey($rowBid)) { [string]$FeedUnits[$rowBid] } else { '' }
    $r = Resolve-ScalerGpu -Gpu $rowGpu -MapUnit $mapUnit -RowUnit $liveUnit -Item $canon -Bid $rowBid
    $out.Add([pscustomobject]@{ Index = $i; Item = $item; Canon = $canon; Verdict = 'HEAL'; Bid = $rowBid; Gpu = (Format-Gpu $r.Gpu); Why = ''; Flag = $r.Flag })
  }
  return $out
}

# ---------------------------------------------------------------------------------------------------
# THE SPLICE. Inserts "bid" and "gpu" into ONE flat scaler.ing object, matched by identity, preserving
# the file's own indentation and separator style. Returns @{ text; ok; why }.
# ---------------------------------------------------------------------------------------------------
function Add-BidToBlock {
  param([Parameter(Mandatory)][string]$Raw, [Parameter(Mandatory)][string]$Canon,
        [Parameter(Mandatory)][string]$Bid, [Parameter(Mandatory)][string]$Gpu)
  # scaler.ing blocks are FLAT objects, so [^{}]* is a safe body match. Require the block to carry the
  # identity AND "grams" AND "buy", which no other object in the spec does.
  $esc = [regex]::Escape($Canon)
  $rx  = '\{[^{}]*"(?:canon|item)":\s*"' + $esc + '"[^{}]*"grams":[^{}]*"buy":[^{}]*\}'
  $ms  = [regex]::Matches($Raw, $rx)
  if ($ms.Count -eq 0) { return @{ text = $Raw; ok = $false; why = "no scaler block matched '$Canon'" } }
  if ($ms.Count -gt 1) { return @{ text = $Raw; ok = $false; why = "identity '$Canon' matched $($ms.Count) blocks - refusing rather than guessing" } }
  $blk = $ms[0].Value
  if ($blk -match '"bid":\s*"[^"]+"') { return @{ text = $Raw; ok = $false; why = "block for '$Canon' already carries a bid" } }

  # Learn the file's own style from the "buy" line: its leading whitespace and the gap after the colon.
  $bm = [regex]::Match($blk, '(?m)^([ \t]*)"buy":(\s*)"')
  $indent = if ($bm.Success) { $bm.Groups[1].Value } else { '  ' }
  $gap    = if ($bm.Success -and $bm.Groups[2].Value) { $bm.Groups[2].Value } else { ' ' }
  $nl     = if ($blk -match "`r`n") { "`r`n" } else { "`n" }
  # The block's last property ends just before the closing brace; append after it.
  $tail   = [regex]::Match($blk, '(?s)^(.*?)(\s*)\}$')
  if (-not $tail.Success) { return @{ text = $Raw; ok = $false; why = "could not locate the closing brace of '$Canon'" } }
  $body   = $tail.Groups[1].Value.TrimEnd()
  $close  = $tail.Groups[2].Value
  $add    = ',' + $nl + $indent + '"bid":' + $gap + '"' + $Bid + '",' + $nl + $indent + '"gpu":' + $gap + '"' + $Gpu + '"'
  $newBlk = $body + $add + $close + '}'
  $out    = $Raw.Remove($ms[0].Index, $ms[0].Length).Insert($ms[0].Index, $newBlk)
  return @{ text = $out; ok = $true; why = '' }
}

# ---- self-test -------------------------------------------------------------------------------------
if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + '   got: ' + $got); $script:fail++ }
  }

  # FROZEN VOCABULARY - the three real rows, plus a unit-mismatch case.
  $vocab = @{
    'Bulgur Wheat' = [pscustomobject]@{ bid = 'bulgur-wheat';  gpu = 28.3495; unit = 'oz' }
    'Sumac'        = [pscustomobject]@{ bid = 'ground-sumac';  gpu = 28.3495; unit = 'oz' }
    'Keto Bun'     = [pscustomobject]@{ bid = $null;           gpu = 50;      unit = 'each' }
    'Big Flour'    = [pscustomobject]@{ bid = 'flour';         gpu = 453.592; unit = 'lb' }
    'Apple'        = [pscustomobject]@{ bid = 'apples';        gpu = 175.0;   unit = 'each' }
    'Odd Thing'    = [pscustomobject]@{ bid = 'odd-thing';     gpu = 100.0;   unit = 'bunch' }
  }
  $feed = @{ 'bulgur-wheat' = 'oz'; 'flour' = 'oz'; 'apples' = 'lb'; 'odd-thing' = 'sprig' }

  $fx = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Bulgur Wheat'; canon = 'Bulgur Wheat'; grams = 957;  buy = '6.75 cups' },
    [pscustomobject]@{ item = 'Salt';         canon = 'Salt';         grams = 61;   buy = '3.5 tbsp'; bid = 'salt'; gpu = '28.350' }) } }
  $e = @(Get-MissingBidEdits -Spec $fx -Vocab $vocab -FeedUnits $feed)
  Chk 'MUST FIRE  a bid-less block whose vocabulary knows the bid is healed' `
    ($e.Count -eq 1 -and $e[0].Verdict -eq 'HEAL' -and $e[0].Bid -eq 'bulgur-wheat' -and $e[0].Gpu -eq '28.350') `
    (($e | ForEach-Object { $_.Canon + '=' + $_.Verdict + '/' + $_.Bid + '/' + $_.Gpu }) -join ' | ')
  Chk 'CLEAN TWIN a block that already carries a bid is not re-edited' `
    (@($e | Where-Object { $_.Canon -eq 'Salt' }).Count -eq 0) (($e | ForEach-Object { $_.Canon }) -join ' | ')

  # THE RULING FLOOR. Keto Bun's row is deliberately bid-less; this script must REPORT, never invent.
  $fxK = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Keto Bun'; canon = 'Keto Bun'; grams = 1320; buy = '26.4 buns' }) } }
  $eK = @(Get-MissingBidEdits -Spec $fxK -Vocab $vocab -FeedUnits $feed)
  Chk 'MUST NOT FIRE  a deliberately bid-less vocabulary row is reported, never guessed' `
    ($eK.Count -eq 1 -and $eK[0].Verdict -eq 'RULING' -and $eK[0].Bid -eq '') `
    (($eK | ForEach-Object { $_.Verdict + '/' + $_.Bid }) -join ' | ')

  # A NAME THE VOCABULARY HAS NEVER HEARD OF is a mapping problem, not a repair.
  $fxU = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Moon Cheese'; canon = 'Moon Cheese'; grams = 10; buy = '1 oz' }) } }
  $eU = @(Get-MissingBidEdits -Spec $fxU -Vocab $vocab -FeedUnits $feed)
  Chk 'MUST NOT FIRE  an unknown name is reported as needing a ruling, not healed' `
    ($eU.Count -eq 1 -and $eU[0].Verdict -eq 'RULING') (($eU | ForEach-Object { $_.Verdict }) -join ' | ')

  # A BLOCK WITH NO IDENTITY refuses. Positive identification or nothing.
  $fxN = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ grams = 100; buy = '1 cup' }) } }
  $eN = @(Get-MissingBidEdits -Spec $fxN -Vocab $vocab -FeedUnits $feed)
  Chk 'MUST FIRE  a block declaring neither canon nor item is refused, not defaulted' `
    ($eN.Count -eq 1 -and $eN[0].Verdict -eq 'NO-IDENTITY') (($eN | ForEach-Object { $_.Verdict }) -join ' | ')

  # GPU RECONCILIATION. Big Flour is mapped per-lb (453.592 g) and the feed quotes per-oz: gpu must move
  # to 28.350, not stay at 453.592. This is the whole "a bid is three fields" lesson in one case - a gpu
  # left on the map's unit quotes a price 16x wrong while every guard reads green.
  $fxA = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Big Flour'; canon = 'Big Flour'; grams = 350; buy = '12 oz' }) } }
  $eA = @(Get-MissingBidEdits -Spec $fxA -Vocab $vocab -FeedUnits $feed)
  Chk 'MUST FIRE  gpu is reconciled to the unit the FEED quotes, not copied from the map' `
    ($eA.Count -eq 1 -and $eA[0].Gpu -eq '28.350') (($eA | ForEach-Object { $_.Gpu }) -join ' | ')

  # AN UNCONVERTIBLE PAIR IS NOT A CONVERSION. 'each' is not in UNIT_G, so an each->lb move is a
  # non-standard mismatch and gpu stays as mapped - build-v2-spec.ps1 behaves exactly this way, and a
  # port that "improved" on it would silently disagree with every spec the builder has ever written.
  $fxE = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Apple'; canon = 'Apple'; grams = 350; buy = '2 apples' }) } }
  $eE = @(Get-MissingBidEdits -Spec $fxE -Vocab $vocab -FeedUnits $feed)
  Chk 'MUST NOT FIRE  an each->lb pair is NOT silently converted (UNIT_G has no each)' `
    ($eE.Count -eq 1 -and $eE[0].Gpu -eq '175.000' -and $eE[0].Flag -match 'NON-STANDARD') `
    (($eE | ForEach-Object { $_.Gpu + '/' + $_.Flag }) -join ' | ')

  # A NON-STANDARD unit mismatch must leave gpu alone AND flag it, exactly as the builder does.
  $fxO = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Odd Thing'; canon = 'Odd Thing'; grams = 5; buy = '1 bunch' }) } }
  $eO = @(Get-MissingBidEdits -Spec $fxO -Vocab $vocab -FeedUnits $feed)
  Chk 'MUST FIRE  a non-standard unit mismatch leaves gpu as mapped and flags it' `
    ($eO.Count -eq 1 -and $eO[0].Gpu -eq '100.000' -and $eO[0].Flag -match 'NON-STANDARD') `
    (($eO | ForEach-Object { $_.Gpu + '/' + $_.Flag }) -join ' | ')

  # ---- splice fixtures, on the real PowerShell-JSON shape (CRLF, double-space after colon) ----
  $rawFx = "{`r`n    `"scaler`":  {`r`n        `"ing`":  [`r`n                       {`r`n                           `"item`":  `"Bulgur Wheat`",`r`n                           `"canon`":  `"Bulgur Wheat`",`r`n                           `"grams`":  957,`r`n                           `"buy`":  `"6.75 cups`"`r`n                       }`r`n                   ]`r`n    }`r`n}`r`n"
  $sp = Add-BidToBlock -Raw $rawFx -Canon 'Bulgur Wheat' -Bid 'bulgur-wheat' -Gpu '28.350'
  Chk 'MUST FIRE  the splice inserts bid and gpu' ($sp.ok) $sp.why
  $ok = $false; $parsed = $null
  try { $parsed = $sp.text | ConvertFrom-Json; $ok = $true } catch { $ok = $false }
  Chk 'the spliced spec is still valid JSON' ($ok) 'parse failed'
  if ($ok) {
    Chk 'the spliced block carries the right bid and gpu' `
      ([string]$parsed.scaler.ing[0].bid -eq 'bulgur-wheat' -and [string]$parsed.scaler.ing[0].gpu -eq '28.350') `
      ([string]$parsed.scaler.ing[0].bid + '/' + [string]$parsed.scaler.ing[0].gpu)
    Chk 'the splice leaves the existing fields untouched' `
      ([string]$parsed.scaler.ing[0].buy -eq '6.75 cups' -and [int]$parsed.scaler.ing[0].grams -eq 957) `
      ([string]$parsed.scaler.ing[0].buy)
  }
  Chk 'the splice preserves CRLF line endings' `
    (($sp.text -split "`r`n").Count -eq ($rawFx -split "`r`n").Count + 2) `
    ('lines ' + ($sp.text -split "`r`n").Count + ' vs ' + ($rawFx -split "`r`n").Count)
  # The inserted lines must copy the file's own indentation AND its double-space-after-colon gap. Matched
  # against the literal CRLF rather than (?m)$, which in .NET anchors before the \n and so never sees the
  # \r - an assertion that would have passed on any indentation at all.
  Chk 'the splice preserves the file indentation style' `
    ($sp.text.Contains("`r`n" + (' ' * 27) + '"bid":  "bulgur-wheat",' + "`r`n" + (' ' * 27) + '"gpu":  "28.350"')) `
    'indent/gap not matched'

  # IDEMPOTENT. A second pass over a healed block must refuse, not double-insert.
  $sp2 = Add-BidToBlock -Raw $sp.text -Canon 'Bulgur Wheat' -Bid 'bulgur-wheat' -Gpu '28.350'
  Chk 'idempotent - an already-healed block is refused, not doubled' `
    (-not $sp2.ok -and $sp2.why -match 'already carries a bid') $sp2.why

  # AMBIGUITY REFUSES. Two blocks with the same identity must stop the spec, not pick one.
  $dupe = $rawFx -replace '(?s)(\{[^{}]*"canon":  "Bulgur Wheat"[^{}]*\})', '$1,$1'
  $sp3 = Add-BidToBlock -Raw $dupe -Canon 'Bulgur Wheat' -Bid 'bulgur-wheat' -Gpu '28.350'
  Chk 'MUST FIRE  an identity matching two blocks refuses rather than guessing' `
    (-not $sp3.ok -and $sp3.why -match 'matched 2 blocks') $sp3.why

  # A NAME NOT PRESENT refuses cleanly rather than writing nothing and claiming success.
  $sp4 = Add-BidToBlock -Raw $rawFx -Canon 'Sumac' -Bid 'ground-sumac' -Gpu '28.350'
  Chk 'MUST FIRE  a name absent from the spec refuses' (-not $sp4.ok -and $sp4.why -match 'no scaler block matched') $sp4.why

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 2 }
}

# ---- live sweep ------------------------------------------------------------------------------------
$vocabMap = @{}
foreach ($row in (Read-JsonFile (Join-Path $mp 'db\ingredients.json'))) {
  $vocabMap[[string]$row.item] = $row
  # Aliases resolve here too - the split that let one half of the pipeline see a name the other could not
  # is the exact bug cost-recipes.ps1 documents at its ALIASES block.
  if ($row.PSObject.Properties.Name -contains 'aliases') {
    foreach ($a in @($row.aliases)) { $an = [string]$a; if ($an -and -not $vocabMap.ContainsKey($an)) { $vocabMap[$an] = $row } }
  }
}
$feedUnits = @{}
$feedPath = Join-Path $repo 'grocery\out\smp-feed.json'
if (Test-Path $feedPath) {
  $fj = (Read-JsonFile $feedPath).ingredients
  if ($fj) { foreach ($p in $fj.PSObject.Properties) { if ($p.Value.unit) { $feedUnits[$p.Name] = [string]$p.Value.unit } } }
} else {
  Write-Output "  WARNING feed not found ($feedPath) - gpu reconciliation limited to the mapped unit"
}

$specFiles = Get-ChildItem (Join-Path $mp 'db\recipes\*.json')
if ($Slugs) {
  $specFiles = @($specFiles | Where-Object { $Slugs -contains $_.BaseName })
  if (-not $specFiles.Count) { Write-Output 'repair-missing-scaler-bid: no specs match -Slugs'; exit 2 }
}

$healed = 0; $rulings = 0; $refused = 0; $touchedSlugs = New-Object System.Collections.Generic.List[string]
foreach ($sf in $specFiles) {
  $raw = [IO.File]::ReadAllText($sf.FullName)
  $spec = $raw | ConvertFrom-Json
  $edits = @(Get-MissingBidEdits -Spec $spec -Vocab $vocabMap -FeedUnits $feedUnits)
  if ($edits.Count -eq 0) { continue }
  $text = $raw; $changedHere = 0
  foreach ($e in $edits) {
    if ($e.Verdict -ne 'HEAL') {
      Write-Output ("  {0,-32} {1,-16} {2}  ({3})" -f $sf.BaseName, $e.Canon, $e.Verdict, $e.Why)
      if ($e.Verdict -eq 'NO-IDENTITY') { $refused++ } else { $rulings++ }
      continue
    }
    $sp = Add-BidToBlock -Raw $text -Canon $e.Canon -Bid $e.Bid -Gpu $e.Gpu
    if (-not $sp.ok) { Write-Output ("  {0,-32} {1,-16} REFUSED  ({2})" -f $sf.BaseName, $e.Canon, $sp.why); $refused++; continue }
    if ($e.Flag) { Write-Output ('      flag ' + $e.Flag) }
    $text = $sp.text; $changedHere++
    Write-Output ("  {0,-32} {1,-16} HEAL     bid={2} gpu={3}" -f $sf.BaseName, $e.Canon, $e.Bid, $e.Gpu)
  }
  if ($changedHere -eq 0) { continue }
  # PARSE-VERIFY BEFORE WRITING. A spec this script cannot re-read is a spec it has no business saving.
  try { $null = $text | ConvertFrom-Json } catch { Write-Output ("  {0,-32} REFUSED  spliced spec no longer parses - not written" -f $sf.BaseName); $refused++; continue }
  $healed += $changedHere
  $touchedSlugs.Add($sf.BaseName)
  if ($Apply) { [IO.File]::WriteAllText($sf.FullName, $text, (New-Object Text.UTF8Encoding($false))) }
}

Write-Output ("missing scaler bid: {0} block(s) healed across {1} spec(s); {2} awaiting a ruling; {3} refused{4}" -f `
  $healed, $touchedSlugs.Count, $rulings, $refused, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
if ($Apply -and $touchedSlugs.Count) {
  ($touchedSlugs.ToArray()) -join "`n" | Set-Content (Join-Path $mp 'out\missing-scaler-bid-slugs.txt') -Encoding UTF8
  Write-Output '  slugs -> out\missing-scaler-bid-slugs.txt (recost, reanchor, rebuild + republish these cards)'
}
Write-GuardComplete -Name 'repair-missing-scaler-bid' -Summary ("healed=$healed rulings=$rulings refused=$refused")
if ($rulings -gt 0 -or $refused -gt 0) { exit 1 }
exit 0
