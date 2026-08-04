<#
  build-trend-redirects.ps1 - Emits out\trend-redirects.json, a Ghost redirects file that 301s every
  RETIRED /<id>-price-omaha/ page to the board.

  Context (2026-08-04): the trend-page set was cut from 492 to 20 (see lib\trend-keep.ps1). The other
  472 posts get unpublished, so without this file every one of them becomes a hard 404 - including the
  handful Google actually indexed (grapefruit, powdered-sugar, honeydew, lettuce, energy-drinks,
  marshmallows all appeared in site: results) and any link already sitting in a reader's browser cache
  or in the my-staples tool's client-side data.

  The redirect set is derived from price-history.json MINUS the keep-list, so it can never drift from
  what the publisher actually publishes. Upload the result in Ghost Admin under
  Settings -> Advanced -> Redirects (it replaces the whole redirect set, so this file must stay complete).
#>
param(
  [string]$HistoryFile = 'C:\Codex\income\grocery\price-history.json',
  [string]$OutFile     = 'C:\Codex\income\grocery\out\trend-redirects.json',
  [string]$Target      = '/omaha-grocery-prices/'
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here '..\lib\trend-keep.ps1')

$data = Get-Content $HistoryFile -Raw | ConvertFrom-Json
$live = @($data.commodities | ForEach-Object { [string]$_.id })

# Drift guard: a keep id that no longer exists means someone renamed a commodity and the keep-list
# was not updated. That would silently retire a page we meant to keep, so refuse to emit.
$stale = Get-TrendKeepStale -LiveIds $live
if ($stale.Count -gt 0) { throw ("trend-keep.json names {0} id(s) not in price-history.json: {1}" -f $stale.Count, ($stale -join ', ')) }

# Retired = everything that WOULD have published under the old rule but is not keep-listed.
# Mirroring the old rule (not simply "all commodities") keeps the file to URLs that really existed.
$retired = @($data.commodities |
  Where-Object { $_.src -ne 'recipe' -and @($_.history).Count -ge 3 -and -not (Test-TrendKeep $_.id) } |
  ForEach-Object { [string]$_.id } | Sort-Object)

if ($retired.Count -eq 0) { throw 'No retired trend pages found - refusing to write an empty redirect file over a good one.' }

$rules = @()
foreach ($id in $retired) {
  # Anchored, optional trailing slash, optional query string. Ghost matches on the path only.
  $rules += [ordered]@{
    from      = ('^/' + [regex]::Escape($id) + '-price-omaha/?$')
    to        = $Target
    permanent = $true
  }
}

$outDir = Split-Path $OutFile -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# PS 5.1: ConvertTo-Json collapses a 1-element array to an object; -Depth 5 keeps the rule objects intact.
$json = ConvertTo-Json -InputObject @($rules) -Depth 5
[IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))

# ALSO emit the UPLOAD-READY yaml. Ghost's redirect upload REPLACES the entire redirect set, so this file
# must contain the pre-existing rules too - redirects-base.yaml holds the 17 rules that were already live
# (rebrand tag moves + lesson consolidations), captured 2026-08-04. Emitting the merged file here means
# nobody has to hand-merge before uploading, and the base stays in version control where it can be diffed.
# Slugs are [a-z0-9-] only, so every key is a safe YAML plain scalar and needs no quoting.
$baseFile = Join-Path $here 'redirects-base.yaml'
if (-not (Test-Path $baseFile)) { throw "redirects-base.yaml missing - uploading without it would DELETE the $($Target) site's existing redirects." }
$base = ([IO.File]::ReadAllText($baseFile)) -replace "`r`n", "`n"
if (-not $base.StartsWith('301:')) { throw 'redirects-base.yaml must start with a 301: block.' }

$baseLines = @($base -split "`n" | Where-Object { $_.Trim() })
$haveKeys  = @{}
foreach ($l in $baseLines) { $haveKeys[(($l -split ':')[0]).Trim()] = $true }

$lines = @()
foreach ($id in $retired) {
  $rule = ('  ^/' + $id + '-price-omaha/?$: ' + $Target)
  $k = (($rule -split ':')[0]).Trim()
  if (-not $haveKeys.ContainsKey($k)) { $lines += $rule }   # never emit a duplicate key
}

$yamlFile = [IO.Path]::ChangeExtension($OutFile, '.yaml')
$merged = ($baseLines -join "`n") + "`n" + ($lines -join "`n") + "`n"
[IO.File]::WriteAllText($yamlFile, $merged, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("wrote {0} - UPLOAD THIS FILE: {1} base rule(s) + {2} retired = {3} lines" -f $yamlFile, ($baseLines.Count - 1), $lines.Count, @($merged -split "`n" | Where-Object { $_.Trim() }).Count)

Write-Output ("kept (still published) : {0}" -f (Get-TrendKeep).Count)
Write-Output ("retired (301 -> {0}) : {1}" -f $Target, $retired.Count)
Write-Output ("wrote {0} ({1} KB)" -f $OutFile, [math]::Round((Get-Item $OutFile).Length/1KB,1))
