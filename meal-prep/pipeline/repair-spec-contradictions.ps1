<#
  repair-spec-contradictions.ps1 - fix the self-contradictions that need no cook's judgment.

  audit-spec-contradictions.ps1 finds five classes. THREE of them are decidable from the spec alone,
  because in each case one of the two disagreeing statements is the one the ENGINE priced and the other is
  loose text nobody costs from. Those three are repaired here:

    STAT-PROSE   a calorie/protein figure in prose that is not stat's. stat is what the macro DB computed
                 and what the card's rectangle shows, so prose is the side that is wrong. Live case:
                 fajita-chicken-rice-bowl's portion paragraph says 499 calories on a 541-calorie recipe -
                 and spec-guards PASSES it, because 541 also appears in the same paragraph. "Contains the
                 right number" and "contains no wrong ones" are different questions.
    STALE-MONEY  a dollar figure in cost_closing/upsell that is not stat.cost_ps, or ANY "N cents" claim.
                 Both fields are required by spec-guards to quote the current cost exactly, so a different
                 figure there is a leftover, not a comparison. The cents claims all predate the whole-package
                 basis and cannot be re-derived, so the clause is removed rather than re-stated with a number
                 nothing computes.
    HEAD-QTY     head.recipeIngredient disagreeing with the costed display line about the same ingredient in
                 the same unit. The display line is what the cost engine and the serving scaler both read;
                 the head list is schema.org metadata. So the head list is rewritten to the costed amount.

  NOT REPAIRED HERE, and the reason is that they are not text problems:
    ABSURD-UNIT (81) and ZERO-QTY (16) are the spec generator picking a unit that renders badly - 105 tbsp
    of cilantro, "0 oz" of bay leaves. The number is right and the UNIT is wrong, which lives in the scaler
    entry's gpu (grams per displayed unit) that the serving widget re-scales from. Rewriting the printed
    string without the gpu would make the card lie the moment a reader changes the serving count. Those need
    the generator's unit picker, then a full re-cost and card rebuild.

  Every repair is reported with the before and after. Read-only unless -Apply.
  Usage: .\repair-spec-contradictions.ps1 [-Apply]   |   .\repair-spec-contradictions.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [switch]$IncludeArchive, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }

# Same matcher as audit-spec-contradictions.ps1. The HEAD-QTY decision in particular has three refusals in
# it that were each written after this repair produced a WRONG rewrite, and a second copy of that logic
# would lose them one at a time.
. (Join-Path $here 'spec-contradiction-lib.ps1')

function Repair-Spec($spec) {
  $changes = New-Object System.Collections.Generic.List[string]
  $cal = 0; $pro = 0
  [void][int]::TryParse(([string]$spec.stat.cal), [ref]$cal)
  [void][int]::TryParse(([string]$spec.stat.protein), [ref]$pro)
  $cps = [string]$spec.stat.cost_ps

  # ---- STAT-PROSE: re-anchor every macro figure in reader prose to stat.
  foreach ($k in @('intro_html','portion_html','cost_closing_html','upsell_html')) {
    $t = [string]$spec.$k; if (-not $t) { continue }
    $o = $t
    if ($cal -gt 0) { $t = [regex]::Replace($t, '(?i)\b(\d{3,4})(\s*)(cal(?:orie)?s?)\b', { param($m) if ([int]$m.Groups[1].Value -ne $cal) { "$cal" + $m.Groups[2].Value + $m.Groups[3].Value } else { $m.Value } }) }
    if ($pro -gt 0) { $t = [regex]::Replace($t, '(?i)\b(\d{1,3})(\s*)(g\b|grams?\b)(\s*(?:of\s+)?protein)', { param($m) if ([int]$m.Groups[1].Value -ne $pro) { "$pro" + $m.Groups[2].Value + $m.Groups[3].Value + $m.Groups[4].Value } else { $m.Value } }) }
    if ($t -ne $o) { $spec.$k = $t; $changes.Add("STAT-PROSE  $k re-anchored to stat (cal=$cal, protein=$pro)") }
  }
  if ($spec.head -and $spec.head.description) {
    $t = [string]$spec.head.description; $o = $t
    if ($cal -gt 0) { $t = [regex]::Replace($t, '(?i)\b(\d{3,4})(\s*)(cal(?:orie)?s?)\b', { param($m) if ([int]$m.Groups[1].Value -ne $cal) { "$cal" + $m.Groups[2].Value + $m.Groups[3].Value } else { $m.Value } }) }
    if ($pro -gt 0) { $t = [regex]::Replace($t, '(?i)\b(\d{1,3})(\s*)(g\b|grams?\b)(\s*(?:of\s+)?protein)', { param($m) if ([int]$m.Groups[1].Value -ne $pro) { "$pro" + $m.Groups[2].Value + $m.Groups[3].Value + $m.Groups[4].Value } else { $m.Value } }) }
    if ($t -ne $o) { $spec.head.description = $t; $changes.Add('STAT-PROSE  head.description re-anchored to stat') }
  }

  # ---- STALE-MONEY: the two cost fields must quote the current per-serving cost and nothing else.
  foreach ($k in @('cost_closing_html','upsell_html')) {
    $t = [string]$spec.$k; if (-not $t) { continue }
    $o = $t
    # A bare "$12" with no cents is a restaurant/takeout comparison and is left alone; a $N.NN in these two
    # fields is a per-serving claim by construction, because that is what spec-guards requires them to carry.
    $t = [regex]::Replace($t, '\$\d+\.\d{2}', ('$' + $cps))
    # A cents claim cannot be re-stated: it was a per-LINE figure under a basis the redesign removed, and
    # nothing in the spec computes its replacement. Drop the clause, keeping the sentence readable.
    $t = [regex]::Replace($t, '(?i),?\s*(?:but|and)?\s*it\s+seasons[^.]*?for\s+\d{1,3}\s*cents', '')
    $t = [regex]::Replace($t, '(?i)\s*for\s+\d{1,3}\s*cents\b', '')
    $t = [regex]::Replace($t, '\s+([.,])', '$1')
    if ($t -ne $o) { $spec.$k = $t; $changes.Add("STALE-MONEY $k re-anchored to `$$cps") }
  }

  # ---- HEAD-QTY: the head ingredient list follows the costed display line. The decision (and its three
  # refusals) is Get-HeadQtyMismatch in the shared lib; only the rewrite lives here.
  $disp = Get-DisplayQuantities $spec
  if ($spec.head -and $spec.head.recipeIngredient) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($hi in @($spec.head.recipeIngredient)) {
      $s = [string]$hi
      $mm = Get-HeadQtyMismatch $s $disp
      if ($mm) {
        $new = ([regex]::Replace($s, '^\s*[\d.]+', ('{0:0.####}' -f $mm.costed), 1))
        $changes.Add("HEAD-QTY    '$s' -> '$new' (the costed line is what the engine prices)")
        $s = $new
      }
      $out.Add($s)
    }
    $spec.head.recipeIngredient = @($out.ToArray())
  }
  return $changes
}

if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  # FROZEN FIXTURE - the four live cases, verbatim.
  $s = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 541; protein = 49; cost_ps = '3.52' }
    portion_html = '<p>One container is 499 cal and 49g protein.</p>'
    intro_html = '<p>541 calories a bowl.</p>'
    cost_closing_html = '<p>About <strong>$2.12 a bowl</strong> for a plate a restaurant charges $12 for. The fish sauce seasons this whole batch for 28 cents.</p>'
    upsell_html = '<p>$3.52 a bowl.</p>'
    head = [pscustomobject]@{ description = 'A 499 calorie bowl.'; recipeIngredient = @('5.5 cups dry rice', '2 lb ground beef') }
    ingredients_display = @('<strong>Rice (Member''s Mark):</strong> 3.75 cups dry (700 g)', '<strong>Ground Beef:</strong> 2 lb (907 g)')
  }
  $ch = @(Repair-Spec $s)
  Chk 'MUST FIRE  499 cal in portion becomes 541' ($s.portion_html -match '541 cal' -and $s.portion_html -notmatch '499') ($s.portion_html)
  Chk 'CLEAN TWIN a protein figure that already agrees is untouched' ($s.portion_html -match '49g protein') ($s.portion_html)
  Chk 'MUST FIRE  head.description 499 becomes 541' ($s.head.description -match '541') ($s.head.description)
  Chk 'MUST FIRE  cost_closing $2.12 becomes the current $3.52' ($s.cost_closing_html -match '\$3\.52 a bowl') ($s.cost_closing_html)
  Chk 'CLEAN TWIN the restaurant comparison $12 survives' ($s.cost_closing_html -match 'charges \$12 for') ($s.cost_closing_html)
  Chk 'MUST FIRE  the "28 cents" clause is dropped, not re-stated' ($s.cost_closing_html -notmatch 'cents') ($s.cost_closing_html)
  Chk 'MUST FIRE  head rice 5.5 cups becomes the costed 3.75' (@($s.head.recipeIngredient)[0] -eq '3.75 cups dry rice') (@($s.head.recipeIngredient)[0])
  Chk 'CLEAN TWIN head beef 2 lb already agrees and is untouched' (@($s.head.recipeIngredient)[1] -eq '2 lb ground beef') (@($s.head.recipeIngredient)[1])
  # THE THREE REFUSALS, each frozen from a WRONG rewrite this repair actually produced on live specs.
  $s2 = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 600; protein = 40; cost_ps = '3.00' }
    intro_html = '<p>600 calories.</p>'; portion_html = '<p>600 calories.</p>'
    cost_closing_html = '<p>$3.00 a bowl.</p>'; upsell_html = '<p>$3.00 a bowl.</p>'
    head = [pscustomobject]@{ description = 'A 600 calorie bowl.'; recipeIngredient = @(
      # (1) two quantities on one line: matching ginger then rewriting the LEADING number turned garlic's
      #     4.75 into 1.5 on korean-braised-chicken-potatoes-dakdoritang.
      '4.75 tbsp minced garlic and 1.5 tbsp grated ginger',
      # (2) the key is not the trailing ingredient: 'rice' matched inside 'rice vinegar' and would have
      #     rewritten pepper-steak-with-rice's vinegar to 3.75 CUPS.
      '0.75 cups rice vinegar',
      # (3) "wild rice" ENDS WITH "rice" but is not the plain rice this recipe costs. Accepting it rewrote
      #     turkey-spinach-artichoke-rice-casserole's head to the plain-rice amount and left the NAME wrong,
      #     trading a visible contradiction for a quieter one. Whether the dish wants wild rice is a cook's
      #     question, so the line is left exactly as it is for a person to answer.
      '5 cups wild rice',
      # (4) CLEAN TWIN for the adjective ladder: 'ground' is the first word of the INGREDIENT here, not an
      #     adjective in front of it. Stripping it blindly left "turkey", matched nothing, and silently
      #     dropped a real 3.5 lb vs 5.25 lb disagreement on turkey-chile-relleno-casserole-skillet.
      '3.5 lb 93/7 ground turkey'
    ) }
    ingredients_display = @('<strong>Rice:</strong> 3.75 cups (700 g)', '<strong>Garlic:</strong> 1.5 tbsp (12 g)', '<strong>Ginger:</strong> 1.5 tbsp (9 g)', '<strong>93/7 Ground Turkey (Jennie-O):</strong> 5.25 lb (2380 g)')
  }
  $null = Repair-Spec $s2
  Chk 'MUST NOT FIRE  a head line with TWO quantities is left alone' (@($s2.head.recipeIngredient)[0] -eq '4.75 tbsp minced garlic and 1.5 tbsp grated ginger') (@($s2.head.recipeIngredient)[0])
  Chk 'MUST NOT FIRE  "rice vinegar" is not the RICE line' (@($s2.head.recipeIngredient)[1] -eq '0.75 cups rice vinegar') (@($s2.head.recipeIngredient)[1])
  Chk 'MUST NOT FIRE  "wild rice" is not the plain RICE line' (@($s2.head.recipeIngredient)[2] -eq '5 cups wild rice') (@($s2.head.recipeIngredient)[2])
  Chk 'MUST FIRE  "93/7 ground turkey" still matches its own line (3.5 -> 5.25 lb)' (@($s2.head.recipeIngredient)[3] -eq '5.25 lb 93/7 ground turkey') (@($s2.head.recipeIngredient)[3])
  $ch2 = @(Repair-Spec $s)
  Chk 'idempotent - a second pass changes nothing' ($ch2.Count -eq 0) (($ch2 -join ' | '))
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$touched = 0; $total = 0
$slugs = New-Object System.Collections.Generic.List[string]
# THE LIVE SPEC LAYER IS db\recipes. engine\build-cards.ps1 renders from there; archive\<run>\specs\ are
# pre-consolidation snapshots that nothing builds from, and 372 of the 513 differ from their live twin.
# Repairing the archive fixes files no shopper can see - which is exactly what the first version of this
# script did. -IncludeArchive is there for anyone who wants the snapshots tidied too.
$dirs = New-Object System.Collections.Generic.List[string]
$liveDir = Join-Path $mp 'db\recipes'
if (Test-Path $liveDir) { $dirs.Add($liveDir) }
if ($IncludeArchive) {
  foreach ($d in @(Get-ChildItem (Join-Path $mp 'archive') -Directory -ErrorAction SilentlyContinue)) {
    $sd = Join-Path $d.FullName 'specs'
    if (Test-Path $sd) { $dirs.Add($sd) }
  }
}
foreach ($sd in $dirs) {
  $d = [pscustomobject]@{ Name = $(if ($sd -eq $liveDir) { 'live' } else { Split-Path (Split-Path $sd -Parent) -Leaf }) }
  foreach ($f in @(Get-ChildItem (Join-Path $sd '*.json') | Where-Object { $_.Name -notmatch '^(run-|recipes-)' -and $_.Name -ne '_index.json' })) {
    $spec = $null
    try { $spec = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not $spec.stat) { continue }
    $ch = @(Repair-Spec $spec)
    if ($ch.Count -eq 0) { continue }
    $touched++; $total += $ch.Count
    $slugs.Add($f.BaseName)
    Write-Output ("--- {0}  [{1}]" -f $f.BaseName, $d.Name)
    foreach ($c in $ch) { Write-Output ('    ' + $c) }
    if ($Apply) { $spec | ConvertTo-Json -Depth 8 | Set-Content $f.FullName -Encoding UTF8 }
  }
}
Write-Output ("repair-spec-contradictions: {0} fix(es) across {1} spec(s){2}" -f $total, $touched, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
if ($Apply -and $slugs.Count) { ($slugs.ToArray()) -join "`n" | Set-Content (Join-Path $mp 'out\contradiction-repaired-slugs.txt') -Encoding UTF8; Write-Output ('slug list -> out\contradiction-repaired-slugs.txt (rebuild + republish these cards)') }
exit 0

