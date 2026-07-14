<#
  test-pu-lib.ps1 - differential test for pu-lib.ps1.

  The new shared Get-LinkPerUnit replaces BOTH the old LinkPU (which governs published prices) and the old
  Qty (which governed the guards). Before it is wired in it must prove two things against every real cell:

    1. it NEVER disagrees with LinkPU where LinkPU produced an answer  -> no published price can change
    2. it NEVER fails where LinkPU succeeded                           -> no loss of guard coverage

  Anything it newly resolves is the blind spot being closed. Exit 1 on any regression.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')

# --- explicit assertions: pin the tricky cases regardless of what live data happens to contain ---
$cases = @(
  @{ size='6 pk 4 oz';     unit='oz';     price=2.50; name='';                  want=0.104167 }  # pack-first multipack
  @{ size='2 pk 48 fl oz'; unit='floz';   price=4.00; name='';                  want=0.041667 }  # fl oz multipack -> per fl oz
  @{ size='2 pk 1 gal';    unit='gallon'; price=6.00; name='';                  want=3.0      }  # gallon multipack
  @{ size='16 oz 6 pk';    unit='oz';     price=3.00; name='';                  want=0.03125  }  # weight-first pack (no double-multiply)
  @{ size='6 pk 16 oz';    unit='oz';     price=3.00; name='';                  want=0.03125  }  # pack-first, same product -> same answer
  @{ size='4 pk 4 oz';     unit='each';   price=2.78; name='';                  want=0.695    }  # 'each' commodity: N pk = N items, price/4 (NOT per-oz)
  @{ size='3 oz';          unit='oz';     price=2.18; name='';                  want=0.726667 }  # plain single, unchanged
  @{ size='each';          unit='each';   price=6.00; name='Water 24 Pack';     want=0.25     }  # multipack-in-name (bare-each size + count in name)
  @{ size='lb';            unit='lb';     price=4.99; name='';                  want=4.99     }  # bare unit
  @{ size='$0.07/oz';      unit='oz';     price=5.00; name='';                  want=0.07     }  # explicit unit price
  @{ size='16 oz';         unit='each';   price=2.49; name='';                  want=$null    }  # genuine unit mismatch stays null
)
$afail = 0
foreach ($c in $cases) {
  $got = Get-LinkPerUnit -size $c.size -unit $c.unit -price $c.price -name $c.name
  $ok = if ($null -eq $c.want) { $null -eq $got } else { ($null -ne $got) -and ([math]::Abs([double]$got - [double]$c.want) -lt 0.001) }
  if (-not $ok) { $afail++; Write-Output ("ASSERT FAIL  size=`"$($c.size)`" unit=$($c.unit) price=$($c.price)  want=$($c.want)  got=$got") }
}
if ($afail) { Write-Output "$afail assertion(s) failed - pu-lib math is wrong."; exit 1 }
Write-Output "explicit assertions: all $($cases.Count) passed"
Write-Output ''

# the OLD LinkPU, verbatim from audit-board-consistency.ps1 / build-deals-page.ps1
function LinkPU([string]$size, [string]$unit, [double]$price, [string]$name = '') {
  $s = ([string]$size).ToLower().Trim()
  $up = [regex]::Match($s, '\$?\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)')
  if ($up.Success) { $v=[double]$up.Groups[1].Value; $un=($up.Groups[2].Value -replace '\s','') -replace 'fl',''; switch ($unit) { 'lb'{if($un -eq 'lb'){return $v}; if($un -eq 'oz'){return $v*16}} 'oz'{if($un -eq 'oz'){return $v}; if($un -eq 'lb'){return $v/16}} 'floz'{if($un -match 'oz'){return $v}; if($un -eq 'lb'){return $v/16}} 'each'{if($un -match '^(ea|each|ct|count)$'){return $v}; return $price} 'dozen'{if($un -match '^(ea|each|ct|count)$'){return $v*12}; return $price} } }
  if ($price -le 0) { return $null }
  $q = [regex]::Match($s, '([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?|ct|count|ea|pk|gal|dozen|doz)')
  $n = if ($q.Success) { [double]$q.Groups[1].Value } else { $null }
  $un = if ($q.Success) { ($q.Groups[2].Value -replace '\s','') -replace 'fl','' } else { '' }
  if (-not $q.Success) { $bu=[regex]::Match($s,'\b(lbs?|gal|gallon|dozen|doz|each|ea)\b'); if ($bu.Success) { $n=1; $un=$bu.Groups[1].Value -replace '^gallon$','gal' -replace '^doz$','dozen' } }
  $pk = [regex]::Match($s, '([0-9]+)\s*(pk|pack)\b'); if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal)$')) { $n = $n * [double]$pk.Groups[1].Value }
  if ($unit -eq 'each' -and $name -and (($null -eq $n) -or ($n -eq 1))) {
    $pn = [regex]::Match(([string]$name).ToLower(), '([0-9]+)\s*(?:pk\b|pack\b|ct\b|count\b)')
    if ($pn.Success) { $cnt = [double]$pn.Groups[1].Value; if ($cnt -gt 1) { return $price / $cnt } }
  }
  switch ($unit) {
    'lb'    { if ($un -match '^lbs?$' -and $n) { return $price/$n }; if ($un -eq 'oz' -and $n) { return $price/($n/16) }; return $null }
    'oz'    { if ($un -eq 'oz' -and $n) { return $price/$n }; if ($un -match '^lbs?$' -and $n) { return $price/(16*$n) }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'floz'  { if ($un -match 'oz' -and $n) { return $price/$n }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'each'  { if ($un -match '^(ct|count|ea|pk)$' -and $n) { return $price/$n }; if ($un -match '^(dozen|doz)$') { return $price/12 }; if ($n -eq 1) { return $price }; return $null }
    'dozen' { if ($un -match '^(dozen|doz)$') { return $price }; if ($un -match '^(ct|count|ea)$' -and $n) { return $price/($n/12) }; if ($n -eq 1) { return $price }; return $null }
    'gallon'{ if ($un -eq 'gal' -and $n) { return $price/$n }; if ($n -eq 1) { return $price }; return $null }
    default { return $null }
  }
  return $null
}

$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$all = @((Get-Content $cmpF -Raw | ConvertFrom-Json).comparison)
$riF = Join-Path $root 'out\recipe-board.json'
if (Test-Path $riF) { $all += @((Get-Content $riF -Raw | ConvertFrom-Json).comparison) }
$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

$same=0; $newOnly=0; $oldOnly=0; $differ=0
$newList = New-Object System.Collections.Generic.List[string]
$regress = New-Object System.Collections.Generic.List[string]
foreach ($it in $all) {
  $id=[string]$it.id; $unit=[string]$it.unit
  foreach ($s in $it.stores) {
    $st=[string]$s.store
    $e = $pd.$id.$st; if (-not ($e -and $e.url)) { continue }
    $sp=0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
    $o = LinkPU ([string]$e.size) $unit $sp ([string]$e.name)
    $n = Get-LinkPerUnit -size ([string]$e.size) -unit $unit -price $sp -name ([string]$e.name)
    if (($null -eq $o) -and ($null -eq $n)) { continue }
    if (($null -eq $o) -and ($null -ne $n)) { $newOnly++; $newList.Add(('{0}/{1}  unit={2}  size="{3}"  -> {4}' -f $id,$st,$unit,([string]$e.size),[math]::Round($n,4))); continue }
    if (($null -ne $o) -and ($null -eq $n)) { $oldOnly++; $regress.Add(('LOST  {0}/{1}  unit={2}  size="{3}"  old={4}' -f $id,$st,$unit,([string]$e.size),[math]::Round($o,4))); continue }
    if ([math]::Abs([double]$o - [double]$n) -lt 0.0001) { $same++ }
    else { $differ++; $regress.Add(('DIFF  {0}/{1}  unit={2}  size="{3}"  old={4}  new={5}' -f $id,$st,$unit,([string]$e.size),[math]::Round($o,4),[math]::Round($n,4))) }
  }
}
Write-Output ("identical to the published math      : $same")
Write-Output ("newly resolvable (blind spot closed) : $newOnly")
Write-Output ("REGRESSION - old resolved, new cannot: $oldOnly")
Write-Output ("REGRESSION - different value         : $differ")
Write-Output ''
if ($newList.Count) {
  Write-Output 'sample of cells the guard could not previously judge:'
  foreach ($x in ($newList | Select-Object -First 12)) { Write-Output ('   ' + $x) }
  Write-Output ''
}
if ($regress.Count) {
  Write-Output 'REGRESSIONS:'
  foreach ($x in ($regress | Select-Object -First 25)) { Write-Output ('   ' + $x) }
  Write-Output ''
  Write-Output 'pu-lib is NOT safe to wire in.'
  exit 1
}
Write-Output 'pu-lib matches the published math everywhere it applies, and resolves strictly more. Safe to wire in.'
exit 0
