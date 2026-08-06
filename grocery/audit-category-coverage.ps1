<#
  audit-category-coverage.ps1 - INVARIANT guard: every commodity in commodities.json must belong to EXACTLY ONE
  category in categories.json. A commodity with NO category is matched/priced by the engine but NEVER RENDERS on
  the board (build-deals-page walks categories -> their commodity lists), so it would be silently invisible and in
  no filter. A commodity in >1 category renders twice. Both are bugs. This also flags category entries that point
  at a commodity id that no longer exists.

  So that "add a new item" can never forget to file it into a department/filter: this is a HARD publish gate
  (exit 2 -> publish HELD) and a daily alert. The automated daily pipeline never ADDS commodities, so it only
  ever trips right after a human adds one without categorizing it - exactly when it should.

  Modes: (default) report + exit 2 if any uncategorized / multi-category / orphan-ref, else 0
         -Alert   send-alert.ps1 once per NEW issue-set (signature de-dup) - for the daily pipeline
#>
param([switch]$Alert, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$tmp = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodities.json'))); $commods = @($tmp)
$ids = @($commods | ForEach-Object { [string]$_.id })
$idset = @{}; foreach ($id in $ids) { $idset[$id] = $true }
$cats = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'categories.json')))).categories

# how many categories claim each commodity, and any category ref to a non-existent id
$catCount = @{}; foreach ($id in $ids) { $catCount[$id] = 0 }
$orphanRefs = New-Object System.Collections.Generic.List[string]
foreach ($c in $cats) {
  foreach ($cid in $c.commodities) {
    $s = [string]$cid
    if ($idset.ContainsKey($s)) { $catCount[$s]++ } else { $orphanRefs.Add($c.key + ' -> ' + $s) }
  }
}
$uncategorized = @($ids | Where-Object { $catCount[$_] -eq 0 } | Sort-Object)
$multi = @($ids | Where-Object { $catCount[$_] -gt 1 } | Sort-Object)

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); commodities = $ids.Count; categories = @($cats).Count; uncategorized = $uncategorized; multi_category = $multi; orphan_category_refs = @($orphanRefs) }
Set-Content (Join-Path $OutDir 'category-coverage-report.json') -Value ($report | ConvertTo-Json -Depth 4) -Encoding UTF8

$bad = $uncategorized.Count + $multi.Count + $orphanRefs.Count
if ($bad -eq 0) {
  Write-Output ("category-coverage: OK  all " + $ids.Count + " commodities are in exactly one of " + @($cats).Count + " categories")
  exit 0
}
Write-Output ("category-coverage: FAIL  uncategorized=" + $uncategorized.Count + "  multi-category=" + $multi.Count + "  orphan-refs=" + $orphanRefs.Count)
if ($uncategorized.Count) { Write-Output ("  NOT IN ANY CATEGORY (would be invisible / in no filter): " + ($uncategorized -join ', ')) }
if ($multi.Count) { Write-Output ("  IN MULTIPLE CATEGORIES (renders twice): " + ($multi -join ', ')) }
if ($orphanRefs.Count) { Write-Output ("  CATEGORY POINTS AT MISSING COMMODITY: " + ($orphanRefs -join ', ')) }

if ($Alert) {
  $sig = ($uncategorized -join ';') + '|' + ($multi -join ';') + '|' + (($orphanRefs) -join ';')
  $sigHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '').Substring(0, 16)
  $sigF = Join-Path $OutDir 'category-coverage-alert.sig'
  $last = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  if ($sigHash -ne $last) {
    $body = "Category coverage problem (a new commodity is not filed into a department, so it renders in NO filter):`n" +
      $(if ($uncategorized.Count) { "UNCATEGORIZED: " + ($uncategorized -join ', ') + "`n" } else { '' }) +
      $(if ($multi.Count) { "MULTI-CATEGORY: " + ($multi -join ', ') + "`n" } else { '' }) +
      $(if ($orphanRefs.Count) { "ORPHAN REFS: " + ($orphanRefs -join ', ') + "`n" } else { '' }) +
      "Fix: add each commodity id to exactly one category's commodities[] in categories.json. Publish is HELD until then."
    try { Send-Alert -Subject "Grocery: a commodity is in no category (no filter) - review" -Body $body | Out-Null; Set-Content $sigF -Value $sigHash -Encoding UTF8 } catch {}
  }
}
exit 2
