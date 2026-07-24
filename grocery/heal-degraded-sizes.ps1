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
  [Parameter(Mandatory=$true)][ValidateSet('bakers','aldi','fareway')][string]$Store,
  [int]$MaxDays = 14,
  [string]$RegularDir = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$regDir = if ($RegularDir) { $RegularDir } else { Join-Path $root 'out\regular' }

function Invoke-SizeHeal([string]$prefix, [string]$dir, [int]$maxDays) {
  $files = @(Get-ChildItem (Join-Path $dir ($prefix + '-regular-*.json')) -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match ('^' + [regex]::Escape($prefix) + '-regular-\d{4}-\d{2}-\d{2}$') } |
    Sort-Object Name -Descending)
  if ($files.Count -lt 2) { return "size-heal [$prefix]: fewer than 2 dated captures - nothing to heal from" }
  $newF = $files[0]
  $newDate = [datetime]([regex]::Match($newF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
  $new = Get-Content $newF.FullName -Raw | ConvertFrom-Json

  # candidates: today's rows whose size carries no usable quantity
  $needy = @{}
  foreach ($d in @($new.deals)) {
    $sz = ([string]$d.size).ToLower().Trim()
    if ($sz -eq '' -or $sz -eq 'each' -or $sz -eq 'ea') { $needy[([string]$d.item).Trim()] = $d }
  }
  if ($needy.Count -eq 0) { return "size-heal [$prefix]: every row already carries a size - nothing to do" }

  $healed = 0; $skippedPrice = 0
  foreach ($prevF in ($files | Select-Object -Skip 1)) {
    if ($needy.Count -eq 0) { break }
    $prevDate = [datetime]([regex]::Match($prevF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
    if (($newDate - $prevDate).TotalDays -gt $maxDays) { break }
    $prev = Get-Content $prevF.FullName -Raw | ConvertFrom-Json
    foreach ($p in @($prev.deals)) {
      $k = ([string]$p.item).Trim()
      if (-not $needy.ContainsKey($k)) { continue }
      $psz = ([string]$p.size).ToLower().Trim()
      if ($psz -eq '' -or $psz -eq 'each' -or $psz -eq 'ea') { continue }   # prior is no richer
      $d = $needy[$k]
      if (([string]$d.ad_price).Trim() -ne ([string]$p.ad_price).Trim()) { $skippedPrice++; $needy.Remove($k); continue }
      $d.size = [string]$p.size
      $healed++; $needy.Remove($k)
      Write-Output ("  healed: " + $k + "  size -> [" + $p.size + "]  (price unchanged " + $d.ad_price + ", from " + $prevF.BaseName + ")")
    }
  }
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
    @{ store='Fareway'; price_mode='in-store'; deals=@(
      @{ store='Fareway'; item='Plates'; ad_price='$2.99'; size='48 ct' },
      @{ store='Fareway'; item='Bags';   ad_price='$2.28'; size='50 ct' },
      @{ store='Fareway'; item='Soap';   ad_price='$3.69'; size='3 ct' }
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T "fareway-regular-$d1.json") -Encoding UTF8
    @{ store='Fareway'; price_mode='in-store'; deals=@(
      @{ store='Fareway'; item='Plates'; ad_price='$2.99'; size='each' },   # same price -> heal
      @{ store='Fareway'; item='Bags';   ad_price='$1.99'; size='each' },   # price CHANGED -> do not heal
      @{ store='Fareway'; item='Soap';   ad_price='$3.69'; size='4 ct' }    # already sized -> untouched
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T "fareway-regular-$d0.json") -Encoding UTF8
    Write-Output (Invoke-SizeHeal 'fareway' $T 14)
    $out = Get-Content (Join-Path $T "fareway-regular-$d0.json") -Raw | ConvertFrom-Json
    $pl = $out.deals | Where-Object { $_.item -eq 'Plates' }
    $bg = $out.deals | Where-Object { $_.item -eq 'Bags' }
    $sp = $out.deals | Where-Object { $_.item -eq 'Soap' }
    if ($pl.size -eq '48 ct') { Write-Output 'ok    same-price row healed to prior pack size' } else { Write-Output "FAIL  plates size=$($pl.size)"; $fail++ }
    if ($bg.size -eq 'each') { Write-Output 'ok    price-changed row NOT healed (package may differ)' } else { Write-Output "FAIL  bags size=$($bg.size)"; $fail++ }
    if ($sp.size -eq '4 ct') { Write-Output 'ok    already-sized row untouched' } else { Write-Output "FAIL  soap size=$($sp.size)"; $fail++ }
    Write-Output (Invoke-SizeHeal 'fareway' $T 14)   # idempotency
    $out2 = Get-Content (Join-Path $T "fareway-regular-$d0.json") -Raw | ConvertFrom-Json
    if (($out2.deals | Where-Object { $_.item -eq 'Plates' }).size -eq '48 ct') { Write-Output 'ok    idempotent' } else { Write-Output 'FAIL  second run changed data'; $fail++ }
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

Write-Output (Invoke-SizeHeal $Store $regDir $MaxDays)
