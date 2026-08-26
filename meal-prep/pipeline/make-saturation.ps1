# make-saturation.ps1
# ---------------------------------------------------------------------------------------------------
# Derives db\saturation.json from the catalog digest: how crowded each (protein x sauce-family) region
# already is, so sourcers stop hunting lanes the catalog has already filled.
#
# WHY. considered-dishes.ps1 remembers dishes we have ALREADY rejected. It cannot help the first time
# a crowded region is hunted - and that is where the 2026-08-15 run lost most of its front end: it
# found, fetched and adjudicated FIVE separate creamy pork-chop skillets and FOUR creamy chicken
# skillets before rejecting them all as duplicates of each other and of the catalog. 44 of 91 recipes
# (48%) died as dupes, and hunt+select cost 75.5% of the run. This file describes crowded REGIONS;
# considered-dishes remembers specific DISHES. They compose.
#
#   .\make-saturation.ps1                 rebuild from the digest
#   .\make-saturation.ps1 -Brief          the block for a sourcer prompt
#   .\make-saturation.ps1 -SelfTest
#
# GUIDANCE, NOT A FILTER. A sourcer may bring a dish from a saturated region - it just has to name the
# axis that makes it distinct. Suppressing a genuinely novel dish because its neighbourhood is busy is
# the failure mode this must avoid, so the brief says so in as many words.
# ---------------------------------------------------------------------------------------------------
param(
  [string]$DigestFile, [string]$OutFile, [int]$CrowdedAt = 8, [int]$Top = 15,
  [switch]$Brief, [switch]$Json, [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runBrief=[bool]$Brief; $runJson=[bool]$Json; $runSelfTest=[bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $DigestFile) { $DigestFile = Join-Path $here 'catalog-digest.json' }
if (-not $OutFile)    { $OutFile    = Join-Path $mp 'db\saturation.json' }

# Same family vocabulary as considered-dishes.ps1. Kept in step deliberately: if the two disagree, a
# region can read as crowded here and as a different family there, and the two signals stop composing.
$script:FAMILIES = [ordered]@{
  'cream'  = @('creamy','cream','alfredo','tuscan','marry me','asiago','parmesan cream','white sauce','bechamel')
  'tomato' = @('marinara','tomato','arrabbiata','pomodoro','bolognese','enchilada','tinga','chili')
  'soy'    = @('soy','teriyaki','bulgogi','hoisin','sesame','egg roll','stir fry','lo mein','japchae')
  'curry'  = @('curry','tikka','masala','korma','coconut curry','yellow curry','red curry','dal')
  'wine'   = @('wine','marsala','bourguignon','coq au vin','piccata','chasseur','fricassee','braised in red')
  'cheese' = @('cheddar','queso','cheese','quiche','gratin','mac and cheese','pizza')
  'bbq'    = @('bbq','barbecue','sweet and sour','honey garlic','teriyaki glaze')
  'herb'   = @('chimichurri','pesto','herb','lemon garlic','gremolata','ranch')
  'spice'  = @('taco','fajita','chipotle','adobo','barbacoa','tex-mex','cajun','blackened','harissa','berbere','sumac','tandoori')
}
function Get-Family { param([string]$Text)
  if (-not $Text) { return 'plain' }
  $t = $Text.ToLower()
  foreach ($k in $script:FAMILIES.Keys) { foreach ($n in $script:FAMILIES[$k]) { if ($t -like ('*'+$n+'*')) { return $k } } }
  return 'plain' }

# THE ONE PLACE A DIGEST ROW BECOMES A FAMILY. The derivation loop below calls this and so does the
# garnish fixture, deliberately: PLAN-recipe-hunter-v3 S2a part (d) will move the six item-DEFINED
# families (cream, tomato, soy, curry, wine, bbq) onto the row's canonical items at D12 rung 4, and
# cheese, herb and spice STAY name-only for a measured reason - their ingredient needles fire on
# garnishes. Shredded cheese on top of a beef skillet does not make it a cheese dish, and parsley at
# the end does not make it herb. With the derivation behind one function, that rung is an edit here
# and the clean twin in --selftest goes red the moment items start deciding `cheese`.
function Get-RowFamily { param($Row)
  return Get-Family ([string]$Row.name) }

if ($runSelfTest) {
  $bad=0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }
  T 'family vocabulary matches considered-dishes (cream)' ((Get-Family 'Creamy Tuscan Chicken') -eq 'cream') (Get-Family 'Creamy Tuscan Chicken')
  T 'family vocabulary matches considered-dishes (soy)' ((Get-Family 'Beef Egg Roll in a Bowl') -eq 'soy') (Get-Family 'Beef Egg Roll in a Bowl')
  T 'an unmatched name is plain, not an error' ((Get-Family 'Roast Beef') -eq 'plain') (Get-Family 'Roast Beef')
  T 'MUST FIRE  the digest exists to derive from' (Test-Path $DigestFile) $DigestFile

  # ---- THE GARNISH CLEAN TWIN (D12's named fixture) ----------------------------------------------
  # A dinner with shredded cheese on top is not a cheese dish, and the sourcer map must never file it
  # as one: `cheese` reads as a crowded region, the sourcer stops hunting a shelf that was never full,
  # and nobody finds out because saturation is guidance nobody audits. Both rows go through
  # Get-RowFamily - the same entry point the derivation uses and the same one D12 rung 4 will edit -
  # so this fixture is a live guard on that rung, not a note about it.
  $garnished = [pscustomobject]@{ slug='beef-and-rice-skillet'; name='Beef and Rice Skillet'
                                  items=@('93-7-ground-beef','rice','onions','cheddar-cheese-shredded') }
  T 'MUST FIRE  a dinner with shredded cheese in its ITEMS is not filed as a cheese dish' (
      (Get-RowFamily $garnished) -ne 'cheese') (Get-RowFamily $garnished)
  T 'CLEAN TWIN and it lands where its NAME puts it, which is plain' (
      (Get-RowFamily $garnished) -eq 'plain') (Get-RowFamily $garnished)
  $realCheese = [pscustomobject]@{ slug='chicken-broccoli-gratin'; name='Cheesy Chicken Broccoli Gratin'
                                   items=@('chicken-breast','frozen-broccoli-florets','shredded-cheese') }
  T 'CLEAN TWIN the cheese family is not dead - a dish that IS about cheese still files there, so the twin above is not passing vacuously' (
      (Get-RowFamily $realCheese) -eq 'cheese') (Get-RowFamily $realCheese)
  # the crowding threshold must actually flag the region that cost the last run
  $counts = @{ 'chicken|cream' = 14; 'lamb|curry' = 1 }
  T 'MUST FIRE  a region at/over the threshold is crowded' ($counts['chicken|cream'] -ge $CrowdedAt) ([string]$counts['chicken|cream'])
  T 'CLEAN TWIN a thin region is not crowded' ($counts['lamb|curry'] -lt $CrowdedAt) ([string]$counts['lamb|curry'])
  # MUST FIRE: `plain` regions are excluded from the brief. Found on first build 2026-08-16 - the four
  # `<protein> / plain` buckets held 91-103 recipes each and would have drowned the four regions that
  # actually carry signal (chicken/curry 15, beef/spice 12, turkey/cream 9, chicken/spice 9).
  $fake = @([pscustomobject]@{protein='beef';family='plain';count=103}, [pscustomobject]@{protein='chicken';family='curry';count=15})
  $vis = @($fake | Where-Object { $_.count -ge $CrowdedAt -and [string]$_.family -ne 'plain' })
  T 'MUST FIRE  a huge `plain` region is NOT briefed as saturated' (@($vis).Count -eq 1 -and $vis[0].family -eq 'curry') (@($vis | ForEach-Object { $_.family }) -join ',')
  if ($bad -gt 0) { Write-Output ("make-saturation SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'make-saturation SELF-TEST PASS'
  Write-GuardComplete -Name 'make-saturation' -Summary 'selftest pass'; exit 0
}

if ($runBrief -and (Test-Path $OutFile)) {
  $doc = Get-Content $OutFile -Raw -Encoding utf8 | ConvertFrom-Json
  # `plain` is excluded: it means no sauce family was detected, so "beef / plain: 103 live" says only
  # "the catalog contains beef" - true, useless, and it would drown the four regions that carry real
  # signal. Same catch-all trap that made considered-dishes report a Senegalese chicken dish as prior
  # art for a Moroccan lamb tagine. An absent signal is never evidence.
  $crowded = @($doc.regions | Where-Object { $_.count -ge $CrowdedAt -and [string]$_.family -ne 'plain' } | Sort-Object count -Descending | Select-Object -First $Top)
  if ($runJson) { ($crowded | ConvertTo-Json -Depth 4); exit 0 }
  Write-Output ("SATURATED REGIONS ({0} live recipes in the catalog). Bringing another dish from one of" -f $doc.recipe_count)
  Write-Output 'these is allowed, but you must NAME the axis that makes it distinct (cut, cuisine, method,'
  Write-Output 'starch, technique). This is guidance to argue with, not a filter - a genuinely novel dish in'
  Write-Output 'a busy neighbourhood is still worth having.'
  foreach ($r in $crowded) { Write-Output ("  {0,-22} {1,3} live   e.g. {2}" -f ($r.protein + ' / ' + $r.family), $r.count, ((@($r.examples) | Select-Object -First 3) -join ', ')) }
  exit 0
}

if (-not (Test-Path $DigestFile)) { Write-Output ("make-saturation: no digest at {0}" -f $DigestFile); exit 1 }
$digest = Get-Content $DigestFile -Raw -Encoding utf8 | ConvertFrom-Json
$regions = @{}
foreach ($p in $digest.by_protein.PSObject.Properties) {
  foreach ($r in $p.Value) {
    $fam = Get-RowFamily $r
    $key = ('{0}|{1}' -f $p.Name, $fam)
    if (-not $regions.ContainsKey($key)) { $regions[$key] = [pscustomobject]@{ protein=$p.Name; family=$fam; count=0; examples=@() } }
    $regions[$key].count++
    if (@($regions[$key].examples).Count -lt 5) { $regions[$key].examples = @($regions[$key].examples + [string]$r.slug) }
  }
}
$doc = [pscustomobject]@{
  _doc='Crowding per (protein x sauce-family), derived from the catalog digest. Fed to sourcers so they stop hunting regions the catalog has already filled - the 2026-08-15 run fetched and adjudicated five creamy pork-chop skillets and four creamy chicken skillets before rejecting them all.'
  _rule='GUIDANCE, not a filter. A dish from a saturated region is allowed if the sourcer names the distinguishing axis.'
  generated=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); recipe_count=$digest.recipe_count; crowded_at=$CrowdedAt
  regions=@($regions.Values | Sort-Object count -Descending)
}
$tmpf = $OutFile + '.tmp'
($doc | ConvertTo-Json -Depth 6) | Set-Content -Path $tmpf -Encoding utf8
Move-Item -Path $tmpf -Destination $OutFile -Force
$crowdedN = @($doc.regions | Where-Object { $_.count -ge $CrowdedAt }).Count
Write-Output ("saturation.json: {0} regions over {1} recipes, {2} crowded (>= {3}) -> {4}" -f @($doc.regions).Count, $digest.recipe_count, $crowdedN, $CrowdedAt, $OutFile)
foreach ($r in @($doc.regions | Where-Object { $_.count -ge $CrowdedAt } | Select-Object -First 8)) {
  Write-Output ("  {0,-22} {1,3} live" -f ($r.protein + ' / ' + $r.family), $r.count)
}
Write-GuardComplete -Name 'make-saturation' -Summary ("regions={0} crowded={1}" -f @($doc.regions).Count, $crowdedN)
exit 0
