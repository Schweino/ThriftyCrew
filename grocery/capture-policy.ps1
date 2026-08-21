<#
  capture-policy.ps1 - the ONE place that answers "what should we capture from this store today?"

  THE POLICY (Brad, 2026-08-20), and it is the same for all seven stores:

    1. AD ROLLOVER    the store's current ad expired and a new one is up -> pull its ad.
    2. SALE EXPIRY    an item's temporary sale ended -> re-price that item, because the
                      shelf price reverts the day after sale_end and the board would
                      otherwise keep publishing the sale price.
    3. QUARTERLY BASE everything else rotates: total terms / 90 days, that many per day.

  1 and 2 are EVENTS - they fire once or twice a week, not daily. 3 is the daily drip.

  THIS FILE IS THE CLI. The functions live in capture-policy-lib.ps1, which declares no
  parameters so it can be dot-sourced without resetting its caller's variables - see that
  file's header for the bug that forced the split on 2026-08-21. If you are writing a script
  that needs Get-CapturePlan or Get-CaptureWorklist, dot-source THE LIB, not this.

  Usage:
      capture-policy.ps1 -Report            # human-readable, all seven stores
      capture-policy.ps1 -Emit              # write today's worklist for every store
      capture-policy.ps1 -Store 'Aldi'
#>
param([switch]$Report, [switch]$Emit, [string]$Store = '', [string]$Today = '', [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$script:PolicyRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $script:PolicyRoot 'capture-policy-lib.ps1')
$script:AllStores = @('Hy-Vee', 'Aldi', "Baker's", 'Family Fare', 'Fareway', 'Walmart', "Sam's Club")

if ($Emit) {
  # Emit today's worklist for every store. The three walled stores (Walmart, Sam's,
  # Fareway) have no other way to be told what to fetch - their capture happens in a
  # real logged-in Chrome, so a file is the only handoff that works.
  foreach ($s in $script:AllStores) {
    $f = Write-CaptureWorklist -Store $s -Today $Today -OutDir $OutDir
    $wl = Get-CaptureWorklist -Store $s -Today $Today -OutDir $OutDir
    Write-Output ("{0,-13} {1,3} term(s)  ad_rollover={2,-5}  -> {3}" -f $s, @($wl.Terms).Count, $wl.AdRollover, (Split-Path $f -Leaf))
  }
  return
}

if ($Report -or $Store) {
  $stores = if ($Store) { @($Store) } else { $script:AllStores }
  Write-Output ("capture policy: quarter=$script:QuarterDays d, max-carry=$script:MaxCarryDays d")
  Write-Output ''
  foreach ($s in $stores) {
    $p = Get-CapturePlan -Store $s -Today $Today
    Write-Output ("{0,-13} rotation {1,3} term(s)/day  + {2,2} sale expiry  = budget {3,3}   ad: {4}" -f `
        $p.Store, $p.RotationTerms, $p.SaleExpiries.Count, $p.TermBudget, $p.AdNote)
    if ($p.SaleExpiries.Count) {
      Write-Output ("               sales reverting today: " + (($p.SaleExpiries | Select-Object -First 8) -join ', '))
    }
  }
}


