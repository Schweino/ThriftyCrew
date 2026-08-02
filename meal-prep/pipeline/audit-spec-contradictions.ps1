<#
  audit-spec-contradictions.ps1 - find recipe specs that contradict THEMSELVES.

  WHY. On 2026-07-26 five writer agents rewriting shop_smart prose kept tripping over content bugs that had
  nothing to do with their task, and wrote them up by hand in
  db\worklists\prose-data-smells-2026-07-26.md: a portion paragraph claiming 499 calories on a 541-calorie
  recipe, a head ingredient list asking for 5.5 cups of rice while the recipe costs 3.75, a chicken broth
  line that reads "0 lb", a cost sentence still quoting "28 cents" from a basis that no longer exists.
  Those were found because a human-shaped reader happened to be looking at 97 of the 513 recipes. That is
  not a detector, it is a coincidence - so this is the same reading applied to every spec, every run.

  A CONTRADICTION IS SPECIAL because it needs no outside evidence. The spec states the same fact twice and
  the two statements disagree, so one of them is wrong no matter what the source recipe says. Everything
  that DOES need outside evidence - is 308 g of garlic right for pad thai, should this dish contain
  lemongrass - is deliberately out of scope; that is a cook's judgment and it belongs in a worklist a
  person works, not in a gate.

  THE CHECKS, each one a class the writers actually hit:
    STAT-PROSE   a calorie or protein figure in intro/portion/head.description that is not stat's.
                 spec-guards already requires portion_html to CONTAIN stat.cal, which fajita passes while
                 also containing 499 - "contains the right number" and "contains no wrong ones" are
                 different questions and only the second one catches this.
    ZERO-QTY     a display or cost line that reads "0 lb" / "0 cups". A real ingredient rounded to nothing
                 by its display unit: the shopper is told to buy zero of something the recipe needs.
    STALE-MONEY  a dollar or cents figure in a NON-shop_smart prose field that is not the current
                 per-serving cost. The 2026-07-26 money strip only covered shop_smart, so cost_closing and
                 upsell still carry frozen figures from a basis that changed underneath them.
    ABSURD-UNIT  a tablespoon count over 24 (a cup and a half, in tablespoons). "105 tbsp" of cilantro is
                 arithmetically true at ~1 g/tbsp and useless to a person holding a measuring spoon.
    HEAD-QTY     the head ingredient list and the costed display line state different amounts of the same
                 ingredient in the same unit.
  ADVISORY (reported, never a failure): UNUSED - an ingredient the list buys and the steps never mention.
  It is the noisiest reading here because steps legitimately say "season" instead of naming salt, and a
  guard that cries wolf is one nobody reads.

  Ratchets against out\spec-contradictions-baseline.json so it can ship on a catalogue that already has
  findings: it fails when a CLASS gets worse, never on the standing count.

  Usage: .\audit-spec-contradictions.ps1 [-Baseline] [-Quiet] [-SelfTest]
#>
param([switch]$Baseline, [switch]$Quiet, [switch]$SelfTest, [switch]$IncludeArchive, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }

# The matcher lives in spec-contradiction-lib.ps1, shared with repair-spec-contradictions.ps1. Two copies
# would disagree the first time either was tightened, and this audit would then certify a repair it does
# not actually describe.
. (Join-Path $here 'spec-contradiction-lib.ps1')

function Get-SpecSet([string]$mpRoot, [bool]$includeArchive) {
  <#
    THE LIVE SPEC LAYER IS db\recipes, and that distinction cost a wasted pass. engine\build-cards.ps1
    renders from db\recipes\*.json; archive\<run>\specs\ are the pre-consolidation snapshots of each run and
    nothing builds from them. Reading the archive and calling the result "the catalogue" audits 513 files
    that no shopper can see - measured on 2026-08-02, 372 of the 513 archive copies differ from their live
    twin, in exactly the fields the cost-redesign writer waves rewrote.
    -IncludeArchive is available on purpose (a contradiction in a snapshot is still a fact about that run),
    but the default is the layer that ships.
  #>
  $out = New-Object System.Collections.Generic.List[object]
  $liveDir = Join-Path $mpRoot 'db\recipes'
  if (Test-Path $liveDir) {
    foreach ($f in @(Get-ChildItem (Join-Path $liveDir '*.json') | Where-Object { $_.Name -notmatch '^(run-|recipes-)' -and $_.Name -ne '_index.json' })) {
      $out.Add([pscustomobject]@{ run = 'live'; slug = $f.BaseName; path = $f.FullName })
    }
  }
  if ($includeArchive) {
    foreach ($d in @(Get-ChildItem (Join-Path $mpRoot 'archive') -Directory -ErrorAction SilentlyContinue)) {
      $sd = Join-Path $d.FullName 'specs'
      if (-not (Test-Path $sd)) { continue }
      foreach ($f in @(Get-ChildItem (Join-Path $sd '*.json') | Where-Object { $_.Name -notmatch '^(run-|recipes-)' -and $_.Name -ne '_index.json' })) {
        $out.Add([pscustomobject]@{ run = $d.Name; slug = $f.BaseName; path = $f.FullName })
      }
    }
  }
  return $out
}
if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  # FROZEN FIXTURE - every field below is copied out of a real spec named in
  # db\worklists\prose-data-smells-2026-07-26.md, so each assertion is a bug that actually shipped.
  $bad = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 541; protein = 49; cost_ps = '3.52' }
    # fajita-chicken-rice-bowl: portion says 499 on a 541-calorie recipe (and spec-guards PASSES it,
    # because 541 also appears elsewhere in the same paragraph).
    portion_html = '<p>One container is 499 cal and 49g protein. The whole batch is 541 calories a bowl.</p>'
    intro_html = '<p>541 calories a bowl.</p>'
    # filipino-pork-giniling: a cents figure from a basis that no longer exists.
    cost_closing_html = '<p>About <strong>$3.52 a bowl</strong>, and the fish sauce seasons the batch for 28 cents.</p>'
    upsell_html = '<p>$3.52 a bowl.</p>'
    head = [pscustomobject]@{ description = 'A 541 calorie bowl.'; recipeIngredient = @('5.5 cups dry rice', '2 lb ground beef') }
    # hong-kongstyle-baked-pork-chop-rice + turkey-keema-curry + greek-beef-and-chickpea
    ingredients_display = @('<strong>Chicken Broth (Swanson):</strong> 0 lb (42 g)', '<strong>Fresh Cilantro:</strong> 105 tbsp (105 g)', '<strong>Rice (Member''s Mark):</strong> 3.75 cups dry (700 g)')
    cost_lines = @('Chicken Broth, 0 lb: ~$0.06.')
    make_it = @('Weigh the pot.', 'Cook the rice.', 'Simmer with broth and cilantro.')
  }
  $r = @(Get-SpecContradictions $bad)
  $cls = @($r | ForEach-Object { $_.cls })
  Chk 'MUST FIRE  STAT-PROSE  499 cal in a paragraph that also says 541' (($cls -contains 'STAT-PROSE') -and (@($r | Where-Object { $_.why -match '499' }).Count -eq 1)) (($r | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  ZERO-QTY    a broth line that reads "0 lb"' (@($r | Where-Object { $_.cls -eq 'ZERO-QTY' }).Count -ge 1) (($r | Where-Object { $_.cls -eq 'ZERO-QTY' } | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  STALE-MONEY a "28 cents" claim in cost_closing' (@($r | Where-Object { $_.cls -eq 'STALE-MONEY' -and $_.why -match '28 cents' }).Count -eq 1) (($r | Where-Object { $_.cls -eq 'STALE-MONEY' } | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  ABSURD-UNIT 105 tbsp of cilantro' (@($r | Where-Object { $_.cls -eq 'ABSURD-UNIT' }).Count -eq 1) (($r | Where-Object { $_.cls -eq 'ABSURD-UNIT' } | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  HEAD-QTY    head 5.5 cups rice vs a costed 3.75 cups' (@($r | Where-Object { $_.cls -eq 'HEAD-QTY' }).Count -eq 1) (($r | Where-Object { $_.cls -eq 'HEAD-QTY' } | ForEach-Object { $_.why }) -join ' | ')
  # CLEAN TWIN - a spec that states each fact once and consistently must produce NOTHING but advisories.
  $good = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 620; protein = 41; cost_ps = '3.06' }
    portion_html = '<p>620 calories and 41 g of protein a container.</p>'
    intro_html = '<p>620 calories a bowl.</p>'
    cost_closing_html = '<p>About <strong>$3.06 a bowl</strong> for what a restaurant charges $14 for.</p>'
    upsell_html = '<p>$3.06 a bowl.</p>'
    head = [pscustomobject]@{ description = 'A 620 calorie bowl with 41 g protein.'; recipeIngredient = @('3.75 cups dry rice') }
    ingredients_display = @('<strong>Rice (Member''s Mark):</strong> 3.75 cups dry (700 g)', '<strong>Fresh Cilantro:</strong> 6.5 cups (105 g)')
    cost_lines = @('Rice, 3.75 cups: ~$1.20.')
    make_it = @('Weigh the pot.', 'Cook the rice.', 'Fold in the cilantro.')
  }
  $r2 = @(Get-SpecContradictions $good)
  $hard2 = @($r2 | Where-Object { $_.cls -ne 'UNUSED' })
  Chk 'CLEAN TWIN a self-consistent spec produces no findings' ($hard2.Count -eq 0) (($hard2 | ForEach-Object { $_.cls + ': ' + $_.why }) -join ' | ')
  Chk 'CLEAN TWIN a comparison price ($14 a restaurant charges) is not stale money' (@($r2 | Where-Object { $_.why -match '14' }).Count -eq 0) (($r2 | ForEach-Object { $_.why }) -join ' | ')
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$specs = Get-SpecSet $mp ([bool]$IncludeArchive)
$byClass = @{}
$rows = New-Object System.Collections.Generic.List[object]
foreach ($s in $specs) {
  $spec = $null
  try { $spec = Get-Content $s.path -Raw | ConvertFrom-Json } catch { continue }
  if (-not $spec.stat) { continue }
  foreach ($f in (Get-SpecContradictions $spec)) {
    $byClass[$f.cls] = 1 + [int]$byClass[$f.cls]
    $rows.Add([pscustomobject]@{ run = $s.run; slug = $s.slug; cls = $f.cls; why = $f.why })
  }
}
$outPath = Join-Path $mp 'out\spec-contradictions.json'
New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
@{ generated = 'see git'; specs = $specs.Count; by_class = $byClass; findings = @($rows.ToArray()) } | ConvertTo-Json -Depth 5 | Set-Content $outPath -Encoding UTF8

if (-not $Quiet) {
  Write-Output ("spec contradictions: {0} finding(s) across {1} spec(s)" -f $rows.Count, $specs.Count)
  foreach ($k in ($byClass.Keys | Sort-Object)) { Write-Output ("  {0,-12} {1}" -f $k, $byClass[$k]) }
  foreach ($k in @('STAT-PROSE','ZERO-QTY','STALE-MONEY','ABSURD-UNIT','HEAD-QTY')) {
    $r = @($rows | Where-Object { $_.cls -eq $k })
    if ($r.Count -eq 0) { continue }
    Write-Output ("  --- $k")
    foreach ($x in ($r | Select-Object -First 12)) { Write-Output ("      {0,-46} {1}" -f $x.slug, $x.why) }
    if ($r.Count -gt 12) { Write-Output ("      ... and " + ($r.Count - 12) + " more (full list in out\spec-contradictions.json)") }
  }
}

$basePath = Join-Path $mp 'out\spec-contradictions-baseline.json'
if ($Baseline) {
  $nb = [ordered]@{}
  foreach ($k in ($byClass.Keys | Sort-Object)) { $nb[$k] = [int]$byClass[$k] }
  $nb | ConvertTo-Json -Depth 3 | Set-Content $basePath -Encoding UTF8
  Write-Output ('baseline written: ' + (($byClass.Keys | Sort-Object | ForEach-Object { "$_=$($byClass[$_])" }) -join ' '))
  exit 0
}
$base = @{}
if (Test-Path $basePath) { try { $bd = Get-Content $basePath -Raw | ConvertFrom-Json; foreach ($p in $bd.PSObject.Properties) { $base[$p.Name] = [int]$p.Value } } catch {} }
$worse = @()
foreach ($k in @('STAT-PROSE','ZERO-QTY','STALE-MONEY','ABSURD-UNIT','HEAD-QTY')) {
  $now = [int]$byClass[$k]
  $was = if ($base.ContainsKey($k)) { [int]$base[$k] } else { 0 }
  if ($now -gt $was) { $worse += ("{0}: {1} now, baseline {2}" -f $k, $now, $was) }
}
if ($worse.Count -gt 0) {
  Write-Output ('spec-contradictions FAIL - a class got WORSE than out\spec-contradictions-baseline.json: ' + ($worse -join ' | '))
  Write-Output '  A spec that states the same fact twice and disagrees with itself is wrong no matter what the source recipe says - one of the two numbers is on a live card.'
  exit 1
}
exit 0


