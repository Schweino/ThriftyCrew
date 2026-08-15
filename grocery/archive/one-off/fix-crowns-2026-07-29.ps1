<#
  fix-crowns.ps1 - the three remaining wrong crowns from AUDIT-2026-07-29, by targeted text edit.

  1. air-freshener  <- 'Febreze Extra Strength and Downy FABRIC Spray, 50.6 fl oz, Pack of 2'
     The include is the bare brand token "febreze", so anything Febreze sells lands on an aerosol
     air-freshener row. Require a product noun alongside the brand and exclude the fabric line.
     This is the same rule shape (brand-only include, no product noun) that let fabric conditioner
     onto the hair-conditioner row.

  2. gochujang      <- 'Kikkoman Gochujang Spicy Miso TERIYAKI Sauce'
     Root cause is structural and NOT on the gochujang row: `\bsauce\b` is in GLOBAL_EXCLUDE and
     teriyaki-sauce has no relax_global, so a row labelled "Teriyaki Sauce / Marinade" cannot match
     a product named "... Teriyaki Sauce". Four teriyaki items were misrouted this week, including
     the true cheapest of the bbq-sauce row. Fix the teriyaki row so those products can go home,
     and exclude teriyaki from gochujang so a flavour word cannot win a chili-paste row.

  3. broccoli       <- "Member's Mark Broccoli Normandy 4 lbs."
     A frozen broccoli/cauliflower/carrot blend, dropped by the verify pass in THREE separate weeks
     and still banked as the 16-week record low. not-carried.json hides it from the page but it is
     still in comparison/verified and still setting the record.

  Every change is proved against the real 91,889-name product universe before anything is written:
  the intruder must die, and a named legitimate product must survive.
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$path = 'C:\Codex\ThriftyCrew\grocery\commodities.json'

# --- proofs, run against the live feeds -------------------------------------------------------
$names = New-Object System.Collections.Generic.List[string]
foreach ($f in (Get-ChildItem 'C:\Codex\ThriftyCrew\grocery\out\regular\*-regular-2026-07-*.json','C:\Codex\ThriftyCrew\grocery\out\sams\sams-deals-2026-07-29.json' -ErrorAction SilentlyContinue)) {
  try { $d = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
  foreach ($r in $d.deals) { if ($r.item) { $names.Add([string]$r.item) } }
}
Write-Output ("product universe: {0} names" -f $names.Count)

function Show([string]$label, [string]$pat) {
  # Write-HOST, not Write-Output. A function that returns data must emit nothing else on the output stream:
  # the first draft logged with Write-Output, so the label line "fabric spray/refresher (exclude)" landed IN
  # the returned array and the gate below read it as a real air-freshener product name and failed. Same trap
  # capture-lib.ps1 documents from this morning.
  $hits = @($names | Where-Object { $_ -imatch $pat } | Select-Object -Unique)
  Write-Host ("  {0,-34} {1,-32} hits={2}" -f $label, $pat, $hits.Count)
  foreach ($h in ($hits | Select-Object -First 5)) { Write-Host ("        {0}" -f $h) }
  return $hits
}

Write-Output ''
Write-Output 'AIR-FRESHENER: new include must keep real air fresheners, drop the fabric spray'
$keepAF = Show 'febreze air/small spaces/plug' 'febreze\s*(?:air|small\s+spaces|plug|fabric\s+refresher\s+air)'
$killAF = Show 'fabric spray/refresher (exclude)' '\bfabric\s+(?:spray|refresher)\b'
Write-Output ''
Write-Output 'GOCHUJANG / TERIYAKI'
$teri = Show 'teriyaki products in the feed' '\bteriyaki\b'
Write-Output ''
Write-Output 'BROCCOLI'
$norm = Show 'normandy blend (exclude)' '\bnormandy\b'

# hard gates
$bad = 0
# The exclude may legitimately hit a product whose marketing copy says "air freshener" - Febreze sells a
# "Fabric Spray Air Freshener". What must NOT happen is killing a product that is not a fabric product at all.
# So the gate is: every casualty must itself say "fabric".
$notFabric = @($killAF | Where-Object { $_ -inotmatch '\bfabric\b' })
if ($notFabric.Count -gt 0) { Write-Output ('FAIL: the fabric exclude hits a non-fabric product: ' + ($notFabric -join ' ; ')); $bad++ }
if ($norm.Count -eq 0) { Write-Output 'FAIL: \bnormandy\b matches nothing - wrong pattern'; $bad++ }
if ((@($norm | Where-Object { $_ -inotmatch 'normandy' })).Count -gt 0) { Write-Output 'FAIL: normandy over-matches'; $bad++ }
if ($teri.Count -eq 0) { Write-Output 'FAIL: no teriyaki products found - cannot verify the reroute'; $bad++ }
if ($bad) { Write-Output "$bad proof(s) FAILED - writing nothing."; exit 1 }
Write-Output ''
Write-Output 'all proofs pass'
if (-not $Apply) { Write-Output 'DRY RUN - pass -Apply to write.'; exit 0 }

# --- edits ------------------------------------------------------------------------------------
$text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
$orig = $text

# 1. air-freshener: swap the bare brand include for a brand+product-noun form.
# LINE-SCOPED, not a whole-block or global replace: apply-category-excludes bakes the household class - which
# itself contains "febreze" - into ~445 commodities' EXCLUDE lists, so a global replace of the token would
# rewrite hundreds of unrelated rules. Only the one include line inside the air-freshener block may change.
$ls = @($text -split "`r?`n")
$afStart = -1
for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i] -match '^\s*"id":\s*"air-freshener",\s*$') { $afStart = $i; break } }
if ($afStart -lt 0) { throw 'air-freshener commodity not found' }
$incIdx = -1
for ($j = $afStart; $j -lt [Math]::Min($afStart + 40, $ls.Count); $j++) {
  if ($ls[$j] -match '^\s*"febreze",\s*$') { $incIdx = $j; break }
  if ($ls[$j] -match '^\s*"exclude":') { break }   # never cross into the exclude array
}
if ($incIdx -lt 0) { throw 'bare "febreze" include not found inside air-freshener - refusing to guess' }
$ls[$incIdx] = '                        "febreze\\s*(?:air|small\\s+spaces|plug)",'
$text = [string]::Join("`r`n", $ls)
Write-Output ('  ~ air-freshener include: bare "febreze" -> brand + product noun (line ' + ($incIdx + 1) + ')')

# 2a. teriyaki-sauce: let it match its own name past GLOBAL_EXCLUDE's \bsauce\b
# LINE-SCOPED for the same reason the air-freshener edit is: a here-string in this script carries LF newlines
# while commodities.json is CRLF, so a verbatim block compare can never match. Insert relax_global immediately
# before the include array of the teriyaki-sauce row.
$ls2 = @($text -split "`r?`n")
$tStart = -1
for ($i = 0; $i -lt $ls2.Count; $i++) { if ($ls2[$i] -match '^\s*"id":\s*"teriyaki-sauce",\s*$') { $tStart = $i; break } }
if ($tStart -lt 0) { throw 'teriyaki-sauce commodity not found' }
$tInc = -1
for ($j = $tStart; $j -lt [Math]::Min($tStart + 20, $ls2.Count); $j++) {
  if ($ls2[$j] -match '^\s*"relax_global":') { throw 'teriyaki-sauce already has relax_global - review by hand' }
  if ($ls2[$j] -match '^\s*"include":\s*\[\s*$') { $tInc = $j; break }
}
if ($tInc -lt 0) { throw 'teriyaki-sauce include array not found' }
$tl = New-Object System.Collections.Generic.List[string]
$tl.AddRange([string[]]$ls2)
$tl.InsertRange($tInc, [string[]]@(
  '        "relax_global":  [',
  '                             "\\bsauce\\b"',
  '                         ],'
))
$text = [string]::Join("`r`n", $tl.ToArray())
Write-Output '  + teriyaki-sauce: relax_global ["\bsauce\b"] so the row can match its own product name'

# 2b + 3. one exclude each on gochujang and broccoli, inserted at the head of their exclude array
$lines = @($text -split "`r?`n")
function Get-ExcludeIdx([string[]]$L, [string]$id) {
  for ($i = 0; $i -lt $L.Count; $i++) {
    if ($L[$i] -match ('^\s*"id":\s*"' + [regex]::Escape($id) + '",\s*$')) {
      for ($j = $i; $j -lt [Math]::Min($i + 40, $L.Count); $j++) { if ($L[$j] -match '^\s*"exclude":\s*\[\s*$') { return $j } }
      throw "no exclude array for $id"
    }
  }
  throw "commodity not found: $id"
}
$plan = @(
  [pscustomobject]@{ id = 'gochujang';     pats = @('\\bteriyaki\\b'); idx = 0 },
  [pscustomobject]@{ id = 'broccoli';      pats = @('\\bnormandy\\b'); idx = 0 },
  [pscustomobject]@{ id = 'air-freshener'; pats = @('\\bfabric\\s+(?:spray|refresher)\\b'); idx = 0 }
)
foreach ($p in $plan) { $p.idx = Get-ExcludeIdx $lines $p.id }
$out = New-Object System.Collections.Generic.List[string]
$out.AddRange([string[]]$lines)
foreach ($p in ($plan | Sort-Object idx -Descending)) {
  $ins = @($p.pats | ForEach-Object { '                        "' + $_ + '",' })
  $out.InsertRange($p.idx + 1, [string[]]$ins)
  Write-Output ("  + {0}: {1}" -f $p.id, ($p.pats -join ', '))
}
$final = [string]::Join("`r`n", $out.ToArray())
$null = $final | ConvertFrom-Json      # parse gate
[IO.File]::WriteAllText($path, $final, (New-Object Text.UTF8Encoding($true)))
Write-Output 'commodities.json written and re-parsed clean.'
