<#
  heal-degraded-sizes.ps1 - restore pack counts a shallow capture dropped (2026-07-23).

  The bug class: the browser agent's storefront pull can return an item WITHOUT its pack size
  ("Bright Essentials Paper Plates, $2.99, each") that an earlier, deeper capture had WITH it
  ("48 ct"). Same product, same shelf price, poorer metadata. The per-unit engine then computes
  $2.99 PER PLATE, the price band (correctly) rejects it as garbage, and the store silently
  vanishes from the board row - which is how Fareway lost paper plates, napkins, sandwich bags,
  bar soap and string cheese in one morning while every price was actually unchanged.

  The heal is deliberately narrow, because adopting a size across a price change could marry a
  new price to an old package:
    - same store file family, same EXACT item name, prior file inside the carry window
    - today's size is '' or 'each' AND the prior size carries a real count/measure (not 'each')
    - today's ad_price EQUALS the prior ad_price (string compare after trim) - identical shelf
      price is the evidence it is the same package
  Only then is the prior size adopted. Anything else is left alone for the band to judge.

  Run AFTER carry-forward, BEFORE compare-deals. Idempotent (healed rows no longer qualify).
#>
param(
  [ValidateSet('bakers','aldi','fareway')][string]$Store,
  # 0 = read the capture policy's carry (90). It was a hardcoded 14 until 2026-08-22, which under the
  # quarterly rotation left degraded sizes on every row 15-90 days old unhealed - and those rows are on
  # the board, priced, for the rest of their carry. The self-test passes its own number.
  [int]$MaxDays = 0,
  [string]$RegularDir = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
if (-not $MaxDays -and -not $SelfTest) {
  . (Join-Path $PSScriptRoot 'capture-policy-lib.ps1')
  $MaxDays = [int](Get-PolicyMaxCarryDays)
  if (-not $MaxDays) { throw 'heal-degraded-sizes: the capture-policy carry window could not be read' }
}
if (-not $MaxDays) { $MaxDays = 14 }   # -SelfTest runs hermetically with its own fixtures
# -Store is REQUIRED for a real run but must NOT be declared Mandatory (2026-08-08). PowerShell prompts for a
# missing mandatory parameter, so `-SelfTest` alone could never be invoked: it died with
# MissingMandatoryParameter on any non-interactive runner. This file's self-test therefore existed and had
# never once run - the "a fix needs a reachable self-test" class, found the day a change-time gate was added
# and 4 of 80 self-tests turned out to be unreachable for exactly this reason. Enforced explicitly instead.
if (-not $SelfTest -and -not $Store) { throw '-Store is required (bakers|aldi|fareway)' }
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$regDir = if ($RegularDir) { $RegularDir } else { Join-Path $root 'out\regular' }

# The store's own product id, read out of the row's link_url. A store can RENAME a product without changing
# it - "Fareway 24 Pack Purified Drinking Water" became "Fareway Purified Drinking Water" between the
# 2026-07-15 and 2026-07-31 captures, same $3.87, same product page 20544533 - and the item+price key below
# then saw two different products and refused to heal. The id in the URL is the one part of the row the
# rename does not touch, so it is the second key. It is NOT a replacement for the price guard: the price is
# what proves it is still the same PACKAGE, and that guard is unchanged.
function Get-CatalogProductId([string]$url) {
  if (-not $url) { return '' }
  # Instacart storefronts (Fareway, Aldi): /products/<digits>-<slug>
  $m = [regex]::Match($url, '/products/(\d{3,})(?:[-/?#]|$)')
  if ($m.Success) { return $m.Groups[1].Value }
  # Kroger / Baker's: /p/<slug>/<upc>
  $m = [regex]::Match($url, '/p/[^/?#]+/(\d{6,})(?:[/?#]|$)')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Invoke-SizeHeal([string]$prefix, [string]$dir, [int]$maxDays) {
  $files = @(Get-ChildItem (Join-Path $dir ($prefix + '-regular-*.json')) -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match ('^' + [regex]::Escape($prefix) + '-regular-\d{4}-\d{2}-\d{2}$') } |
    Sort-Object Name -Descending)
  if ($files.Count -lt 2) { return "size-heal [$prefix]: fewer than 2 dated captures - nothing to heal from" }
  $newF = $files[0]
  $newDate = [datetime]([regex]::Match($newF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
  $new = Read-JsonFile $newF.FullName

  # candidates: today's rows whose size carries no usable quantity, indexed by BOTH keys
  $needy = @{}      # exact item name -> row
  $needyPid = @{}   # store product id (from link_url) -> row  (survives a rename)
  foreach ($d in @($new.deals)) {
    $sz = ([string]$d.size).ToLower().Trim()
    if ($sz -eq '' -or $sz -eq 'each' -or $sz -eq 'ea') {
      $needy[([string]$d.item).Trim()] = $d
      # NB: never name this $pid - PowerShell's $PID is a read-only automatic and assignment throws.
      $prodId = Get-CatalogProductId ([string]$d.link_url)
      if ($prodId) { $needyPid[$prodId] = $d }
    }
  }
  if ($needy.Count -eq 0) { return "size-heal [$prefix]: every row already carries a size - nothing to do" }

  $healed = 0; $skippedPrice = 0; $healedByPid = 0
  foreach ($prevF in ($files | Select-Object -Skip 1)) {
    if ($needy.Count -eq 0) { break }
    $prevDate = [datetime]([regex]::Match($prevF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
    if (($newDate - $prevDate).TotalDays -gt $maxDays) { break }
    $prev = Read-JsonFile $prevF.FullName
    foreach ($p in @($prev.deals)) {
      $k = ([string]$p.item).Trim()
      $prevProdId = Get-CatalogProductId ([string]$p.link_url)
      $d = $null; $via = ''
      if ($needy.ContainsKey($k)) { $d = $needy[$k]; $via = '' }
      elseif ($prevProdId -and $needyPid.ContainsKey($prevProdId)) { $d = $needyPid[$prevProdId]; $via = (" [matched on product id $prevProdId across a rename from '" + $k + "']") }
      if (-not $d) { continue }
      $psz = ([string]$p.size).ToLower().Trim()
      if ($psz -eq '' -or $psz -eq 'each' -or $psz -eq 'ea') { continue }   # prior is no richer
      # drop this row from BOTH indexes whatever the outcome, so one prior file settles it once
      $dropKey = ([string]$d.item).Trim(); $dropProdId = Get-CatalogProductId ([string]$d.link_url)
      if (([string]$d.ad_price).Trim() -ne ([string]$p.ad_price).Trim()) {
        $skippedPrice++
        if ($needy.ContainsKey($dropKey)) { $needy.Remove($dropKey) }
        if ($dropProdId -and $needyPid.ContainsKey($dropProdId)) { $needyPid.Remove($dropProdId) }
        continue
      }
      $d.size = [string]$p.size
      $healed++; if ($via) { $healedByPid++ }
      if ($needy.ContainsKey($dropKey)) { $needy.Remove($dropKey) }
      if ($dropProdId -and $needyPid.ContainsKey($dropProdId)) { $needyPid.Remove($dropProdId) }
      Write-Output ("  healed: " + $dropKey + "  size -> [" + $p.size + "]  (price unchanged " + $d.ad_price + ", from " + $prevF.BaseName + ")" + $via)
    }
  }
  if ($healedByPid -gt 0) { Write-Output ("  ($healedByPid of them would have been missed by the item+price key alone - the store had renamed the product)") }
  if ($healed -gt 0) {
    $note = ("size-heal: {0} row(s) re-sized from prior capture(s) (same item+price, capture had dropped the pack count); {1} skipped on price change" -f $healed, $skippedPrice)
    if ($new.PSObject.Properties['size_heal_note']) { $new.size_heal_note = $note } else { $new | Add-Member -NotePropertyName size_heal_note -NotePropertyValue $note }
    $new | ConvertTo-Json -Depth 6 | Set-Content $newF.FullName -Encoding UTF8
  }
  return "size-heal [$prefix]: healed=$healed skipped-on-price-change=$skippedPrice -> $($newF.Name)"
}

if ($SelfTest) {
  $fail = 0
  $T = Join-Path $env:TEMP ('sh-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $T -Force | Out-Null
  try {
    $today = [datetime]::Today
    $d0 = $today.ToString('yyyy-MM-dd'); $d1 = $today.AddDays(-5).ToString('yyyy-MM-dd')
    # RENAME FIXTURE (2026-08-01, triage 9da3a8) - frozen from the real Fareway rows: the store renamed
    # "Fareway 24 Pack Purified Drinking Water" (2026-07-15, "24 ct", $3.87) to "Fareway Purified Drinking
    # Water" (2026-07-31, "each", $3.87) at the SAME product page 20544533. The item+price key saw two
    # products, refused the heal, and bottled-water lost its Fareway cell. 'Rename2' is its clean twin: same
    # rename, same product id, but the price moved, so the package may have changed and the heal must NOT fire.
    $puA = 'https://shop.fareway.com/store/fareway-meat-grocery/products/20544533-fareway-drinking-water-purified-24-each'
    $puB = 'https://shop.fareway.com/store/fareway-meat-grocery/products/31889021-fareway-napkins-family-pack-250-each'
    @{ store='Fareway'; price_mode='in-store'; deals=@(
      @{ store='Fareway'; item='Plates'; ad_price='$2.99'; size='48 ct' },
      @{ store='Fareway'; item='Bags';   ad_price='$2.28'; size='50 ct' },
      @{ store='Fareway'; item='Soap';   ad_price='$3.69'; size='3 ct' },
      @{ store='Fareway'; item='Fareway 24 Pack Purified Drinking Water'; ad_price='$3.87'; size='24 ct'; link_url=$puA },
      @{ store='Fareway'; item='Fareway Family Pack Napkins';             ad_price='$2.49'; size='250 ct'; link_url=$puB }
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T "fareway-regular-$d1.json") -Encoding UTF8
    @{ store='Fareway'; price_mode='in-store'; deals=@(
      @{ store='Fareway'; item='Plates'; ad_price='$2.99'; size='each' },   # same price -> heal
      @{ store='Fareway'; item='Bags';   ad_price='$1.99'; size='each' },   # price CHANGED -> do not heal
      @{ store='Fareway'; item='Soap';   ad_price='$3.69'; size='4 ct' },   # already sized -> untouched
      @{ store='Fareway'; item='Fareway Purified Drinking Water'; ad_price='$3.87'; size='each'; link_url=$puA },  # RENAMED, same price -> heal on product id
      @{ store='Fareway'; item='Fareway Napkins';                 ad_price='$1.99'; size='each'; link_url=$puB }   # RENAMED but price changed -> do NOT heal
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T "fareway-regular-$d0.json") -Encoding UTF8
    Write-Output (Invoke-SizeHeal 'fareway' $T 14)
    $out = Read-JsonFile (Join-Path $T "fareway-regular-$d0.json")
    $pl = $out.deals | Where-Object { $_.item -eq 'Plates' }
    $bg = $out.deals | Where-Object { $_.item -eq 'Bags' }
    $sp = $out.deals | Where-Object { $_.item -eq 'Soap' }
    if ($pl.size -eq '48 ct') { Write-Output 'ok    same-price row healed to prior pack size' } else { Write-Output "FAIL  plates size=$($pl.size)"; $fail++ }
    if ($bg.size -eq 'each') { Write-Output 'ok    price-changed row NOT healed (package may differ)' } else { Write-Output "FAIL  bags size=$($bg.size)"; $fail++ }
    if ($sp.size -eq '4 ct') { Write-Output 'ok    already-sized row untouched' } else { Write-Output "FAIL  soap size=$($sp.size)"; $fail++ }
    $rn = $out.deals | Where-Object { $_.item -eq 'Fareway Purified Drinking Water' }
    $rn2 = $out.deals | Where-Object { $_.item -eq 'Fareway Napkins' }
    if ($rn.size -eq '24 ct') { Write-Output 'ok    RENAMED row healed on the catalog product id (item+price alone could not)' } else { Write-Output "FAIL  renamed row size=$($rn.size) (expected 24 ct)"; $fail++ }
    if ($rn2.size -eq 'each') { Write-Output 'ok    CLEAN TWIN renamed row with a CHANGED price still not healed' } else { Write-Output "FAIL  renamed+repriced row size=$($rn2.size) (expected each)"; $fail++ }
    Write-Output (Invoke-SizeHeal 'fareway' $T 14)   # idempotency
    $out2 = Read-JsonFile (Join-Path $T "fareway-regular-$d0.json")
    if (($out2.deals | Where-Object { $_.item -eq 'Plates' }).size -eq '48 ct') { Write-Output 'ok    idempotent' } else { Write-Output 'FAIL  second run changed data'; $fail++ }
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

Write-Output (Invoke-SizeHeal $Store $regDir $MaxDays)
