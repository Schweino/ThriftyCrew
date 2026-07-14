<#
  audit-price-mode.ps1 - "never again" guard for the Aldi delivery-price bug (2026-07-14).

  THE BUG THIS PREVENTS
  ---------------------
  Aldi (and Fareway) run Instacart-powered storefronts that serve a DIFFERENT PRICE
  per fulfillment mode (Delivery / Pickup / In-Store). A cold session defaults to
  Delivery, which is marked up ~10%. We shipped 249 Aldi rows pulled in Delivery
  mode while the file's free-text `source` string *claimed* in-store. Nothing caught
  it, because the numbers were internally consistent and matched their source page.

  Free-text prose in `source` is NOT a guarantee. This guard demands a MACHINE-CHECKABLE
  field and fails the build if it is missing or wrong.

  CONTRACT
  --------
  Every out\regular\<store>-regular-<date>.json MUST declare:
      price_mode    : 'in-store'   (the shelf price a shopper actually pays)
      mode_verified : 'YYYY-MM-DD' (when a human/script confirmed the session mode)
  Stores whose storefront exposes a fulfillment toggle (Aldi, Fareway) are STRICT:
  a missing or non-'in-store' price_mode is a hard FAIL (exit 2).

  Exit codes: 0 = clean, 2 = a store is shipping non-shelf prices.
#>
param([string]$RegularDir = '')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $RegularDir) { $RegularDir = Join-Path $root 'out\regular' }

# Storefronts that serve different prices per fulfillment mode. These are the dangerous ones.
$MODE_SENSITIVE = @('Aldi', 'Fareway')

$fail = @(); $warn = @(); $ok = @()

# newest file per store
$files = Get-ChildItem (Join-Path $RegularDir '*.json') |
  Group-Object { ($_.BaseName -replace '-regular-.*$','') } |
  ForEach-Object { $_.Group | Sort-Object Name -Descending | Select-Object -First 1 }

foreach ($f in $files) {
  $d = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $store = [string]$d.store
  $mode  = [string]$d.price_mode
  $ver   = [string]$d.mode_verified

  if ($MODE_SENSITIVE -contains $store) {
    if ($mode -ne 'in-store') {
      $fail += ("{0}: price_mode='{1}' (expected 'in-store'). {2} is an Instacart storefront whose delivery catalog is MARKED UP. File: {3}" -f $store, $(if($mode){$mode}else{'<missing>'}), $store, $f.Name)
    } elseif (-not $ver) {
      $fail += ("{0}: price_mode='in-store' but mode_verified is missing. Prove when the session mode was confirmed. File: {1}" -f $store, $f.Name)
    } else {
      $ok += ("{0}: in-store (verified {1})" -f $store, $ver)
    }
  } else {
    if ($mode -ne 'in-store') {
      $warn += ("{0}: price_mode='{1}' - not mode-sensitive, but please stamp it." -f $store, $(if($mode){$mode}else{'<missing>'}))
    } else {
      $ok += ("{0}: in-store (verified {1})" -f $store, $(if($ver){$ver}else{'-'}))
    }
  }
}

foreach ($o in $ok)   { Write-Output ("  OK    " + $o) }
foreach ($w in $warn) { Write-Output ("  WARN  " + $w) }
foreach ($x in $fail) { Write-Output ("  FAIL  " + $x) }

if ($fail.Count -gt 0) {
  Write-Output ""
  Write-Output ("PRICE-MODE AUDIT FAILED: {0} store(s) are shipping non-shelf prices. Board NOT safe to publish." -f $fail.Count)
  exit 2
}
Write-Output ""
Write-Output "PRICE-MODE AUDIT OK: every mode-sensitive store is pinned to the in-store shelf price."
