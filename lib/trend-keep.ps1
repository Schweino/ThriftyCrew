<#
  trend-keep.ps1 - THE single source for "does this commodity get a standalone
  /<id>-price-omaha/ page?".

  Dot-source it, then call Test-TrendKeep / Get-TrendKeep.

  WHY THIS EXISTS: until 2026-08-04 four scripts (build-deals-page, publish-trend-pages,
  build-trend-index, build-staples-data) each carried their OWN copy of a
  ">= 3 weeks of history and src -ne 'recipe'" rule. That rule qualified 492 of 572
  commodities, so the site published 492 near-identical ~550-word pages. Google
  responded by never fetching 475 URLs ("Discovered - currently not indexed",
  Last crawled = N/A) and served the entire Omaha vertical 0 impressions in 28 days.
  The board's own history modal already draws a richer per-store chart than the
  trend pages did, so nothing of reader value depended on them.

  FAIL LOUD: a missing or empty keep file THROWS. It must never silently degrade to
  "keep everything" (that re-publishes the 492) or "keep nothing" (that unpublishes
  the survivors on the next run).
#>

$script:TCTrendKeepCache = $null

function Get-TrendKeepPath {
  $here = Split-Path -Parent $PSCommandPath
  return (Join-Path (Split-Path $here -Parent) 'grocery\trend-keep.json')
}

function Get-TrendKeep {
  <# Returns the keep-list as a string[] of commodity ids. Cached per session. #>
  param([switch]$Refresh)
  if ($script:TCTrendKeepCache -and -not $Refresh) { return $script:TCTrendKeepCache }

  $path = Get-TrendKeepPath
  if (-not (Test-Path $path)) { throw "trend-keep.json missing at $path - refusing to guess which trend pages to publish." }

  $raw = Get-Content $path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) { throw "trend-keep.json at $path is empty - refusing to guess." }

  # PS 5.1: an empty JSON array parses to $null, and a 1-element array does not unroll.
  # Wrap in @() AFTER ConvertFrom-Json, never inside the pipeline. See ps51-json-array-traps.
  $obj = $raw | ConvertFrom-Json
  $ids = @($obj.keep) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ }
  $ids = @($ids)
  if ($ids.Count -eq 0) { throw "trend-keep.json at $path has an empty 'keep' list - refusing to unpublish every trend page by accident." }

  $script:TCTrendKeepCache = $ids
  return $ids
}

function Test-TrendKeep {
  <# $true when this commodity id should have a standalone trend page. #>
  param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  return ((Get-TrendKeep) -contains $Id)
}

function Get-TrendKeepStale {
  <#
    Ids in the keep-list that no longer exist in a given set of live commodity ids.
    Callers pass their own id list so this stays free of a price-history.json dependency.
    A non-empty result means the keep-list has drifted and someone renamed a commodity.
  #>
  param([Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$LiveIds)
  $live = @{}
  foreach ($i in $LiveIds) { if ($i) { $live[[string]$i] = $true } }
  return @(Get-TrendKeep | Where-Object { -not $live.ContainsKey($_) })
}
