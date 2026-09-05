<#
  recover-sams-quarantine.ps1 - convert a quarantined UNIT-PRICE Sam's capture into the engine's
  package-price shape (README option 2 in out\sams\quarantine\README.md) and emit it back into
  out\sams\ so compare-deals can read it.

  THE PROBLEM (why the 2026-07-15 capture was quarantined): its rows carry the price PER UNIT in
  ad_price with a bare unit in size ("$1.09" + size:"each"). For weight/volume units the engine
  reads that correctly by luck (size "oz" -> amount 1). For unit 'each' it does NOT: Get-UnitPrice
  falls through to Get-PackCount on the product NAME and divides, so "Cucumbers, 3 ct." at $1.09
  per each became $0.3633.

  THE CONVERSION (must exactly invert the engine's read):
    - oz / lb / fl oz / dozen rows: PASS THROUGH unchanged (ad_price already means "price of one
      size-unit", which is the engine's own rule: ad_price = price of ONE `size`).
    - each rows: N = Get-PackCount(name) - the SAME function compare-deals uses, lifted verbatim,
      so the multiply is guaranteed to invert the engine's divide.
        N found:  ad_price = round(U x N, 2), size = "N ct"   (true package price + pack size;
                  the engine reads the count from SIZE first, so the name is never consulted)
        no N:     size = "1 ct" ... BUT ONLY when the name truly has no count. If we emitted
                  "1 ct" for a row whose name says "18 ct.", Get-PackCount("1 ct") returns null
                  (count must be >1) and the engine would fall through to the NAME and divide a
                  per-each price by 18. Get-PackCount(name) being null is exactly the guarantee
                  that fallback can never fire.

  INVARIANT (same idea as build-sams-deals.ps1): every emitted 'each' row is re-read through the
  lifted engine logic and must yield the original per-unit price within a cent (package rounding).
  A failing row is written to <out>.rejects.json, never published.

  Usage: .\recover-sams-quarantine.ps1            (defaults to the 2026-07-15 quarantine file)
         -In <path> -Out <path>
#>
param(
  [string]$In  = "",
  [string]$Out = ""
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $In)  { $In  = Join-Path $root 'out\sams\quarantine\sams-deals-2026-07-15.json' }
if (-not $Out) { $Out = Join-Path $root ('out\sams\' + [IO.Path]::GetFileName($In)) }

# ---- Get-PackCount lifted VERBATIM from compare-deals.ps1 (the divide we are inverting) ----
function Get-PackCount($text) {
  if (-not $text) { return $null }
  $t = ("" + $text).ToLower()
  $m = [regex]::Match($t, '(?:per\s*)?(\d+)\s*[- ]?\s*(?:pack|pk|count|ct|each|ea)\b')
  if ($m.Success) { $n = [int]$m.Groups[1].Value; if ($n -gt 1) { return $n } }
  return $null
}

$doc = Read-JsonFile $In
$outRows = New-Object System.Collections.Generic.List[object]
$rejects = New-Object System.Collections.Generic.List[object]
$passThru = 0; $packed = 0; $single = 0

foreach ($r in $doc.deals) {
  $sz = ([string]$r.size).Trim().ToLower()
  if ($sz -in @('oz','lb','fl oz','floz','dozen','gallon')) { $outRows.Add($r); $passThru++; continue }
  if ($sz -ne 'each' -and $sz -ne 'ea') {
    $rejects.Add([pscustomobject]@{ reason = "unexpected size '$($r.size)' (not a bare unit this converter knows)"; row = $r })
    continue
  }
  # each row: U = per-each price
  $U = 0.0
  if (-not [double]::TryParse((([string]$r.ad_price) -replace '[^0-9.]',''), [ref]$U) -or $U -le 0) {
    $rejects.Add([pscustomobject]@{ reason = "unparseable ad_price '$($r.ad_price)'"; row = $r }); continue
  }
  $N = Get-PackCount ([string]$r.item)
  $new = $r | Select-Object *   # shallow copy
  if ($N) {
    $new.ad_price = ('${0:0.00}' -f [math]::Round($U * $N, 2))
    $new.size     = ('{0} ct' -f $N)
    # invariant: engine reads count from SIZE first -> ad_price/N must round-trip to U
    $chk = [double](($new.ad_price -replace '[^0-9.]','')) / [double](Get-PackCount $new.size)
    if ([math]::Abs($chk - $U) -gt 0.011) {
      $rejects.Add([pscustomobject]@{ reason = ('round-trip drift: engine would read {0:0.0000}, capture said {1:0.0000}' -f $chk, $U); row = $r })
      continue
    }
    $outRows.Add($new); $packed++
  } else {
    # no count anywhere in the name -> engine's name fallback CANNOT fire; "1 ct" hits the
    # explicit per-each branch (size matches '^(1 )?(ct|count|ea|each)$')
    $new.size = '1 ct'
    $outRows.Add($new); $single++
  }
}

$outDoc = [ordered]@{
  store      = $doc.store
  week_of    = $doc.week_of
  price_type = $doc.price_type
  source     = ([string]$doc.source + ' | recovered from quarantine by recover-sams-quarantine.ps1 (unit-price rows converted to package shape per quarantine README)')
  deals      = $outRows.ToArray()   # NOT @($outRows): PS5.1 throws 'Argument types do not match'
}                                   # adding an @()-wrapped List of Select-Object copies to [ordered]
$json = $outDoc | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("WROTE " + $Out)
Write-Output ("  rows in: " + @($doc.deals).Count + "  out: " + $outRows.Count + "  (pass-through " + $passThru + ", each->packed " + $packed + ", each->1ct " + $single + ", rejected " + $rejects.Count + ")")
if ($rejects.Count) {
  $rj = [IO.Path]::ChangeExtension($Out, $null) + 'rejects.json'
  $rejects | ConvertTo-Json -Depth 6 | Set-Content $rj -Encoding UTF8
  Write-Output ("  REJECTS -> " + $rj)
}
exit 0
